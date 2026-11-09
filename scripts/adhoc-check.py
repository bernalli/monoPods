#!/usr/bin/env python3
"""Check that the app and the Sparkle components carry an ad hoc signature without hardened
runtime, team identifier or entitlements. It prints only item indexes, never codesign output."""
from pathlib import Path
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError

ITEMS = ('', 'Contents/Frameworks/Sparkle.framework',
         'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
         'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app')
TIMEOUT = 60


class CheckError(Exception):
    """A failed check of the item with this index (-1 for the bundle path itself)."""

    def __init__(self, index):
        super().__init__(index)
        self.index = index


def items(app):
    """The closed list of signed items, in order; each exists and is not a link."""
    if app.is_symlink() or not app.is_dir() or not app.name.endswith('.app'):
        raise CheckError(-1)
    paths = [app / relative if relative else app for relative in ITEMS]
    for index, path in enumerate(paths):
        if path.is_symlink() or not path.exists():
            raise CheckError(index)
    return paths


def single(lines, prefix):
    """The only line that starts with prefix, or None when there is none or more than one."""
    matches = [line for line in lines if line.startswith(prefix)]
    return matches[0] if len(matches) == 1 else None


def check_display(index, path):
    result = subprocess.run(['codesign', '--display', '--verbose=2', str(path)],
                            capture_output=True, timeout=TIMEOUT)
    if result.returncode != 0:
        raise CheckError(index)
    try:
        lines = result.stderr.decode('utf-8', errors='strict').splitlines()
    except UnicodeDecodeError as error:
        raise CheckError(index) from error
    directory = single(lines, 'CodeDirectory ')
    flags = [field for field in (directory or '').split() if field.startswith('flags=')]
    if (single(lines, 'Signature=') != 'Signature=adhoc'
            or single(lines, 'TeamIdentifier=') != 'TeamIdentifier=not set'
            or len(flags) != 1 or 'adhoc' not in flags[0] or 'runtime' in flags[0]):
        raise CheckError(index)


def check_entitlements(app):
    result = subprocess.run(['codesign', '--display', '--entitlements', '-', '--xml', str(app)],
                            capture_output=True, timeout=TIMEOUT)
    if result.returncode != 0:
        raise CheckError(0)
    if not result.stdout:
        return
    try:
        value = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError, ExpatError) as error:
        raise CheckError(0) from error
    if value != {}:
        raise CheckError(0)


def main(arguments):
    if len(arguments) != 1:
        raise CheckError(-1)
    app = Path(arguments[0])
    paths = items(app)
    for index, path in enumerate(paths):
        check_display(index, path)
    check_entitlements(app)
    print(f'ad hoc signature check passed: {len(paths)} items')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except CheckError as error:
        print(f'ad hoc signature check failed: item {error.index}', file=sys.stderr)
        sys.exit(1)
    except (OSError, subprocess.SubprocessError):
        print('ad hoc signature check failed', file=sys.stderr)
        sys.exit(1)
