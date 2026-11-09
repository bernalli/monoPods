#!/usr/bin/env python3
"""Record release identity outside the repository after read-only validation.

Every build is signed ad hoc; with --appcast the receipt also binds the feed and the channel."""
import base64
import binascii
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import stat
import struct
import subprocess
import sys

import appcast
from release_contract import bundle_tree_hash, internal_link, validate
from manifest import artifact_bytes, reject_symlinks, verify_manifest

SIGNING_MODE = 'ad-hoc'
BUNDLE_INFO = runpy.run_path(str(Path(__file__).resolve().parent / 'bundle-info.py'))


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def repository_roots(root):
    roots = {root}
    # A linked worktree also belongs to the primary checkout's repository.
    if (root / '.git').exists():
        common = Path(command('git', '-C', str(root), 'rev-parse',
                              '--path-format=absolute', '--git-common-dir')).resolve()
        if common.name == '.git':
            roots.add(common.parent)
    return roots


def validate_paths(root, bundle, dmg, output):
    if not output.is_absolute() or '..' in output.parts:
        raise ValueError('absolute output path required')
    for path in (bundle, dmg, output):
        reject_symlinks(path)
    if any(output.resolve().is_relative_to(parent) for parent in repository_roots(root)):
        raise ValueError('receipt must be outside repository')
    if output.exists() or not output.parent.is_dir():
        raise ValueError('receipt destination must be new')
    dist = root / 'dist'
    if (bundle.suffix != '.app' or not bundle.is_dir()
            or dmg.suffix != '.dmg' or not dmg.is_file()
            or not bundle.resolve().is_relative_to(dist)
            or not dmg.resolve().is_relative_to(dist)):
        raise ValueError('expected release artifacts in dist')


def release_fields(bundle, feed_path):
    """Feed digest, versions and the incorporated channel; the feed must describe the bundle."""
    reject_symlinks(feed_path)
    data = appcast.regular_file(feed_path, appcast.FEED_LIMIT)
    try:
        values = appcast.parse(data, candidate=False)
    except ValueError:
        values = appcast.parse(data, candidate=True)
    info = plistlib.loads(appcast.regular_file(bundle / 'Contents/Info.plist', appcast.PLIST_LIMIT))
    if not isinstance(info, dict):
        raise ValueError('invalid Info.plist')
    version, short = info.get('CFBundleVersion'), info.get('CFBundleShortVersionString')
    feed, key = info.get('SUFeedURL'), info.get('SUPublicEDKey')
    if (values['build'], values['short']) != (version, short):
        raise ValueError('feed differs from the bundle')
    if feed != BUNDLE_INFO['PRODUCTION_FEED_URL'] or not isinstance(key, str):
        raise ValueError('bundle has no production channel')
    try:
        decoded = base64.b64decode(key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError('invalid public key') from error
    if len(decoded) != BUNDLE_INFO['PUBLIC_KEY_BYTES']:
        raise ValueError('invalid public key')
    return {'appcastSha256': hashlib.sha256(data).hexdigest(), 'bundleVersion': version,
            'shortVersion': short, 'feedURL': feed, 'publicEDKey': key}


def main():
    arguments = sys.argv[1:]
    feed_path = None
    if len(arguments) == 5 and arguments[3] == '--appcast':
        feed_path = Path(arguments[4])
        arguments = arguments[:3]
    if len(arguments) != 3:
        raise ValueError('usage: release-receipt.py dist/bundle.app dist/image.dmg '
                         '/absolute/output.json [--appcast FILE]')
    root = Path(__file__).resolve().parent.parent
    bundle, dmg, output = map(Path, arguments)
    validate_paths(root, bundle, dmg, output)
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    manifest = verify_manifest(bundle)
    receipt = {
        'v': 1, 'sourceCommit': manifest['sourceCommit'], 'build': manifest['build'],
        'manifestSha256': hashlib.sha256(
            (bundle / 'Contents/Resources/Manifest.json').read_bytes()).hexdigest(),
        'dmgSha256': hashlib.sha256(dmg.read_bytes()).hexdigest(),
        'bundleTreeSha256': bundle_tree_hash(bundle),
        'toolchain': {'swift': command('swift', '--version'),
                      'macOSVersion': command('sw_vers', '-productVersion'),
                      'macOSBuild': command('sw_vers', '-buildVersion')},
        'createdUTC': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'signingMode': SIGNING_MODE,
    }
    if feed_path is not None:
        receipt.update(release_fields(bundle, feed_path))
    validate(receipt, channel=feed_path is not None)
    data = (json.dumps(receipt, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')
    # Exclusive creation refuses both existing files and links installed at the destination.
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, struct.error, subprocess.SubprocessError):
        # Do not print command output or artifact paths into shared logs.
        print('Release receipt validation failed', file=sys.stderr)
        sys.exit(1)
