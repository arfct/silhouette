#!/bin/sh
# Fetch the face puppet's Core ML models into App/Models, where Xcode compiles
# them into the app. They stay out of git. Without them the puppet still runs:
# an ellipsoid head instead of the depth model, and the original image behind
# the head instead of LaMa's clean plate.
#
# - Depth Anything V2 Small, Apple's Core ML conversion (Apache 2.0, 48 MB):
#   the portrait's depth, once per image.
# - LaMa (big-lama, Apache 2.0), converted by john-rocky and mirrored at
#   gumka/lama-coreml: fills the background behind the subject, once per image.
set -e
cd "$(dirname "$0")/.."

fetch() {   # fetch <dest .mlpackage> <base url of the .mlpackage>
  dest=$1; base=$2
  if [ -d "$dest" ]; then echo "already present: $dest"; return; fi
  mkdir -p "$dest/Data/com.apple.CoreML/weights"
  curl -fsSL "$base/Manifest.json" -o "$dest/Manifest.json"
  curl -fsSL "$base/Data/com.apple.CoreML/model.mlmodel" -o "$dest/Data/com.apple.CoreML/model.mlmodel"
  curl -fsSL "$base/Data/com.apple.CoreML/weights/weight.bin" -o "$dest/Data/com.apple.CoreML/weights/weight.bin"
  echo "fetched $dest"
}

fetch App/Models/DepthAnythingV2SmallF16.mlpackage \
  https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage
fetch App/Models/LaMa.mlpackage \
  https://huggingface.co/gumka/lama-coreml/resolve/main/LaMa.mlpackage
