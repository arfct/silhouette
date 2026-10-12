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
    float  personMode;     // 1 = the matte comes from maskTex (person segmentation), not chroma
    float  temperature;    // colour temperature shift for the camera pixels only: -1 cool … +1 warm
    float  fgMasked;       // 1 = the foreground layer shows only over the subject (multiplied by the matte)
    float  relight;        // 0…1 strength of the background's light on the subject
    float  highlights;     // 0 only tints lit areas … 1 also brightens them
    float  hasFace;        // 1 when faceEllipse and faceForward are valid
    float  aspect;         // output width / height, to measure uv directions isotropically
    float  relightPad0;    // keeps the float4s below 16-byte aligned without implicit padding
    float  relightPad1;
    float4 faceEllipse;    // head ellipse in output uv: centre xy, radii zw
    float4 faceForward;    // unit vector the face points along, camera space (x right, y up, z away from the camera)
    float4 light0;         // xy: position in output uv, z: brightness 0…1
    float4 light0Color;    // rgb with the largest channel 1
    float4 light1;
    float4 light1Color;
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

// The colour guide at a camera uv: full-range (Y, Cb, Cr).
static inline float3 guideColor(float2 cuv, texture2d<float> lumaTex, texture2d<float> chromaTex, sampler s, constant KeyParams &P) {
    return float3(fullRangeLuma(lumaTex.sample(s, cuv).r, P), fullRangeChroma(chromaTex.sample(s, cuv).rg, P));
}

// Refined person alpha at a camera uv. Two ideas stacked:
//  1. Guided filter: alpha = a · (Y, Cb, Cr) + b with box-filtered coefficients,
//     so the edge follows the image within the filter's window.
//  2. Trimap by colour: the wide box mean of the coarse mask splits the frame into
//     definite subject (near 1), definite background (near 0), and a band. In the
//     band, a pixel is subject to the degree its colour is closer to the local
//     subject colour than to the local background colour. This is what removes
//     the model's over-coverage around hair, which is wider than any filter window.
static inline float personAlpha(float2 cuv, texture2d<float> lumaTex, texture2d<float> chromaTex,
                                texture2d<float> guideTex, texture2d<float> wide0, texture2d<float> wide2,
                                texture2d<float> wide3, texture2d<float> wideBg, sampler s, constant KeyParams &P) {
    float3 I = guideColor(cuv, lumaTex, chromaTex, s, P);
    float4 ab = guideTex.sample(s, cuv);
    float guided = smoothstep(0.3, 0.7, saturate(dot(ab.xyz, I) + ab.w));

    float4 w0 = wide0.sample(s, cuv);        // mean (Y, Cb, Cr), mean p over the wide window
    float pWide = w0.w;
    if (pWide > 0.97) return guided;         // deep inside the mask: trust it
    if (pWide < 0.03) return 0.0;            // far outside: nothing
    float4 w2 = wide2.sample(s, cuv);        // CbCr, CrCr, Y·p, Cb·p
    float4 w3 = wide3.sample(s, cuv);        // Cr·p
    float4 wb = wideBg.sample(s, cuv);       // (Y, Cb, Cr)·(1-p), (1-p)
    if (wb.w < 0.05) return guided;          // too little background nearby for a usable estimate
    float3 fgMean = float3(w2.z, w2.w, w3.x) / pWide;
    float3 bgMean = wb.xyz / wb.w;
    const float3 weight = float3(1.0, 2.5, 2.5);   // chroma separates hair from backdrop; luma less so
    float dFg = length((I - fgMean) * weight);
    float dBg = length((I - bgMean) * weight);
    float byColor = smoothstep(0.3, 0.7, dBg / max(dFg + dBg, 1e-4));
    return guided * byColor;
}

