# Plan: matte and lighting refinements

Status: 14 October 2026. Proposed, nothing built. This follows the person-matting plan and extends the Lighting group.

## Why

A study of a mature production compositor for video calls turned up a handful of techniques we do not have, and confirmed several we do. This plan folds the useful ones into Silhouette's pipeline without changing its shape: everything stays on the GPU at low resolution, under a millisecond or two per frame, with no new models to ship for the first milestones.

## Where we stand

| Stage | Silhouette today |
|---|---|
| Person mask | Vision segmentation at the fast level, about 256×192, 2.5 ms on the Neural Engine, synchronous per frame |
| Mask refinement | Colour guided filter at half camera resolution (radius 3, ε 0.001) plus a colour trimap band for over-coverage |
| Temporal | Stabilize: blend with the previous matte where luma did not change, user strength 0 to 90 |
| Edge colour | Decontaminate (person) and spill suppression (chroma) |
| Scene tint | Foreground layer with Mask on and Blend set to Multiply, applied in sRGB, clipped to the subject |
| Relight | Two lights from the background's brightest halves, body cylinder plus head sphere normals, a tint map at 240×135 eased at 0.08 per frame, multiplied in sRGB; Highlights adds brightness |
| Colour match | Auto temperature from subject and background chroma means, eased |
| Wrap | Part of the relight map: the background's local colour where the soft matte is thin |

## Learnings worth taking

Each item says what the technique is, how it differs from ours, and what we would change.

### 1. Temporal smoothing weighted by uncertainty

The reference keeps more of the previous mask only where the model is unsure (probability near 0.5) and updates confident pixels at once. The weight is an entropy-like curve of the probability: about 1 at 0.5, about 0 near 0 and 1. The blend ratio is 0.7.

Ours blends everywhere the picture is static, at the user's strength. That smooths confident interior pixels that did not need it and, at high strengths, drags the edge when a static scene has a slow-moving subject.

Change: multiply Stabilize's blend by the uncertainty of the fresh matte, so smoothing concentrates on the transition band in both modes. The chroma matte's "probability" is its smoothstep output, which has the same shape. Stabilize stays the user's control and Auto still never touches it; this only changes where the strength applies. Expected: less edge shimmer at the same setting, no interior lag.

### 2. Ghost suppression

A two-pass count of confident pixels in a 5×5 window (vertical then horizontal), with the mask scaled by `smoothstep(0, 0.25, coverage)`. Isolated specks and one-pixel strands the model hallucinated vanish; real edges, which have dense support, are untouched.

We have nothing like it. Noise specks in a chroma key and stray blobs in the person mask both show up as flicker.

Change: add the two passes on the coarse mask before the guided upsample (person) and on the matte before Stabilize (chroma), at the matte's working resolution. Cost is two tiny separable passes. Constants from the reference: radius 2, confidence 0.5, coverage 0.25. Tune on the sample video and a webcam.

### 3. Light wrap as coverage, not colour

The reference's wrap is one line: `weight = min(blur(mask) / 0.5, mask)` then `out = mix(bg, person, weight)`. Where the blurred mask is thin, the subject's coverage drops and the background shows through the edge. It is cheap, runs on the composite, and needs no light estimate.

Ours lives inside the relight map and tints the edge with the background's colour instead of letting the background through. It only runs when Relight is on.

Change: add the coverage wrap to the composite, using the blurred quarter-resolution matte we already render for the shadow (sampled without the shadow offset). Expose it as a Wrap slider in Lighting, default 50 when a background is set, 0 otherwise. Keep the relight's colour wrap, since the two do different jobs: one opens the edge, the other lights it.

### 4. Relight in linear light, as a gain with albedo

The reference adds light as a multiplicative gain in linear RGB: `out = src × (1 + Σ light × albedo × weight)`, converted back to sRGB at the end. Light can only brighten. Albedo, a per-pixel reflectance estimate, puts more light on skin and light clothing than on dark hair. The weight is `min(mask, blur(mask))²`, so light never reaches the background and fades in from the silhouette.

Ours multiplies a tint in sRGB, which darkens as much as it lights, and applies it uniformly across the subject.

Changes, in order of value per effort:

- Weight the relight by `min(mask, blur(mask))²` instead of the matte alone. Free; both textures exist.
- Apply the relight as a gain in linear light: convert the subject pixel to linear, multiply by `1 + k × tint`, convert back. Three `pow` calls per subject pixel, well under 0.1 ms at 1080p.
- An albedo proxy from luma: `luma / blur(luma)` with a wide blur, clamped. We have luma and the shrink-grid downscaler; one more 64×36 map and a sample. A proper albedo model waits for milestone 6 of the matting plan.

### 5. Point lights with distance and falloff

