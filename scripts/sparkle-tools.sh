#!/bin/bash
# Print the folder of the pinned Sparkle command line tools, downloading once and verifying every use.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 0 ]] || { printf 'Usage: scripts/sparkle-tools.sh\n' >&2; exit 64; }
SPARKLE_VERSION=2.10.1
SPARKLE_SPM_SHA256=4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a
url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
cache=build/sparkle-tools
archive=$cache/Sparkle-for-Swift-Package-Manager.zip
tools=$cache/$SPARKLE_VERSION
# Every cache level is a real folder: a link could redirect the tools to another place.
python3 - "$cache" "$tools" <<'PY'
from pathlib import Path
import sys
cache, tools = Path(sys.argv[1]), Path(sys.argv[2])
for path in (cache.parent, cache, tools):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise SystemExit('Unsafe Sparkle tools cache')
cache.mkdir(parents=True, exist_ok=True)
PY
digest() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}
partial=
stage=
cleanup() {
  [[ -z $partial ]] || rm -f -- "$partial"
  [[ -z $stage ]] || rm -rf -- "$stage"
}
trap cleanup EXIT
if [[ ! -e $archive ]]; then
  # The download becomes the archive only after its digest matches the pin.
  partial=$(mktemp "$PWD/$cache/.download.XXXXXX")
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$partial" >&2
  if [[ $(digest "$partial") != "$SPARKLE_SPM_SHA256" ]]; then
    printf 'Sparkle archive digest mismatch\n' >&2
    exit 1
  fi
  mv -- "$partial" "$archive"
  partial=
fi
if [[ -L $archive || ! -f $archive || $(digest "$archive") != "$SPARKLE_SPM_SHA256" ]]; then
  printf 'Sparkle archive digest mismatch\n' >&2
  exit 1
fi
if [[ ! -e $tools ]]; then
  # Extraction goes to a fresh folder that is renamed only when complete.
  stage=$(mktemp -d "$PWD/$cache/.extract.XXXXXX")
  ditto -x -k "$archive" "$stage" >&2
  mv -- "$stage" "$tools"
  stage=
fi
python3 - "$archive" "$tools" <<'PY'
import hashlib
from pathlib import Path
import stat
import sys
import zipfile

archive, root = Path(sys.argv[1]), Path(sys.argv[2])

def digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.digest()

try:
    with zipfile.ZipFile(archive) as source:
        for name in ("generate_keys", "sign_update"):
            member = f"bin/{name}"
            entries = [item for item in source.infolist()
                       if item.filename == member]
            path = root / member
            if (len(entries) != 1
                    or (root / "bin").is_symlink()
                    or not (root / "bin").is_dir()
                    or not stat.S_ISREG(path.lstat().st_mode)
                    or path.stat().st_size != entries[0].file_size):
                raise ValueError()
            with source.open(entries[0]) as expected, path.open("rb") as actual:
                if digest(expected) != digest(actual):
                    raise ValueError()
except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
    raise SystemExit("Sparkle tools differ from the pinned archive")
PY
for tool in generate_keys sign_update; do
  path=$PWD/$tools/bin/$tool
  if [[ -L $path || ! -f $path ]]; then
    printf 'Sparkle tool missing: %s\n' "$tool" >&2
    exit 1
  fi
  codesign --verify --strict "$path" >&2 || { printf 'Sparkle tool signature invalid: %s\n' "$tool" >&2; exit 1; }
done
printf '%s\n' "$PWD/$tools"
