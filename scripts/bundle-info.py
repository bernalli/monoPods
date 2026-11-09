#!/usr/bin/env python3
"""Copy bundle metadata, derive the About window copyright from LICENSE, add the update channel."""
import base64
import binascii
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys

PRODUCTION_FEED_URL = 'https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml'
CHANNEL_LIMIT = 65536
CHANNEL_KEYS = {'v', 'feedURL', 'publicEDKey'}
PUBLIC_KEY_BYTES = 32
CANDIDATE_VERSION = re.compile('[1-9][0-9]{0,8}')
USAGE = ('Usage: bundle-info.py template.plist LICENSE output.plist '
         '[--update-channel FILE [--candidate-version N]]')


def unique_object(pairs):
    """Build a JSON object and refuse a repeated key."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate channel key')
        result[key] = value
    return result


def read_channel(path):
    """Read the update channel file: a regular file, never a link, within the size limit."""
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > CHANNEL_LIMIT:
        raise ValueError('unsafe channel file')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        data = handle.read(CHANNEL_LIMIT + 1)
    if len(data) > CHANNEL_LIMIT:
        raise ValueError('channel file too large')
    document = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)
    if not isinstance(document, dict) or set(document) != CHANNEL_KEYS:
        raise ValueError('invalid channel schema')
    if type(document['v']) is not int or document['v'] != 1:
        raise ValueError('invalid channel version')
    if document['feedURL'] != PRODUCTION_FEED_URL:
        raise ValueError('unexpected feed')
    key = document['publicEDKey']
    if not isinstance(key, str) or not key:
        raise ValueError('invalid public key')
    try:
        decoded = base64.b64decode(key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError('invalid public key') from error
    if len(decoded) != PUBLIC_KEY_BYTES:
        raise ValueError('invalid public key')
    return document['feedURL'], key


def parse_options(arguments):
    """Return (channel, candidate) from the optional arguments, refusing anything else."""
    options = {}
    rest = list(arguments)
    while rest:
        name = rest.pop(0)
        if name not in ('--update-channel', '--candidate-version') or name in options or not rest:
            raise ValueError(USAGE)
        options[name] = rest.pop(0)
    if '--candidate-version' in options and '--update-channel' not in options:
        raise ValueError('--candidate-version requires --update-channel')
    return options.get('--update-channel'), options.get('--candidate-version')


def main():
    if len(sys.argv) < 4:
        raise SystemExit(USAGE)
    template, license_path, output = map(Path, sys.argv[1:4])
    channel_path, candidate = parse_options(sys.argv[4:])
    info = plistlib.loads(template.read_bytes())
    if not isinstance(info, dict):
        raise ValueError('template is not a dictionary')
    if 'SUFeedURL' in info or 'SUPublicEDKey' in info:
        raise ValueError('the template must not carry an update channel')
    copyright_line = next((line.strip() for line in license_path.read_text().splitlines()
                           if line.strip().startswith('Copyright ')), None)
    if not copyright_line:
        raise SystemExit('LICENSE must contain a copyright notice')
    info['NSHumanReadableCopyright'] = copyright_line
    if channel_path is not None:
        feed, key = read_channel(Path(channel_path))
        info['SUFeedURL'] = feed
        info['SUPublicEDKey'] = key
    if candidate is not None:
        current = info.get('CFBundleVersion')
        if (CANDIDATE_VERSION.fullmatch(candidate) is None or not isinstance(current, str)
                or not current.isdigit() or int(candidate) <= int(current)):
            raise ValueError('invalid candidate version')
        info['CFBundleVersion'] = candidate
    output.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeDecodeError) as error:
        print(f'bundle-info: {error}', file=sys.stderr)
        sys.exit(1)
