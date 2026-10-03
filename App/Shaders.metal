#include <metal_stdlib>
using namespace metal;

// Must match KeyParams in Renderer.swift (same field order and types).
struct KeyParams {
    float2 keyCbCr;        // key colour in Cb/Cr, 0..1
    float  tolerance;      // CbCr distance fully keyed out
    float  softness;       // width of the transition band
    float  spill;          // 0..1 spill suppression strength
    float  edge;           // erosion radius in chroma texels (0 = off)
    float  hasBackground;  // 1 = composite over bgTex, 0 = premultiplied alpha out
    float2 camScale;       // output uv -> camera uv (aspect fill)
    float2 camOffset;
    float2 bgScale;        // output uv -> background uv (aspect fill)
    float2 bgOffset;
    float2 chromaTexel;    // 1 / chroma plane size
    float2 shadowOffset;   // shadow displacement in output uv
    float  shadowOpacity;  // 0 = off
    float  temporal;       // weight of the previous frame's matte, 0 = off
    float  bypass;         // 1 = show the unkeyed camera image (key colour picking)
    float  videoRange;     // 1 = source is video-range YCbCr (16-235), 0 = full range
    float2 shadowPad;      // shadow canvas padding as a fraction of the canvas (0 for the key matte)
    float2 fgScale;        // output uv -> foreground uv (aspect fill)
    float2 fgOffset;
    float  hasForeground;  // 1 = composite fgTex (premultiplied) over everything
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Single full-screen triangle, no vertex buffer.
vertex VSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Normalise video-range samples to full range so keying is independent of the
// source format.
static inline float2 fullRangeChroma(float2 cbcr, constant KeyParams &P) {
    return P.videoRange > 0.5 ? (cbcr - 0.5) * (255.0 / 224.0) + 0.5 : cbcr;
}
static inline float fullRangeLuma(float y, constant KeyParams &P) {
    return P.videoRange > 0.5 ? saturate((y - 16.0 / 255.0) * (255.0 / 219.0)) : y;
}

static inline float matte(float2 cbcr, constant KeyParams &P) {
    return smoothstep(P.tolerance, P.tolerance + max(P.softness, 1e-4), distance(cbcr, P.keyCbCr));
}

// Full matte (key + erode) at a camera uv.
static inline float computeMatte(float2 cuv, float2 cbcr, texture2d<float> chromaTex,
                                 sampler s, constant KeyParams &P) {
    float a = matte(cbcr, P);
    if (P.edge > 0.0) {
        float2 e = P.chromaTexel * P.edge;
        a = min(a, matte(fullRangeChroma(chromaTex.sample(s, cuv + float2( e.x, 0.0)).rg, P), P));
        a = min(a, matte(fullRangeChroma(chromaTex.sample(s, cuv + float2(-e.x, 0.0)).rg, P), P));
        a = min(a, matte(fullRangeChroma(chromaTex.sample(s, cuv + float2(0.0,  e.y)).rg, P), P));
        a = min(a, matte(fullRangeChroma(chromaTex.sample(s, cuv + float2(0.0, -e.y)).rg, P), P));
    }
    return a;
}

// Matte pass. Runs at full resolution for the key (with temporal blending
// against the previous frame) and at quarter resolution for the shadow.
// Chroma is prefiltered with four diagonal taps so sensor noise does not
// flip pixels that sit inside the transition band.
fragment float4 mattePass(VSOut in [[stage_in]],
                          texture2d<float> lumaTex   [[texture(0)]],
                          texture2d<float> chromaTex [[texture(1)]],
                          texture2d<float> prevMatte [[texture(4)]],
                          texture2d<float> prevLuma  [[texture(5)]],
                          constant KeyParams &P      [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // The shadow matte renders on a padded canvas: frame coordinates run past
    // 0..1 there and the camera's edge pixels extend outward, so a subject cut
    // off by the frame keeps going instead of ending in a hard line.
    float2 fuv = (in.uv - P.shadowPad) / (1.0 - 2.0 * P.shadowPad);
    float2 cuv = fuv * P.camScale + P.camOffset;

    float2 d = P.chromaTexel * 0.75;
    float2 cbcr = 0.25 * (chromaTex.sample(s, cuv + float2( d.x,  d.y)).rg +
                          chromaTex.sample(s, cuv + float2(-d.x,  d.y)).rg +
                          chromaTex.sample(s, cuv + float2( d.x, -d.y)).rg +
                          chromaTex.sample(s, cuv + float2(-d.x, -d.y)).rg);
    float a = computeMatte(cuv, fullRangeChroma(cbcr, P), chromaTex, s, P);

    if (P.temporal > 0.0) {
        float prev = prevMatte.sample(s, fuv).r;
        // Smooth only where the picture itself is static. Where luma changed
        // between frames something moved, so the fresh matte wins.
        float dy = abs(lumaTex.sample(s, cuv).r - prevLuma.sample(s, cuv).r);
        float motion = smoothstep(0.015, 0.08, dy);
        a = mix(a, prev, P.temporal * (1.0 - motion));
    }
    return float4(a, 0.0, 0.0, 1.0);
}

// Keys directly in the camera's native YCbCr (4:2:0 bi-planar) so no colour
// conversion happens before the key, then converts to RGB once.
fragment float4 chromaKey(VSOut in [[stage_in]],
                          texture2d<float> lumaTex   [[texture(0)]],
                          texture2d<float> chromaTex [[texture(1)]],
                          texture2d<float> bgTex     [[texture(2)]],
                          texture2d<float> shadowTex [[texture(3)]],
                          texture2d<float> matteTex  [[texture(4)]],
                          texture2d<float> fgTex     [[texture(5)]],
                          constant KeyParams &P      [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sb(filter::linear, address::clamp_to_edge);

    float2 cuv = in.uv * P.camScale + P.camOffset;

    float  y    = fullRangeLuma(lumaTex.sample(s, cuv).r, P);
    float2 cbcr = fullRangeChroma(chromaTex.sample(s, cuv).rg, P);

    float a = P.bypass > 0.5 ? 1.0 : matteTex.sample(s, in.uv).r;

    // Drop shadow: the blurred matte, displaced, darkens whatever is behind.
    float shadow = 0.0;
    if (P.shadowOpacity > 0.0 && P.bypass < 0.5) {
        float2 suv = (in.uv - P.shadowOffset) * (1.0 - 2.0 * P.shadowPad) + P.shadowPad;
        shadow = shadowTex.sample(sb, suv).r * P.shadowOpacity;
    }

    // Spill suppression: remove the chroma component that points toward the key.
    float2 keyDir = P.keyCbCr - 0.5;
    float keyLen = length(keyDir);
    if (keyLen > 1e-4 && P.bypass < 0.5) {
        keyDir /= keyLen;
        float along = dot(cbcr - 0.5, keyDir);
        cbcr -= keyDir * max(along, 0.0) * P.spill;
    }

    // Full-range BT.709 YCbCr -> RGB
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float3 rgb = saturate(float3(y + 1.5748 * cr,
                                 y - 0.1873 * cb - 0.4681 * cr,
                                 y + 1.8556 * cb));

    // Everything below is premultiplied. The shadow is black, so over the
    // background it darkens colour and adds coverage where the background is clear.
    float4 out;
    if (P.hasBackground > 0.5) {
        float4 bg = bgTex.sample(s, in.uv * P.bgScale + P.bgOffset);
        float3 under = bg.rgb * (1.0 - shadow);
        float  underA = bg.a + shadow * (1.0 - bg.a);
        out = float4(rgb * a + under * (1.0 - a), a + underA * (1.0 - a));
    } else {
        out = float4(rgb * a, a + (1.0 - a) * shadow);
    }
    if (P.hasForeground > 0.5) {
        float4 fg = fgTex.sample(s, in.uv * P.fgScale + P.fgOffset);
        out = fg + out * (1.0 - fg.a);
    }
    return out;
}

// 2x2 box downsample: one bilinear tap at the centre of each 2x2 block
// averages it exactly.
fragment float4 downsample(VSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}

// Small 4:2:0 copy of the whole camera frame for Vision, written as two
// planes. Vision takes bi-planar input through its CPU path, which is cheap
// at 640x360; a BGRA input would route through Core Image on the GPU.
fragment float4 trackLuma(VSOut in [[stage_in]],
                          texture2d<float> lumaTex [[texture(0)]],
                          constant KeyParams &P    [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(fullRangeLuma(lumaTex.sample(s, in.uv).r, P), 0.0, 0.0, 1.0);
}

fragment float4 trackChroma(VSOut in [[stage_in]],
                            texture2d<float> chromaTex [[texture(1)]],
                            constant KeyParams &P      [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(fullRangeChroma(chromaTex.sample(s, in.uv).rg, P), 0.0, 1.0);
}
