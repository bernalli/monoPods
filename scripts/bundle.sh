#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { printf 'Usage: scripts/bundle.sh [--update-channel FILE [--candidate-version N]]\n' >&2; exit 64; }
# The channel is injected at bundle time; without it the build has no updater.
info_options=()
if [[ $# -ge 1 ]]; then
  [[ $# -ge 2 && $1 == --update-channel && -n $2 ]] || usage
  info_options=(--update-channel "$2")
  shift 2
  if [[ $# -ge 1 ]]; then
    [[ $# == 2 && $1 == --candidate-version && -n $2 ]] || usage
    info_options+=(--candidate-version "$2")
    shift 2
  fi
fi
# Bind artifacts to a clean, reachable source commit before creating any output.
source_identity() {
  python3 - <<'PY'
import re
import subprocess

def git(*args):
    return subprocess.check_output(['git', *args])

commit = git('rev-parse', '--verify', 'HEAD^{commit}').decode().strip()
if re.fullmatch('[0-9a-f]{40}', commit) is None:
    raise SystemExit('Invalid source commit')
if not git('for-each-ref', '--contains=' + commit, '--format=%(refname)',
           'refs/heads', 'refs/tags', 'refs/remotes').strip():
    raise SystemExit('Source commit is not reachable from a release reference')
if subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--']).returncode != 0:
    raise SystemExit('Tracked source changes; use a clean artifact checkout')
for name in git('ls-files', '--others', '-z').split(b'\0'):
    if name and not name.startswith((b'build/', b'.build/', b'dist/')):
        raise SystemExit('Untracked source files; use a clean artifact checkout')
for entry in git('ls-files', '-v', '-z').split(b'\0'):
    if entry and (entry[:1].islower() or entry[:1] == b'S'):
        raise SystemExit('Index flags hide source changes; use a clean artifact checkout')
print(commit)
PY
}
source_commit=$(source_identity)
# Refuse existing destinations rather than removing an application or following links.
python3 - <<'PY'
from pathlib import Path
root = Path.cwd()
for path in [root / 'build', root / '.build', root / 'Assets', root / 'Resources', root / 'dist', root / 'dist/MonoPods.app']:
    if path.is_symlink() or (path.name == 'MonoPods.app' and path.exists()):
        raise SystemExit('Unsafe or existing output; choose a clean artifact checkout')
for relative in ['Assets/AppIcon.icns', 'Assets/MenuBarIcon.png', 'Assets/MenuBarIcon@2x.png',
                 'Assets/GitHubMark.pdf', 'Resources/Info.plist', 'LICENSE',
                 'ThirdParty/Sparkle-LICENSE.txt']:
    source = root / relative
    if source.is_symlink() or not source.is_file():
        raise SystemExit('Unsafe source artifact')
(root / 'dist').mkdir(exist_ok=True)
PY
flags=(--disable-sandbox --cache-path build/cache --config-path build/config --security-path build/security)
swift build -c release -debug-info-format none "${flags[@]}"
bin_path=$(swift build -c release -debug-info-format none "${flags[@]}" --show-bin-path)
python3 - "$bin_path" <<'PYVALIDATE'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.is_symlink() or not path.resolve().is_relative_to(Path.cwd() / '.build'):
    raise SystemExit('Unexpected build output')
for name in ['MonoPods']:
    binary = path / name
    if binary.is_symlink() or not binary.is_file():
        raise SystemExit('Unsafe executable')
PYVALIDATE
app=dist/MonoPods.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/MonoPods" "$app/Contents/MacOS/MonoPods"
python3 scripts/bundle-info.py Resources/Info.plist LICENSE "$app/Contents/Info.plist" ${info_options[@]+"${info_options[@]}"}
cp Assets/AppIcon.icns Assets/MenuBarIcon.png Assets/MenuBarIcon@2x.png Assets/GitHubMark.pdf "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist"
# Sparkle comes from the build products: a real directory inside .build, copied with its links.
framework_src="$bin_path/Sparkle.framework"
python3 - "$framework_src" <<'PYFRAMEWORK'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.is_symlink() or not path.is_dir() or not path.resolve().is_relative_to(Path.cwd() / '.build'):
    raise SystemExit('Unexpected framework output')
PYFRAMEWORK
mkdir -p "$app/Contents/Frameworks"
ditto "$framework_src" "$app/Contents/Frameworks/Sparkle.framework"
# Non-sandboxed apps do not need the XPC services; fewer components to sign.
python3 - "$app/Contents/Frameworks/Sparkle.framework" <<'PYXPC'
from pathlib import Path
import shutil
import sys
framework = Path(sys.argv[1])
services = framework / 'Versions/B/XPCServices'
if services.is_symlink() or not services.is_dir():
    raise SystemExit('Unexpected framework layout')
shutil.rmtree(services)
link = framework / 'XPCServices'
if not link.is_symlink():
    raise SystemExit('Unexpected framework layout')
link.unlink()
if services.exists() or services.is_symlink() or link.exists() or link.is_symlink():
    raise SystemExit('Framework services remain')
PYXPC
# The notice ships byte for byte; the pinned digest is the text of Sparkle 2.10.1.
python3 - "$app/Contents/Resources/Sparkle-LICENSE.txt" <<'PYLICENSE'
import hashlib
from pathlib import Path
import shutil
import sys
source = Path('ThirdParty/Sparkle-LICENSE.txt')
expected = '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe'
if source.is_symlink() or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    raise SystemExit('Unexpected Sparkle license')
shutil.copyfile(source, sys.argv[1])
PYLICENSE
# Keep only the system run paths and the framework one: the toolchain adds one for the build machine.
rpaths=$(python3 scripts/macho.py rpaths "$app/Contents/MacOS/MonoPods")
while IFS= read -r rpath; do
  if [[ -n "$rpath" && "$rpath" != /usr/lib/swift && "$rpath" != @loader_path && "$rpath" != @executable_path/../Frameworks ]]; then
    install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/MonoPods"
  fi
done <<< "$rpaths"
python3 scripts/macho.py check-app "$app"
# Ad hoc signatures from the inside out, without hardened runtime. The framework seal
# changes with the removal of the services, so the framework is signed after its components.
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework"
# The preliminary signature creates the Mach-O signature load command. Hashes omit
# only its embedded payload, so the final resource seal cannot create a hash cycle.
codesign --force --sign - "$app"
# Sources must still match the recorded commit after the build has read them.
[[ "$(source_identity)" == "$source_commit" ]]
python3 scripts/manifest.py write "$app" "$source_commit"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 scripts/manifest.py verify "$app" "$source_commit"
python3 scripts/adhoc-check.py "$app"
python3 scripts/artifact-scan.py bundle "$app" --forbid "$PWD" --forbid "$HOME" --exclude-prefix Contents/Frameworks/Sparkle.framework/
printf 'Built %s with ad hoc signing; no runtime or login item was started.\n' "$app"
