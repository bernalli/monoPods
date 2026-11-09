#!/usr/bin/env python3
"""Build or verify the local bundle manifest; no registration or runtime effects."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

REQUIRED = (
    'Contents/MacOS/MonoPods', 'Contents/Info.plist', 'Contents/Resources/AppIcon.icns',
    'Contents/Resources/MenuBarIcon.png', 'Contents/Resources/MenuBarIcon@2x.png',
    'Contents/Resources/GitHubMark.pdf', 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
    'Contents/Resources/Sparkle-LICENSE.txt',
)


def artifact_bytes(path):
    data = bytearray(path.read_bytes())
    if data[:4] == b'\xcf\xfa\xed\xfe':
        commands = struct.unpack_from('<I', data, 16)[0]
        if commands > 65536:
            raise ValueError('invalid Mach-O')
        cursor = 32
        for _ in range(commands):
            kind, size = struct.unpack_from('<II', data, cursor)
            if size < 8 or cursor + size > len(data):
                raise ValueError('invalid load command')
            if kind == 0x1d:
                offset, length = struct.unpack_from('<II', data, cursor + 8)
                if size != 16 or offset < cursor + size or offset + length != len(data):
                    raise ValueError('invalid signature range')
                data = data[:offset]
                data[cursor + 8:cursor + 16] = bytes(8)
                break
            cursor += size
    return bytes(data)


def artifact_hash(path):
    return hashlib.sha256(artifact_bytes(path)).hexdigest()


def reject_symlinks(path):
    for component in (path.absolute(), *path.absolute().parents):
        if component.is_symlink():
            raise ValueError('symlink path')


def validate_commit(value):
    if not isinstance(value, str) or re.fullmatch('[0-9a-f]{40}', value) is None:
        raise ValueError('invalid source commit')
    return value


def manifest(bundle, source_commit):
    validate_commit(source_commit)
    files = {}
    for relative in REQUIRED:
        path = bundle
        for part in Path(relative).parts:
            path = path / part
            if path.is_symlink():
                raise ValueError('symlink in bundle')
        if not path.is_file():
            raise ValueError('missing artifact')
        files[relative] = artifact_hash(path)
    return {'v': 1, 'build': files['Contents/MacOS/MonoPods'],
            'sourceCommit': source_commit, 'files': files}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate manifest key')
        result[key] = value
    return result


def verify_manifest(bundle, source_commit=None):
    output = bundle / 'Contents/Resources/Manifest.json'
    reject_symlinks(output)
    document = json.loads(output.read_text(), object_pairs_hook=unique_object)
    if (not isinstance(document, dict)
            or set(document) != {'v', 'build', 'sourceCommit', 'files'}
            or type(document['v']) is not int or document['v'] != 1):
        raise ValueError('invalid manifest schema')
    recorded = validate_commit(document['sourceCommit'])
    if source_commit is not None and recorded != validate_commit(source_commit):
        raise ValueError('source commit mismatch')
    if document != manifest(bundle, recorded):
        raise ValueError('manifest mismatch')
    return document


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ('write', 'verify'):
        raise ValueError('usage: manifest.py write bundle sourceCommit | verify bundle [sourceCommit]')
    bundle = Path(sys.argv[2])
    reject_symlinks(bundle)
    if not bundle.is_dir() or bundle.suffix != '.app':
        raise ValueError('unexpected bundle')
    root = Path(__file__).resolve().parent.parent
    resolved = bundle.resolve()
    temporary = Path('/private/tmp').resolve()
    tempdir = Path(__import__('tempfile').gettempdir()).resolve()
    if not any(resolved.is_relative_to(parent) for parent in (root / 'dist', temporary, tempdir)):
        raise ValueError('bundle outside artifact roots')
    output = bundle / 'Contents/Resources/Manifest.json'
    reject_symlinks(output)
    source_commit = sys.argv[3] if len(sys.argv) == 4 else None
    if sys.argv[1] == 'write':
        expected = manifest(bundle, source_commit)
        output.write_text(json.dumps(expected, sort_keys=True, separators=(',', ':')) + '\n')
    else:
        verify_manifest(bundle, source_commit)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, struct.error, KeyError):
        print('Manifest validation failed', file=sys.stderr)
        sys.exit(1)
