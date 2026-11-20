#!/usr/bin/env bash
# Compile fluxa-shaper pour l'iPhone et le simulateur, et l'empaquette en
# FluxaShaper.xcframework, que le projet Xcode lie à l'app (voir project.yml).
set -euo pipefail
cd "$(dirname "$0")"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios >/dev/null
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo build --release --locked --target "$target"
done

# Le simulateur tourne sur les Mac Apple et Intel : une bibliothèque pour les deux.
mkdir -p target/simulator
lipo -create \
  target/aarch64-apple-ios-sim/release/libfluxa_shaper.a \
  target/x86_64-apple-ios/release/libfluxa_shaper.a \
  -output target/simulator/libfluxa_shaper.a

rm -rf FluxaShaper.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libfluxa_shaper.a -headers include \
  -library target/simulator/libfluxa_shaper.a -headers include \
  -output FluxaShaper.xcframework
