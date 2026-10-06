# Plan: background removal without a green screen

Status: 5 October 2026. Milestones 1 to 3 are built on the `person-matte` branch: Vision segmentation at the fast level, a colour guided-filter upsample, a colour trimap band for the model's over-coverage, and edge decontamination. Measured: fast is about 2.5 ms per frame (9 ms in the app alongside face tracking), balanced 17 ms, accurate 50 ms, so only fast fits a frame; the plan's balanced-level estimate was wrong. Not yet done: system effect detection, subject selection, and the Metal 4 matting model.

## Goal

Add a second matte source to Silhouette: a person matte produced by on-device machine learning, so the app works with no backdrop at all. It must keep the qualities the chroma path already has: 1080p at 30 fps, about a millisecond of GPU time per frame for our own passes, no CPU copies of video, sandboxed, App Store safe. Everything downstream of the matte (Shrink, Blur, Stabilize, shadow, layers, face tracking) stays as it is, so the user sees one app with two ways to make a matte.

Non-goals for the first version: multiple people with separate controls, held objects outside the person, and iPhone depth data (Continuity Camera does not expose depth to Mac apps).

## What macOS gives us

Four routes exist. The recommendation is the first, with the third as the next step.

### 1. Vision person segmentation (ship this)

Vision has had person segmentation since macOS 12 and it runs on the Neural Engine. The macOS 15 Swift API is `GeneratePersonSegmentationRequest`, with `perform(on:)` returning a `PixelBufferObservation` whose pixel buffer is a soft mask. Three quality levels trade accuracy for time; `.balanced` is the one meant for video. The older `VNGeneratePersonSegmentationRequest` is the same model behind an Objective-C style API and covers macOS 14, our deployment target.

Strengths: zero model management, Apple maintains and improves it, no Core ML download, nothing to ship. Weaknesses: the mask is low resolution (the model works at a few hundred pixels across), edges are soft and hair is a blob, and we have no control over temporal behaviour. All three weaknesses are fixable on the GPU, which is the heart of this plan.

### 2. Vision instance masks (use for recovery, not every frame)

`GeneratePersonInstanceMaskRequest` (macOS 14) separates up to four people, and `GenerateForegroundInstanceMaskRequest` (macOS 14) finds salient foreground objects, people or not. Both are heavier than segmentation and meant for stills. We use the instance request only when the segmentation mask contains more than one blob, to decide which person to keep, and only every second or so.

### 3. A matting model through Core ML and Metal 4 (next step)

Segmentation answers "is this pixel a person"; matting answers "how much of this pixel is the person", which is what hair and motion blur need. Open models such as Robust Video Matting are small (the MobileNetV3 variant runs at 512×288 in a few milliseconds on the Neural Engine), recurrent (they carry hidden state between frames, which gives free temporal stability), and output both alpha and a decontaminated foreground colour.

macOS 15 added `MLState` to Core ML so recurrent models keep their state on device without round trips. macOS 26 added Metal 4's machine learning command encoder, which runs a Core ML model inside a Metal command buffer, reading and writing `MTLTensor` objects that alias our textures. That removes the last copy: the camera texture goes in, an alpha texture comes out, and the composite runs in the same command buffer. This is the most efficient form the whole pipeline can take, and it is also the most work: model conversion, a Metal 4 command queue beside the current one, and a macOS 26 only path.

### 4. The system effects (not usable)

Control Center's Portrait and Background Replacement effects process every camera frame for every app, and `AVCaptureDevice` only lets an app read whether they are on. They would fight our key and cannot be controlled, so the plan is to detect them and tell the user to turn them off when the person matte is active.

## Architecture

```
camera frame (4:2:0, IOSurface)
   │
   ├─► existing path: luma/chroma textures ──────────────────────────────┐
   │                                                                      │
   └─► small frame for Vision (reuse the 640×360 tracking frame,          │
       made on the GPU today)                                             │
           │                                                              │
           ▼  Neural Engine, async, dedicated queue                       │
       person mask, ~512 px wide, 8-bit, IOSurface-backed                 │
           │                                                              │
           ▼  Metal                                                       │
       guided upsample to processing resolution using luma as the guide  │
       (two box-filter passes, MPS) ──► alpha matte at 1080p/4K           │
           │                                                              │
           ▼                                                              │
       temporal blend gated by luma change (the existing Stabilize)       │
           │                                                              │
           ▼                                                              ▼
       matte texture ──────────────────────────► existing composite pass
                                                 (Shrink, Blur, shadow, layers,
                                                  edge decontamination replaces spill)
```

The renderer already has every stage after "matte texture". The new work is the branch on the left: feeding Vision, getting its mask back as a texture, and the guided upsample.

### Data flow with no copies

- Vision input: a `CVPixelBuffer` from a pool with `kCVPixelBufferIOSurfacePropertiesKey` and Metal compatibility. The renderer already writes a 640×360 bi-planar frame for face tracking on the GPU; segmentation takes the same buffer, so the downscale costs nothing new. If `.balanced` wants more pixels than that, raise the tracking frame to 768×432 for both consumers.
- Vision output: set the request's output pixel format to one-component 8-bit. The returned buffer is IOSurface-backed, so `CVMetalTextureCache` wraps it as an `r8Unorm` texture with no copy, exactly as the camera planes are wrapped today.
- Scheduling: Vision runs asynchronously on its own queue. The render for frame N uses the newest finished mask, which is usually from frame N-1. One frame of matte latency at 30 fps is 33 ms, under what people notice, and it keeps the GPU path from ever waiting on the Neural Engine. If a mask is older than two frames, keep using it rather than stall.
- Rate: every frame at `.balanced` when the Neural Engine is otherwise idle. If face tracking is also on, alternate them or drop segmentation to every other frame; the guided upsample uses the current frame's luma, so a one-frame-old mask still snaps to the current edges.

