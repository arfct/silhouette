# Silhouette: App Store listing

Copy for App Store Connect, field by field. Character counts are checked against Apple's limits.

## Name (30)

Silhouette - Fast Chroma Key

## Subtitle (30)

Green screen virtual camera

## Promotional text (170)

Key a real green screen on the GPU and send yourself to any video app as a camera. Put an image, a movie, a colour, or a live web page behind you.

## Keywords (100)

green screen,virtual camera,webcam,background,keyer,matte,backdrop,video call,overlay,streaming

## Description (4000)

Silhouette turns a real green screen into a clean, fast virtual camera.

Hang a green or blue backdrop, point your camera at it, and Silhouette removes it on the GPU. What's left is you, placed in front of whatever you choose. Pick the "Silhouette" camera in FaceTime, Zoom, Google Meet, Microsoft Teams, or any app that uses a Mac camera.

A REAL KEY, NOT A GUESS
AI background blur guesses where you end and the room begins, so hair flickers and hands vanish. A chroma key measures colour, so edges stay crisp, frame after frame. Silhouette keys your camera in its native colour format in a single Metal pass, typically in about a millisecond of GPU time, so it stays cool and quiet during long calls.

LAYERS
• Background: an image, a looping movie, a solid colour, or a live web page.
• Foreground: anything on top of you, such as a transparent PNG, a web page with a transparent background, or a colour wash with alpha.
• Type a URL, a file path, or a hex colour like #1E90FF, or pick from your recent choices.

SHADOW
Add a soft drop shadow cast by your silhouette, so you sit in the scene instead of floating on it. Set opacity, size, and offset. Turn on Vary with distance and the shadow grows softer as you lean in and sharper as you sit back.

FACE TRACKING
Optional face, head pose, and eye tracking runs on the Neural Engine. Web page layers receive the data through a small JavaScript API, so a page can follow your head, react when you look away, or place graphics on your face. A sample page is built in.

CONTROLS THAT STAY OUT OF THE WAY
• Click the colour swatch, then click your backdrop. Or press Auto.
• Color Range shows the actual colours being removed.
• Shrink, Blur, Desaturate, and Stabilize clean up edges, spill, and sensor flicker.
• Values are measured on the 1080p output, so settings carry over between a 720p webcam and a 4K camera.
• Optional 4K keying for finer hair, downsampled to a sharp 1080p output.

BUILT THE MODERN WAY
Silhouette's virtual camera is an Apple camera extension, the current macOS way to add a camera. There are no kernel extensions, no disabled security settings, and nothing to install in other apps. You approve the extension once in System Settings.

PRIVATE BY DESIGN
Your video is processed on your Mac and goes only to the apps you choose. Silhouette has no account, no analytics, and no tracking.

Also included: a test pattern and movie-file input for setting up without a camera, a mirrored preview, light and dark appearance, and built-in help.

Requires a physical green or blue backdrop and macOS 14 or later.

## Support URL

https://arfct.github.io/silhouette/support/

## Marketing URL (optional)

https://arfct.github.io/silhouette/

## Copyright

2026 Artifact

## Category

Primary: Photo & Video. Secondary: Productivity.

## Age rating notes

Answer "No" to every question, including Unrestricted Web Access. The result is 4+.

Silhouette is not a web browser. Web pages are compositing sources, like images or movies: drawn off screen, scaled, and mirrored into the video frame, with no address bar, navigation, links, or input. The App Review notes explain this so the reviewer sees the reasoning.

## App Privacy

- Data collection: Data Not Collected.
- Privacy policy URL: https://arfct.github.io/silhouette/privacy/

## App Review notes (4000)

Silhouette is a chroma keyer that publishes its output as a virtual camera through a CoreMediaIO camera extension (embedded system extension, category com.apple.system_extension.cmio).

Testing without a green screen:
1. Launch Silhouette from /Applications. When prompted, allow camera access.
2. In the Source menu, choose "Sample video", a bundled green screen clip, or "Test pattern". The green is keyed out in the preview.
3. In Layers, set Background to "Test page" or type a colour such as #1E90FF to see the composite.

Testing the virtual camera:
1. On first launch macOS asks to allow the camera extension. Approve it in System Settings > General > Login Items & Extensions > Camera Extensions.
2. Open FaceTime or Photo Booth and choose "Silhouette" as the camera. The composite from step 3 appears there.

About web page layers:
Silhouette is not a web browser. The Background and Foreground layers can render a web page the user specifies, purely as a compositing source, like an image or a movie. The page is drawn off screen into a texture, then scaled and mirrored into the video frame. It is never shown as an interactive page: there is no address bar, no navigation, no links to follow, and no way to click, scroll, or type into it. For that reason we answered No to Unrestricted Web Access in the age rating. NSAllowsArbitraryLoads is set so these compositing pages can come from any address the user provides.

Notes:
- No account or sign-in is needed.
- Face tracking uses Vision on device; nothing leaves the Mac.

## App Sandbox information

Justifications for each entitlement, for the App Sandbox Information section:

| Entitlement | Why |
|---|---|
| com.apple.security.device.camera | Reads the physical camera to key it. |
| com.apple.security.network.client | Loads web pages the user chooses as background or foreground layers. |
| com.apple.security.files.user-selected.read-only | Opens images and movies the user picks as layers or as the video source. |
| com.apple.security.files.bookmarks.app-scope | Reopens those user-chosen files on the next launch. |
| com.apple.developer.system-extension.install | Installs the embedded camera extension that provides the virtual camera. |

## Screenshots

Mac screenshots must be 1280×800, 1440×900, 2560×1600, or 2880×1800, up to 10. Suggested set:

1. The main window keying a person onto a scenic image, sidebar visible. Caption: "A real chroma key, on the GPU."
2. The same frame selected as the camera in FaceTime. Caption: "Shows up as a camera in any video app."
3. A web page background reacting to face tracking. Caption: "Live web pages, driven by your face."
4. Foreground overlay (lower-third PNG) plus shadow. Caption: "Layers in front and behind."
5. The Chromakey section close-up with the Color Range bar. Caption: "See exactly which colours disappear."
