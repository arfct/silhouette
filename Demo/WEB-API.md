# Silhouette web page API

Any web page used as a background can react to the tracked face. The app
injects a small object, `window.silhouette`, into every frame of the page
before the page's own scripts run.

## Subscribing

```js
silhouette.on('face', face => { /* called ~15 times a second */ });
console.log(silhouette.face);   // the most recent face object, or null
```

Events arrive only while "Track face and eyes" is on in the sidebar and the
page is the active background.

## The face object

All coordinates are normalised to the output frame (0…1), origin top-left,
in the unmirrored image the virtual camera sends. Angles are degrees. Keys
for values that could not be measured are absent, so use optional chaining.

| Key | Meaning |
|---|---|
| `t` | Timestamp in seconds (monotonic) |
| `detected` | `false` when no face is in frame; the other keys are then absent |
| `box` | `{x, y, w, h}` face bounding box |
| `center` | `{x, y}` centre of the box |
| `yaw`, `pitch`, `roll` | Head pose. Yaw negative when turned to the image's left |
| `leftEye`, `rightEye` | `{x, y, open}`; left and right as seen in the image. `x, y` is the pupil when available. `open` is the eye's height ÷ width, roughly 0.3 open, under 0.18 closed |
| `nose` | `{x, y}` nose centre |
| `mouth` | `{x, y, open}` inner-lip centre and height ÷ width |
| `distance` | Estimated metres from the camera, from eye separation (box height when an eye is hidden). Assumes a 63 mm interpupillary distance and a 70° horizontal field of view, so treat it as relative |
| `position` | `{x, y, z}` head centre in camera space, metres: x right, y up, z away from the camera |
| `pose` | Column-major 4×4 matrix, camera space: rotation from yaw/pitch/roll plus `position`. Forward (toward the camera) is `pose × (0, 0, -1, 0)` |
| `projection` | Column-major 4×4 perspective matrix for the assumed camera (16:9, near 0.1 m, far 10 m). `projection × pose × point` gives clip space, so WebGL or CSS 3D can place things on the head |
| `contours` | `{faceContour, leftEyebrow, rightEyebrow, noseCrest, nose, leftEye, rightEye, outerLips, innerLips, medianLine}`, each an array of `{x, y}` in output coordinates |

## How the page reaches the output

The page renders in a hidden 1920×1080 web view. The app snapshots it about
15 times a second while its pixels change and backs off to 3 a second when
they don't, then uses the snapshot as the layer behind the keyed person.
Expect roughly 70–100 ms between a face event and the matching pixels in
the output.

## Notes

- The page is the background, so the person covers its centre. Put
  readouts near the edges, or draw things that are meant to sit behind the
  head, like the plane in the bundled test page.
- The output is not mirrored, but the app's preview is. Text that should
  read correctly in the preview needs `transform: scaleX(-1)`; text for the
  people on the call should not be mirrored.
- Snapshots cost WebKit GPU time. Avoid `backdrop-filter`, continuous CSS
  transitions, and animation loops; move things only when a face event
  arrives.
- `Demo/face.html` is the bundled test page and the reference example.
