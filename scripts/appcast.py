#!/usr/bin/env python3
"""Write and verify the single-item update feed of a release, with a closed schema."""

import base64
import binascii
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import re
import stat
import sys

FEED_LIMIT = 64 * 1024
PLIST_LIMIT = 1024 * 1024
SIGNATURE_BYTES = 64
PRODUCTION_URL = (
    "https://github.com/bernalli/monoPods/releases/download/v{short}/MonoPods.dmg"
)
CANDIDATE_NAME = "MonoPods-{build}.dmg"
FIELDS = (
    "title_short",
    "date",
    "build",
    "short",
    "minimum",
    "url",
    "length",
    "signature",
)
TEMPLATE = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
    "  <channel>\n"
    "    <title>MonoPods</title>\n"
    "    <item>\n"
    "      <title>Version {title_short}</title>\n"
    "      <pubDate>{date}</pubDate>\n"
    "      <sparkle:version>{build}</sparkle:version>\n"
    "      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>\n"
    '      <enclosure url="{url}" length="{length}" type="application/octet-stream" '
    'sparkle:edSignature="{signature}"/>\n'
    "    </item>\n"
    "  </channel>\n"
    "</rss>\n"
)
BUILD = re.compile("[1-9][0-9]{0,8}")
SHORT = re.compile("[0-9]+\\.[0-9]+\\.[0-9]+")
MINIMUM = re.compile("[0-9]+\\.[0-9]+(\\.[0-9]+)?")
LENGTH = re.compile("0|[1-9][0-9]{0,14}")
PATH_CHARACTERS = re.compile("[A-Za-z0-9._/-]+")
DATE_FORMAT = "%a, %d %b %Y %H:%M:%S +0000"
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)
USAGE = (
    "Usage: appcast.py build --bundle APP --dmg DMG --signature SIG --download-url URL "
    "--pub-date DATE --output FILE [--candidate]\n"
    "       appcast.py check --appcast FILE [--bundle APP --dmg DMG] [--candidate] "
    "[--previous FILE]"
)


class UsageError(Exception):
    """The command line does not match the normative usage."""


def _pattern():
    """The template as a regular expression: every value is one run of characters that
    cannot open or close markup, so the text around the values must match byte for byte."""
    text = re.escape(TEMPLATE)
    for name in FIELDS:
        text = text.replace(re.escape("{" + name + "}"), f'(?P<{name}>[^<>&"\\n\\r]*)')
    return re.compile(text)


PATTERN = _pattern()


def format_date(moment):
    """RFC 2822 date in UTC with English names, whatever the locale."""
    return (
        f"{WEEKDAYS[moment.weekday()]}, {moment.day:02d} {MONTHS[moment.month - 1]} "
        f"{moment.year:04d} {moment.hour:02d}:{moment.minute:02d}:{moment.second:02d} +0000"
    )


def check_date(value):
    """Accept only the canonical form, so the weekday must agree with the date."""
    parts = value.split(" ")
    if len(parts) != 6 or parts[5] != "+0000":
        raise ValueError("invalid publication date")
    try:
        month = MONTHS.index(parts[2]) + 1
        clock = parts[4].split(":")
        if len(clock) != 3 or not all(
            len(piece) == 2 and piece.isascii() and piece.isdigit() for piece in clock
        ):
            raise ValueError("invalid publication date")
        if not (
            parts[1].isascii()
            and parts[1].isdigit()
            and parts[3].isascii()
            and parts[3].isdigit()
        ):
            raise ValueError("invalid publication date")
        moment = datetime(
            int(parts[3]),
            month,
            int(parts[1]),
            int(clock[0]),
            int(clock[1]),
            int(clock[2]),
            tzinfo=timezone.utc,
        )
    except (ValueError, OverflowError) as error:
        raise ValueError("invalid publication date") from error
    if format_date(moment) != value:
        raise ValueError("invalid publication date")


def check_signature(value):
    """Standard base64 of exactly 64 bytes, in its canonical spelling."""
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("invalid signature") from error
    if (
        len(decoded) != SIGNATURE_BYTES
        or base64.b64encode(decoded).decode("ascii") != value
    ):
        raise ValueError("invalid signature")


def candidate_path(url, build):
    """The absolute, normalized file path that a candidate URL names."""
    if not url.startswith("file://"):
        raise ValueError("invalid candidate URL")
    path = url[len("file://") :]
    if (
        not path.startswith("/")
        or PATH_CHARACTERS.fullmatch(path) is None
        or os.path.normpath(path) != path
        or os.path.basename(path) != CANDIDATE_NAME.format(build=build)
    ):
        raise ValueError("invalid candidate URL")
    return path


def validate_values(values, candidate):
    """The closed value rules, shared by the writer and the reader."""
    if BUILD.fullmatch(values["build"]) is None:
        raise ValueError("invalid build")
    if (
        SHORT.fullmatch(values["short"]) is None
        or values["title_short"] != values["short"]
    ):
        raise ValueError("invalid version")
    if MINIMUM.fullmatch(values["minimum"]) is None:
        raise ValueError("invalid minimum system version")
    if LENGTH.fullmatch(values["length"]) is None:
        raise ValueError("invalid length")
    check_date(values["date"])
    check_signature(values["signature"])
    if candidate:
        candidate_path(values["url"], values["build"])
    elif values["url"] != PRODUCTION_URL.format(short=values["short"]):
        raise ValueError("invalid download URL")