// Guided filter with a colour guide, step 1: at the work resolution gather the
// guide I = (Y, Cb, Cr), the coarse mask p, and their products, plus the
// background colour estimate weighted by (1 - p). Box filters turn all of
// these into local means.
kernel void guidedPrep(texture2d<float> lumaTex   [[texture(0)]],
                       texture2d<float> chromaTex [[texture(1)]],
                       texture2d<float> maskTex   [[texture(2)]],
                       texture2d<float, access::write> out0 [[texture(3)]],   // Y, Cb, Cr, p
                       texture2d<float, access::write> out1 [[texture(4)]],   // YY, YCb, YCr, CbCb
                       texture2d<float, access::write> out2 [[texture(5)]],   // CbCr, CrCr, Yp, Cbp
                       texture2d<float, access::write> out3 [[texture(6)]],   // Crp, -, -, -
                       texture2d<float, access::write> bgOut [[texture(7)]],  // (Y, Cb, Cr) * (1-p), (1-p)
                       constant KeyParams &P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out0.get_width() || gid.y >= out0.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(out0.get_width(), out0.get_height());
    float3 I = guideColor(uv, lumaTex, chromaTex, s, P);
    float p = maskTex.sample(s, uv).r;
    out0.write(float4(I, p), gid);
    out1.write(float4(I.x * I.x, I.x * I.y, I.x * I.z, I.y * I.y), gid);
    out2.write(float4(I.y * I.z, I.z * I.z, I.x * p, I.y * p), gid);
    out3.write(float4(I.z * p, 0.0, 0.0, 0.0), gid);
    float w = 1.0 - p;
    bgOut.write(float4(I * w, w), gid);
}

