---
title: Silhouette
date: 2026-10
category: product
tags: [macos]
url: https://arfct.github.io/silhouette/
links:
  testflight: https://testflight.apple.com/join/EmuWevCK
  source: https://github.com/arfct/silhouette
media:
  - src: sample-video.jpg
    caption: A frame of the sample video bundled with the app, a green-screen clip that the Source menu offers in place of a camera
    alt: A person with blonde hair tied up, in a cream leather jacket over a black top, facing the camera in front of an evenly lit green backdrop
unconfirmed: [date]
---

Silhouette appears to FaceTime, Zoom, Google Meet and Microsoft Teams as one more camera, and what it sends them is the Mac's camera image with a green or blue backdrop removed. The keying is done on the GPU by a single Metal shader. It works on the image in the YCbCr form the camera delivers, with no color conversion beforehand. When a source is first chosen, the key color is taken from the dominant color around the edge of the frame, skipping the face and the body under it.

A background layer and a foreground layer can each hold an image, a looping movie, a solid color or a live web page. A drop shadow is cast from the outline of the person, blurred and offset behind them, and it can vary with distance, growing longer, softer and lighter as the tracked face comes nearer. Face tracking runs on the Mac. A web page used as a background can read the face's position and pose through a JavaScript API, about fifteen times a second.

The preview is mirrored, as a mirror would show it, while the camera's output is not. That output is always 1920×1080 at 30 frames per second, from an Apple camera extension that needs no security setting in macOS turned off. Without a backdrop, a Background Removal mode finds the person by segmentation on the device, and without a camera the app can key a movie file, such as the bundled clip in the image. Silhouette is in beta on TestFlight and requires macOS 26 or later.

Swift, Metal. 2026.
