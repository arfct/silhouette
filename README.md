# Silhouette

Silhouette turns a real green screen into a clean, fast virtual camera for macOS.

Hang a green or blue backdrop, point your camera at it, and Silhouette removes it on the GPU. Pick the "Silhouette" camera in FaceTime, Zoom, Google Meet, Microsoft Teams, or any app that uses a Mac camera.

- Background and foreground layers: images, looping movies, solid colours, or live web pages.
- A soft drop shadow cast by your silhouette.
- Optional on-device face tracking, available to web page layers through a JavaScript API.
- An Apple camera extension: no kernel extensions and no disabled security settings.

Requires macOS 14 or later and a physical green or blue backdrop.

## Links

- [Support](https://arfct.github.io/silhouette/support/)
- [Privacy policy](https://arfct.github.io/silhouette/privacy/)
- [Terms of use](https://arfct.github.io/silhouette/terms/)

## Building from source

A minimal, GPU-only chroma keyer for macOS that outputs a virtual camera.

- Keys the camera feed in its native YCbCr 4:2:0 planes with one Metal fragment
  shader. No colour conversion before the key, no CPU copies.
- Background and foreground layers are images, looping movies, solid colours,
  or web pages (snapshotted up to 15×/s, 3×/s when static). With no
  background the output is transparent and the preview shows a checkerboard.
- Output is a CoreMediaIO camera extension, the modern replacement for DAL
  plug-ins. Zoom, FaceTime, Meet, and Photo Booth see "Silhouette" as a camera
  with no changes to those apps and nothing to disable in macOS.

### Build and install

Requires Xcode and `brew install xcodegen`. The project is signed with the
TVA9Z8LD95 team (set in `project.yml`); change it to yours if needed.

```bash
make install
```

That builds a Release app, copies it to `/Applications`, and launches it. On
first launch macOS asks you to allow the camera extension in
System Settings → General → Login Items & Extensions → Camera Extensions.
Approve it once; from then on "Silhouette" is available in any video app.

`make run` launches from the build folder for iterating on the keyer. The
virtual camera is only installed from `/Applications`.

### Use

- Click the colour swatch, then click the backdrop in the preview to pick
  the key colour. The preview shows the unkeyed image while picking.
- Any movie file works as the camera: Source → Video file…, or drop one on
  the window. The last ten movies stay in the Source menu. It loops, decodes in hardware, and 4K files run the full path.
- Face tracking runs Vision on the Neural Engine. Show on preview draws the
  landmark contours; High frame rate tracks every frame. Web pages get the
  data through `window.silhouette.on('face', fn)`: box, centre, yaw, pitch,
  roll, eyes, nose, mouth, contours, estimated distance, and pose and
  projection matrices. See the [web page API](https://arfct.github.io/silhouette/web-api/).
- No green screen handy? Pick "Sample video" in the Source menu for a real
  green screen clip, or "Test pattern" for a synthetic
  green backdrop with a face shape, fine hair strokes, a soft gradient edge,
  a moving square, and sensor-like noise.
- Controls live in a sidebar on the preview window (Cmd+K hides it).
- Layers has a Background box and a Foreground box. Each takes None, the
  test page, a URL, a file path, or a hex colour like `#1E90FF` (8 digits for
  alpha). The last ten entries are listed for reuse.
- Color Range is in percent of the chroma span: the low value is fully keyed
  out, the high value is where the transition ends. The bar shows the colours
  along that axis. Shrink pulls the matte edge in, in 1080p pixels.
- Desaturate removes green reflections.
- Blur softens the matte edge. Stabilize blends the matte with the previous
  frame's to stop edge flicker from sensor noise; large changes are treated
  as motion and pass straight through.
- Vary with distance scales the shadow with the tracked face: nearer gives
  a longer, softer, lighter shadow; farther gives a shorter, sharper, denser
  one. Slider values apply at a face 40% of the frame tall.
- Shadow adds a soft drop shadow behind you: the matte rendered at quarter
  size on a padded canvas, Gaussian-blurred on the GPU, and offset. The switch
  in its header turns it off; drag the offset pad to position it,
  double-click to reset. The Chromakey switch turns keying off entirely.
- Drop an image or a URL onto the window, or use the Background menu.
- The preview is mirrored like a mirror; the virtual camera output is not.
  View → Mirror Preview turns that off, useful when reading a web background.
- 4K keying captures at 3840×2160 when the camera supports it, runs the key,
  feather, and composite at that size, and box-downsamples to the 1080p
  output. Finer hair and edges with a 4K camera; four times the GPU work.
- The virtual camera output is always 1920×1080 at 30 fps. The camera and
  background are scaled to fill it.

### Layout

- `App/` — the macOS app: capture, Metal renderer, controls, CMIO sink client.
- `Extension/` — the camera extension: one device with a source stream (what
  other apps read) and a sink stream (what the app writes into).
- `Shared/` — constants both sides agree on.

### Distribute to other Macs

`make install` signs with your Apple Development certificate, which only runs
on Macs registered to the team. For any Mac, use Developer ID plus
notarization:

```bash
make dist
```

This archives, exports with Xcode's cloud-managed Developer ID certificate,
notarizes, staples, and writes `dist/Silhouette.zip`. One-time setup before
the first run, with an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials GreenScreen --apple-id you@example.com --team-id TVA9Z8LD95
```

For TestFlight and the Mac App Store, `make testflight` bumps the build
number, archives, signs for the App Store, and uploads to App Store Connect.
The version (`MARKETING_VERSION`) only changes when you mean to start a new
App Review version.

Without notarization the exported app still runs on other Macs, but Gatekeeper
asks you to allow it in System Settings → Privacy & Security on first launch,
and macOS might refuse to load the camera extension.

### Sandbox

The app runs in the App Sandbox (camera, outgoing network, user-selected
files). Files you pick or drop are remembered with security-scoped
bookmarks, so they reopen on the next launch. This is the configuration the
Mac App Store requires; Developer ID builds use it too.

### Performance notes

- The window's top right shows frames per second and the GPU time per frame
  for the keying pipeline (also logged under subsystem `com.artifact.Silhouette`,
  category `stats`).
- The window is one Liquid Glass sheet; the preview sits in an opaque box on
  top of it, so the glass does not recomposite at frame rate.
- Sources are consumed in their native pixel format (video range or full
  range); the shader normalises, so no conversion pass runs per frame.
- Face tracking works on a 640×360 4:2:0 copy made on the GPU. The detector
  runs about four times a second; landmarks fit every tracked frame.
- Web snapshots upload straight into a shared texture, skip when nothing
  changed, and back off to 3 per second while the page is static.

© 2026 Artifact