The reference places each light on a sphere around the subject from a screen position and a distance, treats the subject as a plane at z = 0 with the normals giving shape, and attenuates with `1 / (0.1 + 0.4d + 0.5d²)`. The result is a light that gets brighter and more local as it moves toward the subject.

Ours is directional: a vector toward the light's screen position with a fixed forward lean, no falloff. The two lights come from the background's brightest halves, which is a good source and stays.

Change: give each derived light a distance and attenuation. Put the light on the reference's sphere at about 1.5 units, compute Lambert against our geometric normals per pixel of the 240×135 map, and attenuate. Highlights then becomes the intensity of a gain rather than a separate brightness term. Later, user-placed lights become possible with the same code: a position, a colour, an intensity.

### 6. Exposure matching, the luma counterpart of Auto temperature

The reference measures the person's and the background's mean brightness separately, smooths the statistics over time, and brightens the person with a gain that is reduced on already-bright pixels and blended back toward the original on highlights. The gain is applied in linear light after undoing the camera's S-curve and re-applied after, so skin does not go flat.

Our Auto matches chroma only. A subject lit by a dim room against a bright beach reads wrong even with the right tint.

Change: extend the colour statistics kernel to sum luma for subject and background. Add Exposure to Lighting with an Auto switch beside it like Temperature's, driving a masked gain in linear light with the reference's highlight protection: `gain = max(g² × (1 − lum² × k), min(g, 1))` and `out = mix(adjusted, original, lum × k)`. Skip the S-curve round trip for the first version; add it if skin looks flat. Statistics are read back every sixth frame with the lights and eased like the temperature.

### 7. Things we already do that the reference confirms

- Soft maps at low resolution, upsampled with the image as the guide. Our guided filter is the stronger form of the reference's joint bilateral filter, which runs at 320×180 with σ 0.05 in colour. If we need the time back, halving our work resolution from 960×540 to 480×270 is the lever; try it and compare hair edges.
- Scene tint multiplied in sRGB without linearisation, clipped to the subject.
- Measurement separated from application, with the statistics smoothed over time, and a gate that passes video through untouched when nothing is set.
- Heavy work reused across frames: the reference recomputes its lighting textures only when needed; we read light statistics every sixth frame.

### 8. Not worth taking

- Model input as a stretched 256×256 square and the previous mask as a fourth input channel: Vision owns its input, and a recurrent model (matting plan, milestone 6) gets the previous-mask benefit for free.
- Whole-frame scene-adaptive contrast and saturation: it is a camera look, not compositing, and would fight the user's own camera settings.
- Denoise, bilateral-grid tone mapping, and face restoration: image enhancement outside this app's scope.

## Best practices to adopt as rules

1. Everything soft happens at low resolution, upsampled with a guide. Never blur at output resolution.
2. Effects on the subject are weighted by `min(mask, blur(mask))²`, never by the raw matte, so they stop short of the edge and never touch the background.
3. Additive light is a gain in linear light; tint maps are a multiply in sRGB. Do not mix the two.
4. Temporal smoothing goes where the signal is uncertain, not everywhere.
5. Measure on a coarse grid, smooth the statistics, then apply; gate the whole pass off when its strength is zero.
6. Any gain protects highlights: reduce it on bright pixels and blend back toward the original there.

## Milestones

1. **Mask weight and wrap.** Items 3 and 4a: coverage wrap in the composite with a Wrap slider, and the squared min-mask weight on the relight. Half a day. Verify with the sample video over a bright background: the edge opens, the relight stops at the silhouette.
2. **Temporal and ghosts.** Items 1 and 2. One day. Verify flicker on a webcam with no backdrop at Stabilize 30, before and after, by diffing consecutive matte frames.
3. **Linear-light relight with falloff.** Items 4b, 4c, and 5. One to two days. Verify that Highlights no longer darkens anything, that light falls off with distance, and that GPU time stays under 0.4 ms for the relight.
4. **Exposure matching.** Item 6. One day. Verify on the beach and night-cabin scene packs: subject brightness lands near the background's without flat skin.
5. **Work resolution trial.** Item 7's half-resolution guided filter, kept only if hair edges hold up.

Each milestone is its own branch and TestFlight build.

## Open questions

- Whether the coverage wrap should scale with Blur, or stay independent. Try independent first.
- The light distance for derived lights: the reference leaves it to compiled code. Start at 1.5 and judge by eye on the sample video.
- Whether Exposure Auto should also drive the temperature's strength, since both measure the same pair of regions. Keep them separate until there is a reason not to.
- The uncertainty curve for the chroma matte: the smoothstep output is only a probability by analogy. If it over-smooths wide soft ranges, use the distance from the key band's centre instead.
