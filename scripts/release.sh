#!/bin/bash
# Build, check, sign with EdDSA and describe one ad hoc release; steps R1-R11 of docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  printf 'Usage: scripts/release.sh [--first-release] [--candidate-version N --staging-dir DIR]\n' >&2
  exit 64
}
stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
first=0
candidate=
staging=
seen_candidate=0
seen_staging=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --first-release)
      [[ $first == 0 ]] || usage
      first=1; shift ;;
    --candidate-version)
      [[ $# -ge 2 && $seen_candidate == 0 ]] || usage
      seen_candidate=1; candidate=$2; shift 2 ;;
    --staging-dir)
      [[ $# -ge 2 && $seen_staging == 0 ]] || usage
      seen_staging=1; staging=$2; shift 2 ;;
    *) usage ;;
  esac
done
if [[ $seen_candidate == 1 || $seen_staging == 1 ]]; then
  [[ $seen_candidate == 1 && $seen_staging == 1 && $first == 0 ]] || usage
  [[ $candidate =~ ^[1-9][0-9]{0,8}$ && $staging == /* ]] || usage
fi
[[ ${MONOPODS_SPARKLE_ACCOUNT:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || usage
account=$MONOPODS_SPARKLE_ACCOUNT
receipt=${MONOPODS_RECEIPT:-}
# Paths are judged before any step: absolute, normalized, and the receipt outside the repository.
python3 - "$receipt" "$staging" <<'PY' || exit 64
import os
from pathlib import Path
import subprocess
import sys

receipt, staging = sys.argv[1], sys.argv[2]

def normalized(value):
    return value.startswith('/') and os.path.normpath(value) == value

root = Path.cwd().resolve()
roots = {root}
if (root / '.git').exists():
    common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True, check=True).stdout.strip()
    if Path(common).name == '.git':
        roots.add(Path(common).resolve().parent)
if not normalized(receipt) or not Path(receipt).parent.is_dir():
    raise SystemExit(1)
if any(Path(receipt).parent.resolve().is_relative_to(parent) for parent in roots):
    raise SystemExit(1)
if staging and not normalized(staging):
    raise SystemExit(1)
PY
[[ ! -e $receipt && ! -L $receipt ]] || stop 'the receipt already exists'
# Each build starts from an empty dist folder, so no earlier artifact can be described.
python3 - <<'PY' || stop 'dist must be absent or an empty folder'
from pathlib import Path
dist = Path('dist')
if dist.is_symlink() or (dist.exists() and (not dist.is_dir() or any(dist.iterdir()))):
    raise SystemExit(1)
PY
if [[ -n $candidate ]]; then
  python3 - "$staging" <<'PY' || stop 'the staging folder must be an existing folder without links'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.is_symlink() or not path.is_dir() or path.resolve() != path:
    raise SystemExit(1)
PY
  staged_image=$staging/MonoPods-$candidate.dmg
  staged_feed=$staging/appcast-$candidate.xml
  for output in "$staged_image" "$staged_feed"; do
    [[ ! -e $output && ! -L $output ]] || stop 'a candidate output already exists'
  done
fi

# R1: the pinned Sparkle tools.
tools=$(scripts/sparkle-tools.sh)
# R2: the account's key must be the key every installation trusts.
published=$(python3 - <<'PY'
import runpy
read_channel = runpy.run_path('scripts/bundle-info.py')['read_channel']
print(read_channel('Resources/UpdateChannel.json')[1])
PY
) || stop 'invalid update channel file'
key=$("$tools/bin/generate_keys" --account "$account" -p) || stop 'cannot read the public key'
[[ -n $published && $key == "$published" ]] || stop 'the public key differs from Resources/UpdateChannel.json'
# R3: every gate of the repository.
scripts/check.sh
# R4: the bundle with the production channel.
if [[ -n $candidate ]]; then
  scripts/bundle.sh --update-channel Resources/UpdateChannel.json --candidate-version "$candidate"
else
  scripts/bundle.sh --update-channel Resources/UpdateChannel.json
fi
# R5: ad hoc signatures and the manifest, before any image exists.
python3 scripts/adhoc-check.py dist/MonoPods.app
python3 scripts/manifest.py verify dist/MonoPods.app
# R6: the disk image.
scripts/dmg.sh
# R7: the EdDSA signature of the image, verified with the same account.
sig=$("$tools/bin/sign_update" --account "$account" -p dist/MonoPods.dmg)
[[ -n $sig ]] || stop 'empty signature'
"$tools/bin/sign_update" --account "$account" --verify dist/MonoPods.dmg "$sig"
version=$(python3 - <<'PY'
import plistlib
info = plistlib.loads(open('dist/MonoPods.app/Contents/Info.plist', 'rb').read())
print(info['CFBundleShortVersionString'], info['CFBundleVersion'])
PY
)
short=${version% *}
build=${version#* }
pub_date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
# R8: the feed, checked against the bundle, the image and the published feed.
if [[ -n $candidate ]]; then
  ditto dist/MonoPods.dmg "$staged_image"
  appcast=$staged_feed
  python3 scripts/appcast.py build --candidate --bundle dist/MonoPods.app --dmg "$staged_image" \
    --signature "$sig" --download-url "file://$staged_image" --pub-date "$pub_date" --output "$appcast"
  python3 scripts/appcast.py check --candidate --appcast "$appcast" --bundle dist/MonoPods.app --dmg "$staged_image"
else
  previous=()
  if curl -fsSL --proto '=https' --tlsv1.2 https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml \
    -o dist/previous-appcast.xml; then
    [[ $first == 0 ]] || stop 'a published feed exists: this is not the first release'
    previous=(--previous dist/previous-appcast.xml)
  else
    [[ $first == 1 ]] || stop 'the published feed is unreachable; use --first-release only for the first release'
    rm -f dist/previous-appcast.xml
  fi
  appcast=dist/appcast.xml
  python3 scripts/appcast.py build --bundle dist/MonoPods.app --dmg dist/MonoPods.dmg --signature "$sig" \
    --download-url "https://github.com/bernalli/monoPods/releases/download/v$short/MonoPods.dmg" \
    --pub-date "$pub_date" --output "$appcast"
  python3 scripts/appcast.py check --appcast "$appcast" --bundle dist/MonoPods.app --dmg dist/MonoPods.dmg \
    ${previous[@]+"${previous[@]}"}
fi
# R9: the receipt outside the repository.
python3 scripts/release-receipt.py dist/MonoPods.app dist/MonoPods.dmg "$receipt" --appcast "$appcast"
# R10: no path of the build machine in the bundle.
python3 scripts/artifact-scan.py bundle dist/MonoPods.app --forbid "$PWD" --forbid "$HOME" \
  --exclude-prefix Contents/Frameworks/Sparkle.framework/
# R11: the marker is printed only when every step succeeded.
printf '___RELEASE_END ok version=%s build=%s___\n' "$short" "$build"
