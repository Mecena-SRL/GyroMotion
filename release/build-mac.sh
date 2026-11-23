#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare-core.sh"
cargo build --locked --release --manifest-path "$src/vendor/openfx/Cargo.toml"
bundle="$target_dir/MecenaMotion.ofx.bundle"
bin="$bundle/Contents/MacOS/MecenaMotion.ofx"
mkdir -p "$(dirname "$bin")" "$bundle/Contents/Resources"
cp "$CARGO_TARGET_DIR/release/libgyroflow_ofx.dylib" "$bin"
cp release/Info.plist "$bundle/Contents/"
cp LICENSE "$bundle/Contents/Resources/GPL-3.txt"
for dep in $(otool -L "$bin" | tail -n +2 | awk '{print $1}'); do
    case "$dep" in /System/Library/*|/usr/lib/*) ;; *)
        # A linked dylib lists itself as LC_ID_DYLIB; that entry is not a dependency.
        [[ "$dep" == "$(otool -D "$bin" | tail -1)" ]] || { echo "Dipendenza esterna: $dep"; exit 2; }
    esac
done
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
c++ -std=c++17 -O2 -I SDK tests/bundle.cpp -o "$target_dir/check"
"$target_dir/check" "$bin"
c++ -std=c++17 -O2 -DTEST_PACKAGED_OFX -I SDK -I src tests/host.cpp -o "$target_dir/shutter"
"$target_dir/shutter" "$bin"
c++ -std=c++17 -O3 -DTEST_PACKAGED_OFX -I SDK -I src tests/cinema.cpp -o "$target_dir/cinema"
"$target_dir/cinema" "$bin"
mkdir -p dist
c++ -std=c++17 -O3 -fobjc-arc -I src src/shutter_metal.mm tests/metal_benchmark.mm -framework Metal -framework Foundation -o "$target_dir/metal-check"
"$target_dir/metal-check" | tee dist/Shutter-Metal.txt
ditto -c -k --keepParent "$bundle" "dist/MecenaMotion-0.10.0-$(uname -m).zip"
