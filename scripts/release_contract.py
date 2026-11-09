"""Closed release receipts and artifact identity checks, without runtime effects."""

import base64
import hashlib
import json
import os
import plistlib
import re
import runpy
import stat
from datetime import datetime
from pathlib import Path

LIMIT = 65536
FEED = "https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml"
BASE_FIELDS = {
    "v",
    "sourceCommit",
    "build",
    "manifestSha256",
    "dmgSha256",
    "bundleTreeSha256",
    "toolchain",
    "createdUTC",
    "signingMode",
}
CHANNEL_FIELDS = {
    "appcastSha256",
    "bundleVersion",
    "shortVersion",
    "feedURL",
    "publicEDKey",
}
MANIFEST = runpy.run_path(str(Path(__file__).with_name("manifest.py")))


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def loads(data, limit=LIMIT):
    if type(data) is not bytes or not 0 < len(data) <= limit:
        raise ValueError("invalid document length")
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=unique,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")),
        )
    except (UnicodeError, RecursionError) as error:
        raise ValueError("invalid document") from error


def read(path, limit=LIMIT):
    path = Path(path)
    MANIFEST["reject_symlinks"](path)
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("not a regular file")
    with path.open("rb") as stream:
        return stream.read(limit + 1)


def digest(path):
    path = Path(path)
    MANIFEST["reject_symlinks"](path)
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("not a regular file")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def text(value, maximum=4096):
    return type(value) is str and 0 < len(value.encode("utf-8")) <= maximum


def matches(value, pattern):
    return type(value) is str and re.fullmatch(pattern, value) is not None


def timestamp(value):
    if not matches(value, r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"):
        raise ValueError("invalid timestamp")
    datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")


def validate(document, *, channel=True):
    fields = BASE_FIELDS | (CHANNEL_FIELDS if channel else set())
    if type(document) is not dict or set(document) != fields:
        raise ValueError("invalid receipt fields")
    if type(document["v"]) is not int or document["v"] != 1:
        raise ValueError("invalid receipt version")
    if not matches(document["sourceCommit"], "[0-9a-f]{40}"):
        raise ValueError("invalid commit")
    for key in ("build", "manifestSha256", "dmgSha256", "bundleTreeSha256") + (
        ("appcastSha256",) if channel else ()
    ):
        if not matches(document[key], "[0-9a-f]{64}"):
            raise ValueError("invalid digest")
    if document["signingMode"] != "ad-hoc":
        raise ValueError("invalid signing mode")
    timestamp(document["createdUTC"])
    toolchain = document["toolchain"]
    if (
        type(toolchain) is not dict
        or set(toolchain) != {"swift", "macOSVersion", "macOSBuild"}
        or not all(text(value, 4096) for value in toolchain.values())
    ):
        raise ValueError("invalid toolchain")
    if channel:
        if (
            not matches(document["bundleVersion"], "[1-9][0-9]{0,8}")
            or not text(document["shortVersion"], 64)
            or not matches(document["shortVersion"], r"[0-9]+\.[0-9]+\.[0-9]+")
            or document["feedURL"] != FEED
            or not text(document["publicEDKey"], 44)
        ):
            raise ValueError("invalid channel")
        key = document["publicEDKey"]
        decoded = base64.b64decode(key, validate=True)
        if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != key:
            raise ValueError("invalid key")
    if len(json.dumps(document).encode("utf-8")) > LIMIT:
        raise ValueError("receipt too large")
    return document


def internal_link(root, path):
    target = os.readlink(path)
    if not target or os.path.isabs(target):
        raise ValueError("absolute or empty link")
    try:
        resolved = (path.parent / target).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError("dangling or looping link") from error
    if not resolved.is_relative_to(root) or resolved == root:
        raise ValueError("link outside the bundle")
    return target


def bundle_tree_hash(bundle):
    """Signature-independent tree identity, including internal link destinations."""
    MANIFEST["reject_symlinks"](bundle)
    if not bundle.is_dir():
        raise ValueError("missing bundle")
    records = []

    def fail(error):
        raise error

    for directory, directories, files in os.walk(
        bundle, followlinks=False, onerror=fail
    ):
        for name in directories + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            relative = path.relative_to(bundle).as_posix()
            if stat.S_ISLNK(mode):
                records.append(
                    (
                        relative,
                        b"L",
                        internal_link(bundle.resolve(), path).encode("utf-8"),
                    )
                )
            elif stat.S_ISREG(mode):
                if not relative.startswith("Contents/_CodeSignature/"):
                    records.append((relative, b"F", MANIFEST["artifact_bytes"](path)))
            elif not stat.S_ISDIR(mode):
                raise ValueError("unsupported bundle entry")
    value = hashlib.sha256()
    for relative, kind, data in sorted(records):
        name = relative.encode("utf-8")
        value.update(kind + len(name).to_bytes(8, "big") + name)
        value.update(len(data).to_bytes(8, "big") + data)
    return value.hexdigest()


def verify_artifacts(document, bundle, dmg, appcast):
    validate(document)
    manifest = MANIFEST["verify_manifest"](bundle, document["sourceCommit"])
    expected = {
        "manifestSha256": digest(bundle / "Contents/Resources/Manifest.json"),
        "bundleTreeSha256": bundle_tree_hash(bundle),
        "build": manifest["build"],
        "dmgSha256": digest(dmg),
        "appcastSha256": digest(appcast),
    }
    info = plistlib.loads(read(bundle / "Contents/Info.plist"))
    if type(info) is not dict:
        raise ValueError("invalid bundle info")
    expected.update(
        bundleVersion=info.get("CFBundleVersion"),
        shortVersion=info.get("CFBundleShortVersionString"),
        feedURL=info.get("SUFeedURL"),
        publicEDKey=info.get("SUPublicEDKey"),
    )
    if any(document[key] != value for key, value in expected.items()):
        raise ValueError("artifacts differ from receipt")