// Guided filter, step 2: solve (Σ + ε I) a = cov(I, p) per pixel for the 3-vector
// a, and b = mean p − a · mean I. A box filter averages (a, b) before use.
kernel void guidedCoefficients(texture2d<float> m0 [[texture(0)]],
                               texture2d<float> m1 [[texture(1)]],
                               texture2d<float> m2 [[texture(2)]],
                               texture2d<float> m3 [[texture(3)]],
                               texture2d<float, access::write> out [[texture(4)]],
                               constant float &epsilon [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float4 a0 = m0.read(gid), a1 = m1.read(gid), a2 = m2.read(gid), a3 = m3.read(gid);
    float3 mu = a0.xyz;
    float mp = a0.w;
    // Covariance of the guide, regularised.
    float3x3 sigma = float3x3(float3(a1.x - mu.x * mu.x, a1.y - mu.x * mu.y, a1.z - mu.x * mu.z),
                              float3(a1.y - mu.x * mu.y, a1.w - mu.y * mu.y, a2.x - mu.y * mu.z),
                              float3(a1.z - mu.x * mu.z, a2.x - mu.y * mu.z, a2.y - mu.z * mu.z));
    sigma[0][0] += epsilon; sigma[1][1] += epsilon; sigma[2][2] += epsilon;
    float3 cov = float3(a2.z, a2.w, a3.x) - mu * mp;
    // Inverse by cofactors; the matrix is symmetric positive definite after ε.
    float3 c0 = cross(sigma[1], sigma[2]);
    float3 c1 = cross(sigma[2], sigma[0]);
    float3 c2 = cross(sigma[0], sigma[1]);
    float det = dot(sigma[0], c0);
    float3 a = float3(dot(c0, cov), dot(c1, cov), dot(c2, cov)) / max(det, 1e-12);
    float b = mp - dot(a, mu);
    out.write(float4(a, b), gid);
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
                          texture2d<float> maskTex   [[texture(6)]],
                          texture2d<float> guideTex  [[texture(7)]],
                          texture2d<float> wide0     [[texture(8)]],
                          texture2d<float> wide2     [[texture(9)]],
                          texture2d<float> wide3     [[texture(10)]],
                          texture2d<float> wideBg    [[texture(11)]],
                          constant KeyParams &P      [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // The shadow matte renders on a padded canvas: frame coordinates run past
    // 0..1 there and the camera's edge pixels extend outward, so a subject cut
    // off by the frame keeps going instead of ending in a hard line.
    float2 fuv = (in.uv - P.shadowPad) / (1.0 - 2.0 * P.shadowPad);
    float2 cuv = fuv * P.camScale + P.camOffset;

    float a;
    if (P.personMode > 0.5) {
        // Guided-filter upsample of the coarse person mask: alpha = meanA * luma + meanB,
        // with the coefficients box-filtered at the work resolution. Edges land on
        // the image's own edges rather than the mask's blocks. Shrink erodes it.
        #define PERSON(uv) personAlpha(uv, lumaTex, chromaTex, guideTex, wide0, wide2, wide3, wideBg, s, P)
        a = PERSON(cuv);
        if (P.edge > 0.0) {
            float2 e = P.chromaTexel * P.edge;
            a = min(a, PERSON(cuv + float2( e.x, 0.0)));
            a = min(a, PERSON(cuv + float2(-e.x, 0.0)));
            a = min(a, PERSON(cuv + float2(0.0,  e.y)));
            a = min(a, PERSON(cuv + float2(0.0, -e.y)));
        }
        #undef PERSON
    } else {
        float2 d = P.chromaTexel * 0.75;
        float2 cbcr = 0.25 * (chromaTex.sample(s, cuv + float2( d.x,  d.y)).rg +
                              chromaTex.sample(s, cuv + float2(-d.x,  d.y)).rg +
                              chromaTex.sample(s, cuv + float2( d.x, -d.y)).rg +
                              chromaTex.sample(s, cuv + float2(-d.x, -d.y)).rg);
        a = computeMatte(cuv, fullRangeChroma(cbcr, P), chromaTex, s, P);
    }

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
                          texture2d<float> bgEstTex  [[texture(6)]],
                          texture2d<float> lightTex  [[texture(7)]],
                          texture2d<float> wrapTex   [[texture(8)]],
                          constant KeyParams &P      [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sb(filter::linear, address::clamp_to_edge);

    float2 cuv = in.uv * P.camScale + P.camOffset;

    float  y    = fullRangeLuma(lumaTex.sample(s, cuv).r, P);
    float2 cbcr = fullRangeChroma(chromaTex.sample(s, cuv).rg, P);

    float a = P.bypass > 0.5 ? 1.0 : matteTex.sample(s, in.uv).r;

    // Person mode: edge decontamination. A semi-transparent pixel is a mix of
    // subject and background; subtract the local background estimate and
    // re-normalise, by the Decontaminate strength (the spill slider).
    if (P.personMode > 0.5 && P.bypass < 0.5 && a > 0.02 && a < 0.98 && P.spill > 0.0) {
        float4 bg = bgEstTex.sample(s, cuv);
        if (bg.w > 0.05) {
            float3 bgColor = bg.xyz / bg.w;
            float3 pixel = float3(y, cbcr);
            float an = max(a, 0.15);
            float3 unmixed = (pixel - (1.0 - an) * bgColor) / an;
            unmixed = clamp(unmixed, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));
            float3 fixedColor = mix(pixel, unmixed, P.spill);
            y = fixedColor.x; cbcr = fixedColor.yz;
        }
    }

    // Drop shadow: the blurred matte, displaced, darkens whatever is behind.
    float shadow = 0.0;
    if (P.shadowOpacity > 0.0 && P.bypass < 0.5) {
        float2 suv = (in.uv - P.shadowOffset) * (1.0 - 2.0 * P.shadowPad) + P.shadowPad;
        shadow = shadowTex.sample(sb, suv).r * P.shadowOpacity;
    }

    // Spill suppression: remove the chroma component that points toward the key.
    float2 keyDir = P.keyCbCr - 0.5;
    float keyLen = length(keyDir);
    if (keyLen > 1e-4 && P.bypass < 0.5 && P.personMode < 0.5) {
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

    // Colour temperature, camera pixels only: a white-balance gain on red and
    // blue, renormalised so brightness does not change. Layers are untouched.
    const float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    if (P.temperature != 0.0 && P.bypass < 0.5) {
        float t = P.temperature * 0.22;
        float3 shifted = rgb * float3(1.0 + t, 1.0, 1.0 - t);
        float before = dot(rgb, lumaWeights), after = dot(shifted, lumaWeights);
        rgb = saturate(shifted * (before / max(after, 1e-4)));
    }

    // Relight: the background's light on the subject. Two parts. Light wrap:
    // the blurred background's colour bleeds in where the soft matte is thin,
    // i.e. along the silhouette. Head: the two brightest regions of the
    // background act as lights on a sphere fitted to the face, plus a term for
    // the direction the face points, so turning toward a light lights it.
    // The result multiplies the pixel (albedo × illumination), so it lands on
    // light, lit surfaces and leaves dark ones alone; Highlights adds brightness.
    if (P.relight > 0.0 && P.bypass < 0.5 && a > 0.002) {
        float3 local = lightTex.sample(s, in.uv * P.bgScale + P.bgOffset).rgb;
        float inside = wrapTex.sample(s, in.uv).r;
        float3 lightSum = 0.0;
        float kSum = 0.0;
        float wrap = 1.0 - smoothstep(0.0, 0.85, inside);
        float kw = wrap * smoothstep(0.04, 0.35, dot(local, lumaWeights));
        lightSum += local * kw; kSum += kw;
        if (P.hasFace > 0.5) {
            float2 d = (in.uv - P.faceEllipse.xy) / P.faceEllipse.zw;
            float r2 = dot(d, d);
            if (r2 < 1.0) {
                float3 n = float3(d.x, -d.y, -sqrt(1.0 - r2));   // sphere normal, camera space
                float fade = 1.0 - smoothstep(0.6, 1.0, r2);     // hand over to the wrap at the rim
                for (int i = 0; i < 2; i++) {
                    float4 L = i == 0 ? P.light0 : P.light1;
                    float3 C = i == 0 ? P.light0Color.rgb : P.light1Color.rgb;
                    if (L.z <= 0.0) continue;
                    // From the head toward the light, slightly in front of the head so it reaches the face.
                    float3 dir = normalize(float3((L.x - P.faceEllipse.x) * P.aspect, -(L.y - P.faceEllipse.y), -0.25));
                    float sphere = max(dot(n, dir), 0.0);
                    float plane = max(dot(P.faceForward.xyz, dir), 0.0);
                    float g = (0.7 * sphere * sphere + 0.5 * plane) * L.z * fade;
                    lightSum += C * g; kSum += g;
                }
            }
        }
        if (kSum > 1e-4) {
            float3 tint = lightSum / max(max(lightSum.r, max(lightSum.g, lightSum.b)), 1e-4);
            float k = min(kSum, 1.0) * P.relight;
            rgb = saturate(rgb * mix(float3(1.0), tint, k) * (1.0 + P.highlights * k));
        }
    }

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
        if (P.fgMasked > 0.5) fg *= a;   // premultiplied, so one multiply confines it to the subject
        out = fg + out * (1.0 - fg.a);
    }
    return out;
}

// Shrinks a texture to the destination size by averaging an 8×8 grid of
// bilinear taps per destination texel: evenly spread, so no source region is
// skipped, and far cheaper than a proper filter for a 60:1 reduction. Used
// for the relight's light map and soft matte, which are blurred afterwards.
kernel void shrinkGrid(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 cell = 1.0 / float2(dst.get_width(), dst.get_height());
    float2 origin = float2(gid) * cell;
    float4 sum = 0.0;
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8; i++) {
            sum += src.sample(s, origin + (float2(i, j) + 0.5) / 8.0 * cell);
        }
    }
    dst.write(sum / 64.0, gid);
}

