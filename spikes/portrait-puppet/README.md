# Portrait puppet spike: can LivePortrait run on the Neural Engine?

Question: animate a still portrait from the face Silhouette already tracks, natively, as light as possible. This spike measures the model route (LivePortrait, MIT code) on this repo's development Mac: Apple M4, 16 GB, macOS 27.2, coremltools 9.0, torch 2.7.0, FP16, 2026-11-04.

LivePortrait's per-frame work is three modules: the motion extractor (driving face to keypoints), the warping module (moves the source portrait's 3D feature volume), and the SPADE generator (draws the 512 px frame). The appearance features of the still image are computed once.

## Results

| Module | Converts to Core ML? | Where it runs (MLComputePlan, CPU+ANE) | Median per frame, CPU+ANE | Median, CPU+GPU |
|---|---|---|---|---|
| Motion extractor (256 px in) | Yes | 333 of 333 ops on the ANE | 4.2 ms | 6.8 ms |
| SPADE generator (64×64×256 in, 512 px out) | Yes | 175 of 175 ops on the ANE | 64.0 ms | 187.1 ms |
| Warping module | No | n/a | n/a | n/a |
| 3D `grid_sample` alone (1×32×16×64×64) | No: Core ML's `resample` op takes rank-4 tensors only | n/a | n/a | n/a |
| 2D `grid_sample` alone (1×512×64×64) | Yes | CPU only (not supported on the ANE) | 12.8 ms | 13.0 ms |

What this says:
- The two networks that convert run entirely on the Neural Engine, and the ANE is 1.6 to 2.9 times faster than this Mac's GPU for them.
- The generator alone takes 64 ms, so the model route tops out near 15 frames per second at 512 px before the warp is counted. Silhouette's budget is 30 fps at about a millisecond of GPU time for its own passes.
- The warp can't run in Core ML at all. It would be a custom Metal compute pass (trilinear sampling of a 2-million-voxel volume), and the dense-motion network in front of it uses 3D convolutions, which this spike did not test.

## Verdict

The model route works on the Neural Engine but is not lightweight: about 70 ms a frame on an M4, roughly 400 MB of weights, and a Metal pass still to write. The lightweight route needs no model: detect the still image's face landmarks once with Vision, triangulate them with border points, and each frame move the mesh by the offsets the existing `FaceTracker` already measures, drawn as one textured mesh in `Renderer`. Vision's landmark request is already running, so the added cost is a draw of a few hundred triangles.

## The lightweight route, built

`App/FacePuppet.swift`, toggled by the theatre-masks button on the Foreground tile (saved as `fgPuppet`; turning it on also turns on face tracking and Vision landmarks).

1. When a still image is loaded as the foreground, Vision finds its largest face's landmarks once (`analyze`).
2. The first camera face after turning it on is the neutral pose. Each face update (15 Hz by default) compares the camera landmarks with that pose in a frame built from the eyes (centre between them, x along them, y toward the mouth), so mirroring and roll cancel out.
3. A 97×97 grid over the image moves in two parts: the head follows the camera's translation, scale and roll, fading out between 1.8 and 3.4 eye distances from the face; and each landmark's expression offset spreads to nearby grid points with a Gaussian whose width depends on the region (0.07 eye distances for eyelids and inner lips, 0.25 for the jaw line).
4. `Renderer` draws the grid as one indexed mesh into a texture of the image's size, in its own command buffer just before the composite, and uses it as the foreground for that frame.

`puppet_check.swift` drives `FacePuppet` offline with edited copies of a portrait's own landmarks (neutral, mouth open, eyes shut, 12° roll, head shift) and writes each frame as a PNG.

Checked offline on one 2048 px portrait: the jaw drops and the lips part, the head rolls and shifts with the body held still, no tearing. Eyes only half close: a warp can squash the eye but has no eyelid to draw over it. Not checked: a live camera in the app, timing in the app, images whose face is near the edge, and images with EXIF rotation (Vision reads the raw orientation).

### In the app

`SILHOUETTE_DEMO_PUPPET=1` (Debug builds only) starts with the bundled sample video as the source, `Demo/portrait.jpg` as the foreground and the puppet on: `open --env SILHOUETTE_DEMO_PUPPET=1 build/Build/Products/Debug/Silhouette.app`. It logs a stats line each second under the `puppet` category (`log show --info --predicate 'category == "puppet"'`). `Demo/portrait.jpg` is the Mona Lisa from Wikimedia Commons (public domain), cropped to 16:9 around the face.

