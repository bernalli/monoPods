#!/usr/bin/env python3
"""Read the run paths and linked libraries of a thin 64-bit little-endian Mach-O."""
from dataclasses import dataclass
import os
from pathlib import Path
import stat
import struct
import sys

MAGIC = b'\xcf\xfa\xed\xfe'
HEADER_SIZE = 32
ARM64 = 0x0100000c
LC_RPATH = 0x8000001c
LIBRARY_COMMANDS = frozenset((0xc, 0x80000018, 0x8000001f))
STRING_OFFSET_MINIMUM = 12
FRAMEWORK_RPATH = '@executable_path/../Frameworks'
SPARKLE_LIBRARY = '@rpath/Sparkle.framework/Versions/B/Sparkle'
ALLOWED_RPATHS = frozenset(('/usr/lib/swift', '@loader_path', FRAMEWORK_RPATH))
ALLOWED_LIBRARY_PREFIXES = ('/System/Library/Frameworks/', '/usr/lib/')
EXECUTABLE = 'Contents/MacOS/MonoPods'
READ_LIMIT = 1 << 30


@dataclass(frozen=True)
class MachO:
    """Load commands read from one binary, in file order."""

    cputype: int
    rpaths: list[str]
    libraries: list[str]


def word(data: bytes, offset: int) -> int:
    """Return the little-endian 32-bit word at offset, or raise ValueError past the end."""
    if offset < 0 or offset + 4 > len(data):
        raise ValueError('truncated Mach-O')
    return struct.unpack_from('<I', data, offset)[0]


def command_string(data: bytes, start: int, size: int, minimum: int = STRING_OFFSET_MINIMUM) -> str:
    """Decode the NUL-terminated name of a load command that starts at start."""
    if size <= minimum:
        raise ValueError("short string command")
    offset = word(data, start + 8)
    if offset < minimum or offset >= size:
        raise ValueError('invalid string offset')
    raw = data[start + offset:start + size]
    end = raw.find(b'\0')
    if end < 0:
        raise ValueError('unterminated string')
    try:
        return raw[:end].decode('utf-8')
    except UnicodeDecodeError as error:
        raise ValueError('invalid string') from error


def parse(data: bytes) -> MachO:
    """Parse the header and load commands; every malformation raises ValueError."""
    if len(data) < HEADER_SIZE or data[:4] != MAGIC:
        raise ValueError('not a thin 64-bit little-endian Mach-O')
    cputype = word(data, 4)
    count = word(data, 16)
    commands_end = HEADER_SIZE + word(data, 20)
    if commands_end > len(data):
        raise ValueError('load commands past the end')
    rpaths = []
    libraries = []
    cursor = HEADER_SIZE
    for _ in range(count):
        if cursor + 8 > commands_end:
            raise ValueError('load command past the end')
        kind = word(data, cursor)
        size = word(data, cursor + 4)
        if size < 8 or size % 8 or cursor + size > commands_end:
            raise ValueError('invalid load command size')
        if kind == LC_RPATH:
            rpaths.append(command_string(data, cursor, size))
        elif kind in LIBRARY_COMMANDS:
            libraries.append(command_string(data, cursor, size, minimum=24))
        cursor += size
    if cursor != commands_end:
        raise ValueError('load command sizes disagree with the header')
    return MachO(cputype=cputype, rpaths=rpaths, libraries=libraries)


def read_regular(path: Path) -> bytes:
    """Read a regular file that is not a link."""
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > READ_LIMIT:
        raise ValueError('not a regular file')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        return handle.read(READ_LIMIT + 1)


def check_app(app: Path) -> None:
    """The closed list of the product executable: arm64, system run paths and libraries, and
    exactly the embedded Sparkle framework through its own run path."""
    if app.is_symlink() or not app.is_dir():
        raise ValueError('not a bundle')
    parsed = parse(read_regular(app / EXECUTABLE))
    if parsed.cputype != ARM64:
        raise ValueError('unexpected architecture')
    if not set(parsed.rpaths) <= ALLOWED_RPATHS:
        raise ValueError('unexpected run path')
    if not all(
        library == SPARKLE_LIBRARY
        or (library.startswith(ALLOWED_LIBRARY_PREFIXES)
            and all(part not in ('', '.', '..') for part in library.split('/')[1:]))
        for library in parsed.libraries
    ):
        raise ValueError('unexpected library')
    if FRAMEWORK_RPATH not in parsed.rpaths or SPARKLE_LIBRARY not in parsed.libraries:
        raise ValueError('missing framework link')


def main(arguments: list[str]) -> None:
    """Run one subcommand: rpaths BIN or check-app APP."""
    if len(arguments) != 2 or arguments[0] not in ('rpaths', 'check-app'):
        raise ValueError('usage: macho.py rpaths BIN | check-app APP')
    if arguments[0] == 'rpaths':
        for rpath in parse(read_regular(Path(arguments[1]))).rpaths:
            print(rpath)
    else:
        check_app(Path(arguments[1]))


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError):
        print('Mach-O validation failed', file=sys.stderr)
        sys.exit(1)