def parse(data, candidate):
    """Read one feed from bytes. Every failure is a ValueError."""
    if not isinstance(data, bytes) or len(data) > FEED_LIMIT:
        raise ValueError("feed too large")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("feed is not UTF-8") from error
    match = PATTERN.fullmatch(text)
    if match is None:
        raise ValueError("feed does not match the schema")
    values = match.groupdict()
    validate_values(values, candidate)
    return values


def render(values):
    """The normative text for validated values."""
    return TEMPLATE.format(**values)


def regular_file(path, limit):
    """Bytes of a regular file that is not a link, within the limit."""
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise ValueError("unsafe file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file too large")
    return data


def bundle_values(bundle):
    """Version values of a bundle, read without following links."""
    path = Path(bundle)
    if path.is_symlink() or not path.is_dir() or path.suffix != ".app":
        raise ValueError("unsafe bundle")
    contents = path / "Contents"
    if contents.is_symlink() or not contents.is_dir():
        raise ValueError("unsafe bundle")
    try:
        info = plistlib.loads(regular_file(contents / "Info.plist", PLIST_LIMIT))
    except plistlib.InvalidFileException as error:
        raise ValueError("invalid Info.plist") from error
    if not isinstance(info, dict):
        raise ValueError("invalid Info.plist")
    values = {}
    for name, key in (
        ("build", "CFBundleVersion"),
        ("short", "CFBundleShortVersionString"),
        ("minimum", "LSMinimumSystemVersion"),
    ):
        value = info.get(key)
        if not isinstance(value, str):
            raise ValueError("invalid Info.plist")
        values[name] = value
    return values


def image_size(dmg):
    """Size of a disk image that is a regular file and not a link."""
    info = os.lstat(dmg)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("unsafe disk image")
    return info.st_size


def verify_artifacts(values, bundle, dmg, candidate):
    """The feed describes exactly this bundle and this image."""
    expected = bundle_values(bundle)
    for name in ("build", "short", "minimum"):
        if values[name] != expected[name]:
            raise ValueError("feed differs from the bundle")
    if values["length"] != str(image_size(dmg)):
        raise ValueError("length differs from the disk image")
    if candidate:
        path = candidate_path(values["url"], values["build"])
        if os.path.realpath(path) != os.path.realpath(dmg) or path != os.path.realpath(
            path
        ):
            raise ValueError("candidate URL does not name the disk image")


def parse_arguments(arguments):
    """The command and its options; anything outside the normative usage is a UsageError."""
    if not arguments or arguments[0] not in ("build", "check"):
        raise UsageError()
    command, rest = arguments[0], list(arguments[1:])
    valued = {
        "build": {
            "--bundle",
            "--dmg",
            "--signature",
            "--download-url",
            "--pub-date",
            "--output",
        },
        "check": {"--appcast", "--bundle", "--dmg", "--previous"},
    }[command]
    options = {}
    while rest:
        name = rest.pop(0)
        if name in options:
            raise UsageError()
        if name == "--candidate":
            options[name] = True
        elif name in valued and rest:
            options[name] = rest.pop(0)
        else:
            raise UsageError()
    if command == "build" and not valued <= set(options):
        raise UsageError()
    if command == "check" and (
        "--appcast" not in options or ("--bundle" in options) != ("--dmg" in options)
    ):
        raise UsageError()
    return command, options


def build(options):
    """Write the feed for one bundle and image, refusing an existing output."""
    candidate = options.get("--candidate", False)
    artifact = bundle_values(options["--bundle"])
    values = {
        "title_short": artifact["short"],
        "date": options["--pub-date"],
        "build": artifact["build"],
        "short": artifact["short"],
        "minimum": artifact["minimum"],
        "url": options["--download-url"],
        "length": str(image_size(options["--dmg"])),
        "signature": options["--signature"],
    }
    validate_values(values, candidate)
    data = render(values).encode("utf-8")
    verify_artifacts(
        parse(data, candidate), options["--bundle"], options["--dmg"], candidate
    )
    descriptor = os.open(
        options["--output"], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def check(options):
    """Verify a feed, optionally against the bundle, the image and the previous feed."""
    candidate = options.get("--candidate", False)
    values = parse(regular_file(options["--appcast"], FEED_LIMIT), candidate)
    if "--bundle" in options:
        verify_artifacts(values, options["--bundle"], options["--dmg"], candidate)
    if "--previous" in options:
        previous = parse(regular_file(options["--previous"], FEED_LIMIT), candidate)
        if int(previous["build"]) >= int(values["build"]):
            raise ValueError("build is not newer than the published feed")


def main(arguments):
    """Run one command; usage errors exit 64, refusals exit 1 without paths in the message."""
    try:
        command, options = parse_arguments(arguments)
    except UsageError:
        print(USAGE, file=sys.stderr)
        return 64
    try:
        (build if command == "build" else check)(options)
    except (OSError, ValueError) as error:
        reason = (
            str(error)
            if isinstance(error, ValueError)
            else "unreadable or unwritable file"
        )
        print(f"appcast: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
