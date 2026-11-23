# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by build-mac.sh and build-fxplug.sh: a disposable copy of the sources with the patched Gyroflow core.
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Questa build richiede macOS e il suo SDK."; exit 1; }
target_dir=$(mktemp -d)
trap 'rm -rf "$target_dir"' EXIT
export CARGO_TARGET_DIR="$target_dir/target"
# Patch only a private build checkout. The installed bundle cannot consult the user's lens database.
src="$target_dir/src"
mkdir -p "$src"
cp -R SDK src vendor "$src/"
core="$src/gyroflow"
rev=a298bec3844c0bf070ad001080ec67a411a68791
git clone --quiet --no-checkout "${MECENA_CORE_REPO:-https://github.com/gyroflow/gyroflow.git}" "$core"
git -C "$core" checkout --quiet --detach "$rev"
git -C "$core" submodule update --init --recursive
# Normalize the patched files in this disposable checkout before git apply.
python3 - "$core" <<'PYLINES'
from pathlib import Path
import sys
for name in ("lens_profile_database.rs", "lib.rs", "stabilization/mod.rs", "stabilization/frame_transform.rs", "gyro_source/mod.rs"):
    path = Path(sys.argv[1]) / "src/core" / name
    data = path.read_bytes()
    if b"\r\n" in data:
        path.write_bytes(data.replace(b"\r\n", b"\n"))
PYLINES
git -C "$core" apply --check "$PWD/release/embedded-only.patch"
git -C "$core" apply "$PWD/release/embedded-only.patch"
git -C "$core" apply --check "$PWD/release/master.patch"
git -C "$core" apply "$PWD/release/master.patch"
git -C "$core" apply --check "$PWD/release/shutter-time.patch"
git -C "$core" apply "$PWD/release/shutter-time.patch"
python3 - "$src" <<'PYCORE'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
p=root/'vendor/common/Cargo.toml'
s=p.read_text().replace('git = "https://github.com/gyroflow/gyroflow.git", default-features = false, rev = "a298bec"', 'path = "../../gyroflow/src/core", default-features = false')
p.write_text(s)
for lock in ('openfx', 'fxplug'):
    p=root/'vendor'/lock/'Cargo.lock'
    if p.exists():
        p.write_text(''.join(l for l in p.read_text().splitlines(True) if not l.startswith('source = "git+https://github.com/gyroflow/gyroflow.git?rev=a298bec#')))
PYCORE
