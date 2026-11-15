#!/usr/bin/env python3
"""Check that the app and the Sparkle components carry a timestamped Developer ID signature
with the hardened runtime, one team for all of them and no entitlements. It prints only item
indexes, never codesign output."""

from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.parsers.expat import ExpatError

ITEMS = (
    "",
    "Contents/Frameworks/Sparkle.framework",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
)
TIMEOUT = 60
TEAM = re.compile(r"[A-Z0-9]{10}")
LEAF = re.compile(
    r"Authority=Developer ID Application: (?P<name>.+) \((?P<team>[A-Z0-9]{10})\)"
)
INTERMEDIATE = "Authority=Developer ID Certification Authority"
ROOT = "Authority=Apple Root CA"
FLAGS = re.compile(r"flags=0x(?P<value>[0-9a-fA-F]+)(?:\([^()\s]*\))?")
RUNTIME = 0x10000
ADHOC = 0x2


class CheckError(Exception):
    """A failed check of the item with this index (-1 for the bundle path itself)."""

    def __init__(self, index: int) -> None:
        super().__init__(index)
        self.index = index


def items(app: Path) -> list[Path]:
    """The closed list of signed items, in order; each exists and is not a link."""
    if app.is_symlink() or not app.is_dir() or not app.name.endswith(".app"):
        raise CheckError(-1)
    paths = [app / relative if relative else app for relative in ITEMS]
    for index, path in enumerate(paths):
        if path.is_symlink() or not path.exists():
            raise CheckError(index)
    return paths


def only(lines: list[str], prefix: str, index: int) -> str:
    """The value after prefix on the only line that starts with it; any other count fails."""
    matches = [line for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        raise CheckError(index)
    return matches[0][len(prefix) :]


def team_of(index: int, lines: list[str]) -> str:
    """The team of one item, after every required field matched its closed form."""
    directory = only(lines, "CodeDirectory ", index)
    flags = [field for field in directory.split() if field.startswith("flags=")]
    if len(flags) != 1:
        raise CheckError(index)
    match = FLAGS.fullmatch(flags[0])
    if match is None:
        raise CheckError(index)
    value = int(match.group("value"), 16)
    if not value & RUNTIME or value & ADHOC:
        raise CheckError(index)
    team = only(lines, "TeamIdentifier=", index)
    if TEAM.fullmatch(team) is None:
        raise CheckError(index)
    if not only(lines, "Timestamp=", index).strip():
        raise CheckError(index)
    if any(line.startswith(("Signed Time=", "Signature=adhoc")) for line in lines):
        raise CheckError(index)
    authorities = [line for line in lines if line.startswith("Authority=")]
    if len(authorities) != 3 or authorities[1:] != [INTERMEDIATE, ROOT]:
        raise CheckError(index)
    leaf = LEAF.fullmatch(authorities[0])
    if leaf is None or not leaf.group("name").strip() or leaf.group("team") != team:
        raise CheckError(index)
    return team


def check_display(index: int, path: Path) -> str:
    result = subprocess.run(
        ["codesign", "--display", "--verbose=2", str(path)],
        capture_output=True,
        timeout=TIMEOUT,
    )
    if result.returncode != 0:
        raise CheckError(index)
    try:
        result.stdout.decode("utf-8", errors="strict")
        lines = result.stderr.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as error:
        raise CheckError(index) from error
    return team_of(index, lines)


def check_entitlements(app: Path) -> None:
    result = subprocess.run(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
        capture_output=True,
        timeout=TIMEOUT,
    )
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


def main(arguments: list[str]) -> None:
    if len(arguments) != 1:
        raise CheckError(-1)
    app = Path(arguments[0])
    paths = items(app)
    teams = []
    for index, path in enumerate(paths):
        teams.append(check_display(index, path))
        if teams[index] != teams[0]:
            raise CheckError(index)
    check_entitlements(app)
    print(f"Developer ID signature check passed: {len(paths)} items")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except CheckError as error:
        print(
            f"Developer ID signature check failed: item {error.index}", file=sys.stderr
        )
        sys.exit(1)
    except (OSError, subprocess.SubprocessError):
        print("Developer ID signature check failed", file=sys.stderr)
        sys.exit(1)