Measured on the Mac mini (M4), Debug build, 2026-11-04: 24 fps (the sample video's rate), whole-frame GPU time 0.96 to 1.29 ms with the puppet on. The mesh solve runs off the main thread: 0.30 to 0.34 ms per update optimised (`puppet_check`), 54 ms in the unoptimised Debug build. The head follows the video's tilt and position with no tearing; the top of the hair stretches when the head moves down. Guards added after the first run: expression fades out past 20° of yaw or pitch, each landmark offset is capped at 0.35 eye distances, roll at 25°, the neutral pose is only taken from a face within 12° of the camera, the mesh eases back when the face is lost, and the image edges are pinned.

### 3D head

Second round, same day. The 2D warp could only tilt and shift, so a turned head looked flat. Now each grid point inside an ellipsoid round the head (1.25 by 1.6 eye distances, 0.95 deep, centred near the nose) is lifted onto it, turned by the camera face's yaw and pitch from Vision (relative to the neutral pose, capped at 40° and 35°), rolled, moved, and projected back; its depth goes to a depth test so the near side of the head draws over the far side, and a full-frame copy of the image behind the mesh fills any hole a sharp turn opens (the camera showed through there before). Head pose is eased (0.35 a step); eyes, lips, brows and chin are not. Head size stays as drawn. Expression is now each feature's change of shape about its own centre (brows against the eye below), so head motion no longer leaks into it, and the chin follows the lower lip.

Seen in the recording: the head turns left and right and nods in 3D, no holes or tearing. At the largest turns the top of the hair sweeps into a crest, because the ellipsoid ends inside the hair. GPU time per frame stayed at 0.96 to 1.17 ms.

### Depth from a model, once per image

Third round. The ellipsoid is replaced by the portrait's own depth: Apple's Core ML conversion of Depth Anything V2 Small (Apache 2.0, 48 MB, `scripts/fetch-models.sh` puts it in `App/Models`, kept out of git) runs once when the foreground image loads, on the CPU and Neural Engine through Vision (34 ms for the 1280×720 portrait on the M4). The depth is sampled onto the mesh grid and scaled so the face contour sits at 0.4 of the head's depth and the nose tip at the front; without the model the ellipsoid is the fallback. Per frame nothing changes: the same Metal mesh, about 1 ms of GPU time.

Why not a one-shot 3D avatar model: LAM (Alibaba, 2025) builds an animatable Gaussian head from one photo, but its weights are CC BY-NC 4.0, its install expects CUDA, and it is rigged to FLAME. MobilePortrait (ByteDance, 2025) has no released weights. Seen in the recording: turns keep the face's shape better than the ellipsoid; the hair still crests at the largest turns.

### Cutout and clean plate, once per image

Fourth round, for the hair. Vision's person segmentation (accurate) cuts the subject out, and LaMa (big-lama, Apache 2.0, the 209 MB Core ML conversion mirrored at gumka/lama-coreml, fetched by `scripts/fetch-models.sh`) fills the background where she was. The whole cutout turns with the face, hair included, fading out only down the neck; the mesh draws only inside the cutout, over the clean plate. The mask is grown two grid cells for the motion weight so edge cells move whole: without that the hair edge tore into a sawtooth. The first image took 6.4 s for cutout and plate together, model load included. Seen in the recording: the hair crest is gone, and landscape shows where the head moved.

### A closed head

Fifth round, for the flat back of the head. Behind the face sheet sits a skull: the back half of an ellipsoid, measured from the cutout (head centre to the hair's edge on each side and to its top, depth 0.9 of the half-width), turned rigidly with the head. It is two quarter shells, one per side, each textured from its own side's hair band just inside the outline, so the exposed back shows hair rather than the face. It is hidden while no face is tracked, because it has no rest pose to ease to; leaving it showed a stale turned skull over the face. Seen in the recording: turned heads have a rounded back of hair; its texture is a stretched copy of the side hair.

## Files

- `convert_liveportrait.py` converts the three modules (run from a LivePortrait checkout with its weights in `pretrained_weights/`).
- `grid_sample_probe.py` converts the 3D and 2D `grid_sample` alone.
- `puppet_check.swift` is the offline check of `FacePuppet` above.
- `bench.swift` prints per-op device placement from `MLComputePlan` and prediction times for CPU+ANE, CPU+GPU and all units: `swiftc -parse-as-library -O bench.swift -o bench && ./bench <model.mlpackage>…`

Not measured: the dense-motion network's 3D convolutions on the ANE, the generator at 256 px output, any iPhone, and image quality of the FP16 conversion. The InsightFace detector LivePortrait ships with is non-commercial; Silhouette would use Vision instead, so it isn't needed.
