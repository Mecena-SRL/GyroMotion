#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# How much Mecena Stabilize corrects a clip, with the engine of the Final Cut effect:  release/probe-fxplug.sh FILE [MODE] [ZOOM]
set -euo pipefail
source "$(dirname "$0")/prepare-core.sh"
cp "$src/vendor/openfx/Cargo.lock" "$src/vendor/fxplug/Cargo.lock"
cargo run --quiet --offline --release --manifest-path "$src/vendor/fxplug/Cargo.toml" --example "${EXAMPLE:-probe}" -- "$@"
