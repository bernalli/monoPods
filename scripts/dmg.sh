#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
root = Path.cwd()
for path in [root / 'dist', root / 'dist/MonoPods.app']:
    if path.is_symlink() or not path.is_dir():
        raise SystemExit('Bundle missing or unsafe')
if (root / 'dist/MonoPods.dmg').exists() or (root / 'dist/MonoPods.dmg').is_symlink():
    raise SystemExit('Refusing existing DMG')
PY
codesign --verify --strict dist/MonoPods.app
python3 scripts/manifest.py verify dist/MonoPods.app
stage=$(mktemp -d "$PWD/dist/.dmg.XXXXXX")
# This trap removes only this invocation's exact, freshly created staging directory.
trap 'python3 - "$stage" <<'"'"'PY'"'"'
from pathlib import Path
import shutil, sys
path = Path(sys.argv[1])
assert not path.is_symlink() and path.parent == Path.cwd() / "dist" and path.name.startswith(".dmg.")
shutil.rmtree(path)
PY' EXIT
# ditto preserves the framework links exactly as signed.
ditto dist/MonoPods.app "$stage/MonoPods.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname MonoPods -srcfolder "$stage" -format UDZO -o dist/MonoPods.dmg
hdiutil verify dist/MonoPods.dmg
# Read-only mounting is a separate acceptance operation, never implicit in packaging.
if [[ ${MONOPODS_VERIFY_MOUNT:-0} == 1 ]]; then
  mountpoint=$(mktemp -d "${TMPDIR:-/tmp}/monopods-mount.XXXXXX")
  hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" dist/MonoPods.dmg
  test -d "$mountpoint/MonoPods.app"
  test -L "$mountpoint/MonoPods.app/Contents/Frameworks/Sparkle.framework/Versions/Current"
  test "$(readlink "$mountpoint/Applications")" = /Applications
  hdiutil detach "$mountpoint"
  rmdir "$mountpoint"
fi