// Average colour of the subject (matte-weighted camera chroma) and of the
// background layer, on a coarse grid, summed into fixed-point counters. The
// CPU turns the two means into an automatic temperature setting.
kernel void colorStats(texture2d<float> lumaTex   [[texture(0)]],
                       texture2d<float> chromaTex [[texture(1)]],
                       texture2d<float> matteTex  [[texture(2)]],
                       texture2d<float> bgTex     [[texture(3)]],
                       device atomic_uint *sums   [[buffer(1)]],
                       constant KeyParams &P      [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]],
                       uint2 grid [[threads_per_grid]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(grid);
    float2 cuv = uv * P.camScale + P.camOffset;
    float a = matteTex.sample(s, uv).r;
    float2 cbcr = fullRangeChroma(chromaTex.sample(s, cuv).rg, P);
    const float scale = 1024.0;
    atomic_fetch_add_explicit(&sums[0], uint(a * cbcr.x * scale), memory_order_relaxed);
    atomic_fetch_add_explicit(&sums[1], uint(a * cbcr.y * scale), memory_order_relaxed);
    atomic_fetch_add_explicit(&sums[2], uint(a * scale), memory_order_relaxed);
    if (P.hasBackground > 0.5) {
        float4 bg = bgTex.sample(s, uv * P.bgScale + P.bgOffset);
        float3 c = bg.a > 1e-3 ? bg.rgb / bg.a : float3(0.0);   // premultiplied
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        float cb = (c.b - y) / 1.8556 + 0.5, cr = (c.r - y) / 1.5748 + 0.5;
        atomic_fetch_add_explicit(&sums[3], uint(bg.a * cb * scale), memory_order_relaxed);
        atomic_fetch_add_explicit(&sums[4], uint(bg.a * cr * scale), memory_order_relaxed);
        atomic_fetch_add_explicit(&sums[5], uint(bg.a * scale), memory_order_relaxed);
    }
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
