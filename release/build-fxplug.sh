#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds vendor/fxplug (Mecena Stabilize's engine for Final Cut Pro) as a static library with the patched core:
#   fcp/build/lib/libmecena_fxplug.a      (arm64)
set -euo pipefail
source "$(dirname "$0")/prepare-core.sh"
# the versions of the OpenFX build (same core and dependencies)
cp "$src/vendor/openfx/Cargo.lock" "$src/vendor/fxplug/Cargo.lock"
cargo build --offline --release --manifest-path "$src/vendor/fxplug/Cargo.toml"
mkdir -p fcp/build/lib
cp "$CARGO_TARGET_DIR/release/libmecena_fxplug.a" fcp/build/lib/
ls -la fcp/build/lib/libmecena_fxplug.a