### Guided upsample (the part that makes it look good)

A guided filter upsamples the coarse mask using the full-resolution luma image as the guide, so the matte follows real edges, including hair strands, that the mask never saw. It is two passes of box filtering over five small images plus two tiny per-pixel shaders, all separable, so on the GPU it costs about what the existing shadow blur costs. Radius 8 at 1080p, epsilon tuned once. This replaces the blobby model edge with an edge that sits on the actual boundary. Output is the alpha matte at processing resolution, written straight into the texture the composite pass already samples.

Fallback for the first milestone: a plain bilinear upsample with the existing Blur, to see the pipeline end to end before the guided filter lands.

### Edge decontamination

Spill suppression is a chroma-key idea; with a person matte the edge problem is background colour mixed into semi-transparent pixels. Standard fix: for pixels with 0 < alpha < 1, estimate the background colour from the nearest alpha-zero pixels (a small dilation of the background, computed in the same guided-filter passes) and unmix: `fg = (pixel - (1 - alpha) * bg) / alpha`. Reuse the Desaturate slider as the strength, relabelled "Decontaminate" when in person mode.

### Temporal behaviour

Segmentation masks flicker frame to frame. Stabilize already blends the matte with the previous frame where luma did not change, which is the right tool and already exists. Default it to 30 in person mode and 0 in chroma mode, since the chroma matte does not flicker and the person matte does.

### Choosing who to keep

The segmentation mask covers every person in frame. Policy for version one: keep everything the mask calls person, which matches how video apps behave. When the face tracker reports a face, the person containing it is the subject; if the mask has a second blob with no face for more than a second, run the instance request once and offer "Keep only me" as a switch.

## Performance budget

Estimates on an M-series Mac at 1080p, to be measured in milestone one:

| Stage | Where | Estimate |
|---|---|---|
| Small frame for Vision | GPU, already exists | 0 ms new |
| Person segmentation, balanced | Neural Engine, async | 3–6 ms, off the GPU and CPU |
| Mask wrap as texture | none | 0 ms |
| Guided upsample, radius 8 | GPU | 0.4–0.8 ms |
| Decontamination | GPU, in composite | under 0.1 ms |
| Everything existing | GPU | about 1 ms today |

GPU total stays near 2 ms per frame. The Neural Engine time runs in parallel and does not delay frames. Power is the real cost: the Neural Engine at 30 Hz is a few hundred milliwatts, less than the camera ISP, and far less than the WebKit snapshots we already take for web layers.

## Milestones

1. **Plumbing.** New `PersonMatter.swift`: pixel buffer pool, Vision request at `.balanced`, async perform, newest-mask handoff under the existing lock, `CVMetalTextureCache` wrap. Renderer gains a matte source switch: `.chroma` (today) or `.person`. In person mode the matte pass samples the upsampled mask instead of computing chroma distance. Bilinear upsample only. Sidebar gets a Matte segmented control: Chroma / Person. Measure GPU ms and Neural Engine time with `powermetrics`.
2. **Guided upsample.** Metal pass using MPS box filters on mask, luma, and their products; fuse the two small per-pixel steps into one kernel each. Tune radius and epsilon on the sample video and a webcam with no backdrop. Compare hair edges against milestone one in screenshots.
3. **Decontamination and defaults.** Background estimate from the dilated alpha-zero region, unmix in the composite shader, Desaturate relabelled per mode, Stabilize defaults per mode, Auto disabled in person mode (nothing to sample) with the swatch and Auto hidden.
4. **System effect detection.** Read `isPortraitEffectEnabled` and the background replacement flag on the current device, and show a one-line hint when either is on in person mode.
5. **Subject selection.** Face-anchored person choice, the occasional instance request, and the "Keep only me" switch.
6. **Metal 4 matting (macOS 26 only, behind a flag).** Convert a matting model to a Core ML package, build a Metal 4 machine learning pipeline state, run it in the render command buffer with `MTLTensor` views of the camera and alpha textures, keep recurrent state in `MLState`. Fall back to milestone 2 on older systems. This is where hair detail and motion blur get properly right, and where the whole frame costs one command buffer.

## Open questions

- Which `.balanced` input size the model actually uses, and whether our 640×360 frame is enough or it wants 768 wide. Measure on day one.
- Whether `GeneratePersonSegmentationRequest` output can be requested at a chosen size, or whether we always upsample from the model's native size.
- How the Vision mask behaves on 4K processing mode: the mask resolution does not change, only the upsample does, so 4K should cost only the guided filter at 4K, roughly four times 0.6 ms.
- Licence terms of any third-party matting model for milestone 6. Robust Video Matting is GPL-3 in its reference repository; a permissively licensed alternative or a model trained in-house would be needed for the App Store build.

## Risks

- Edge quality from segmentation alone will not match a lit green screen. The guided filter closes most of the gap; the honest message to users is "good enough for calls, use a backdrop for broadcast".
- Neural Engine contention with face tracking. Mitigation is alternating frames; both are tolerant of half rate.
- Apple's model changes between OS versions, so masks differ by machine. Tune thresholds from the mask statistics per session rather than hard-coding them.
