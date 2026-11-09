#!/usr/bin/env python3
"""Refuse an artifact that names a forbidden term or carries image metadata.

Subcommands: bundle BUNDLE, tree DIR and text FILE... Every regular file is read in blocks of
1 MiB. PNG and ICNS files must pass a closed structural check; Mach-O files must have a valid
layout, and only their validated code signature regions may contain the name terms.
"""
import argparse
from dataclasses import dataclass, field
import os
import plistlib
import re
import stat
import struct
import sys
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple
from xml.parsers import expat
import zlib

USAGE_EXIT = 64
MINIMUM_TERM_LENGTH = 4
MAXIMUM_TERM_BYTES = 1024
TERMS_FILE_LIMIT = 1 << 20
TERMS_LIMIT = 4096
READ_LIMIT = 1 << 30
BLOCK_SIZE = 1 << 20
IMAGE_LIMIT = 64 << 20
PROPERTY_LIST_LIMIT = 1 << 20
PROPERTY_LIST_DEPTH = 64
CONTAINER_ELEMENTS = 4096
PNG_SIDE_LIMIT = 16384
PNG_PIXEL_LIMIT = 64_000_000
PNG_CHUNK_LENGTH_LIMIT = 0x7fffffff
ICC_PROFILE_LIMIT = 4 << 20
FAT_SLICE_LIMIT = 64
LOAD_COMMAND_LIMIT = 65536
LOAD_COMMANDS_BYTES_LIMIT = 16 << 20
WORD_BYTES = frozenset(b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_')
WORD_UNITS = {encoding: frozenset(chr(byte).encode(encoding) for byte in WORD_BYTES)
              for encoding in ('utf-8', 'utf-16-le', 'utf-16-be')}
INFO_PLIST = ('Contents', 'Info.plist')
COPYRIGHT_KEY = 'NSHumanReadableCopyright'

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
PNG_ALLOWED_CHUNKS = frozenset((b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'cHRM', b'gAMA',
                                b'iCCP', b'sBIT', b'sRGB', b'pHYs', b'bKGD', b'iDOT', b'cICP'))
PNG_BEFORE_PALETTE = frozenset((b'cHRM', b'gAMA', b'iCCP', b'sBIT', b'sRGB', b'cICP'))
PNG_DEPTHS = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
PNG_FIXED_LENGTHS = {b'IHDR': 13, b'IEND': 0, b'gAMA': 4, b'cHRM': 32, b'sRGB': 1, b'pHYs': 9,
                     b'cICP': 4}
PNG_SBIT_LENGTHS = {0: 1, 2: 3, 3: 3, 4: 2, 6: 4}
PNG_BKGD_LENGTHS = {0: 2, 2: 6, 3: 1, 4: 2, 6: 6}
PNG_TRNS_LENGTHS = {0: 2, 2: 6}

ICNS_MAGIC = b'icns'
MACHO_THIN = {b'\xcf\xfa\xed\xfe': (32, 8, 0x19, 72), b'\xce\xfa\xed\xfe': (28, 4, 0x1, 56)}
MACHO_FAT = {b'\xca\xfe\xba\xbe': False, b'\xca\xfe\xba\xbf': True}
LC_CODE_SIGNATURE = 0x1d
CODE_SIGNATURE_MAGIC = 0xfade0cc0
# The blob formats understood by this structural gate, keyed by their signature slot.
SIGNATURE_SLOTS = {0: 0xfade0c02, 2: 0xfade0c01, 5: 0xfade7171,
                   7: 0xfade7172, 0x10000: 0xfade0b01}
SIGNATURE_SLOTS.update({slot: 0xfade0c02 for slot in range(0x1000, 0x1006)})
SECTION_SIZES = {0x19: 80, 0x1: 68}
VM_PROT_EXECUTE = 4


class UsageError(Exception):
    """The command line is invalid."""


class Invalid(Exception):
    """A file is refused; the reason never contains a term."""


class ScanFailure(Exception):
    """The artifact is refused; the reason never contains a term."""

    def __init__(self, relative: str, reason: str) -> None:
        super().__init__(reason)
        self.relative = relative
        self.reason = reason


class Parser(argparse.ArgumentParser):
    """Argument parser whose errors are usage errors."""

    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(message)


@dataclass(frozen=True)
class Term:
    """A forbidden byte string; whole-word terms match only between non-word bytes."""

    label: str
    data: bytes
    whole_word: bool
    encoding: str = 'utf-8'


def make_terms(texts: Iterable[str], kind: str, word_rule: bool, first: int = 0) -> Tuple[Term, ...]:
    """Build labelled terms. With word_rule, a term made only of [A-Za-z0-9_] matches whole words."""
    terms = []
    for index, text in enumerate(texts, first):
        if len(text) < MINIMUM_TERM_LENGTH:
            raise UsageError('term too short')
        data = text.encode('utf-8', 'surrogateescape')
        if len(data) > MAXIMUM_TERM_BYTES:
            raise UsageError('term too long')
        whole = word_rule and all(byte in WORD_BYTES for byte in data)
        terms.append(Term(f'{kind} {index}', data, whole))
    return tuple(terms)


def bundle_terms(terms: Tuple[Term, ...]) -> Tuple[Term, ...]:
    """Keep labels and matching rules while adding both UTF-16 byte orders, with no BOM needed."""
    return terms + tuple(Term(term.label,
                              term.data.decode('utf-8', 'surrogateescape').encode(
                                  encoding, 'surrogatepass'), term.whole_word, encoding)
                         for term in terms for encoding in ('utf-16-le', 'utf-16-be'))


def read_terms_file(path: str) -> List[str]:
    """Read one term per UTF-8 line; '#' starts a comment line and blank lines are ignored."""
    try:
        descriptor = os.open(path, os.O_RDONLY)
        with os.fdopen(descriptor, 'rb') as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise UsageError('terms file is not a regular file')
            data = handle.read(TERMS_FILE_LIMIT + 1)
    except OSError as error:
        raise UsageError('unreadable terms file') from error
    if len(data) > TERMS_FILE_LIMIT:
        raise UsageError('terms file too large')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as error:
        raise UsageError('terms file is not UTF-8') from error
    terms = []
    for line in text.split('\n'):
        line = line.strip()
        if line and not line.startswith('#'):
            terms.append(line)
    if not terms:
        raise UsageError('terms file has no terms')
    if len(terms) > TERMS_LIMIT:
        raise UsageError('too many terms')
    return terms


def matches(term: Term, window: bytes, starts_file: bool = True, ends_file: bool = True) -> int:
    """Count the occurrences of term that window decides.

    An occurrence of a whole-word term needs the code unit before and after it; at an edge of
    the window that is not an edge of the file a unit is unknown, and the occurrence is left to
    the neighbouring window, which overlaps this one.
    """
    count = 0
    position = window.find(term.data)
    while position >= 0:
        end = position + len(term.data)
        if not term.whole_word:
            count += 1
        else:
            width = 1 if term.encoding == 'utf-8' else 2
            units = WORD_UNITS[term.encoding]
            before = (window[position - width:position] not in units
                      if position >= width else starts_file and position == 0)
            after = (window[end:end + width] not in units
                     if end + width <= len(window) else ends_file and end == len(window))
            if before and after:
                count += 1
        position = window.find(term.data, position + 1)
    return count


def first_match(terms: Sequence[Term], window: bytes, starts_file: bool = True,
                ends_file: bool = True) -> Optional[Term]:
    for term in terms:
        if matches(term, window, starts_file, ends_file):
            return term
    return None


def check_terms(terms: Sequence[Term], data: bytes) -> None:
    term = first_match(terms, data)
    if term is not None:
        raise Invalid(term.label)


@dataclass(frozen=True)
class Policy:
    """What one file is checked for. Names are not checked when names is empty."""

    general: Tuple[Term, ...]
    names: Tuple[Term, ...] = ()
    property_list: bool = False
    structures: bool = True


def masked(window: bytes, start: int, regions: Sequence[Tuple[int, int]]) -> bytes:
    """Zero the bytes of window (at file offset start) that fall inside regions."""
    if not regions:
        return window
    result = bytearray(window)
    for first, last in regions:
        low = max(first, start) - start
        high = min(last, start + len(window)) - start
        if low < high:
            result[low:high] = bytes(high - low)
    return bytes(result)


def scan_stream(descriptor: int, policy: Policy, regions: Sequence[Tuple[int, int]],
                names: Sequence[Term]) -> None:
    """Read the file in blocks with an overlap that keeps every occurrence and its neighbours
    inside one window."""
    longest = max((len(term.data) for term in (*policy.general, *names)), default=0)
    # A whole-word occurrence of a UTF-16 term needs a 2-byte unit on each side in one window.
    overlap = longest + 3
    window = b''
    offset = 0
    total = 0
    while True:
        block = os.read(descriptor, BLOCK_SIZE)
        total += len(block)
        if total > READ_LIMIT:
            raise Invalid('file too large')
        at_end = not block
        window += block
        starts = offset == 0
        term = first_match(policy.general, window, starts, at_end)
        if term is None and names:
            term = first_match(names, masked(window, offset, regions), starts, at_end)
        if term is not None:
            raise Invalid(term.label)
        if at_end:
            return
        keep = min(len(window), overlap)
        offset += len(window) - keep
        window = window[len(window) - keep:]


def read_all(descriptor: int, size: int, limit: int, reason: str) -> bytes:
    if size > limit:
        raise Invalid(reason)
    chunks = []
    total = 0
    while True:
        block = os.read(descriptor, BLOCK_SIZE)
        if not block:
            return b''.join(chunks)
        total += len(block)
        if total > limit:
            raise Invalid(reason)
        chunks.append(block)


def positional_reader(descriptor: int) -> Callable[[int, int], bytes]:
    return lambda offset, length: os.pread(descriptor, length, offset)


# PNG ------------------------------------------------------------------------------------------

def icc_profile(body: bytes) -> Tuple[bytes, bytes]:
    """Return the name and the decompressed iCCP profile, refusing the profile as soon as the
    output passes the limit."""
    separator = body.find(b'\0')
    if separator < 1 or separator > 79 or len(body) < separator + 2 or body[separator + 1] != 0:
        raise Invalid('invalid PNG color profile')
    decompressor = zlib.decompressobj()
    pending = body[separator + 2:]
    output = []
    total = 0
    while True:
        try:
            part = decompressor.decompress(pending, ICC_PROFILE_LIMIT - total + 1)
        except zlib.error as error:
            raise Invalid('invalid PNG color profile') from error
        total += len(part)
        if total > ICC_PROFILE_LIMIT:
            raise Invalid('PNG color profile too large')
        output.append(part)
        pending = decompressor.unconsumed_tail
        if not pending:
            break
    if not decompressor.eof or decompressor.unused_data:
        raise Invalid('invalid PNG color profile')
    return body[:separator], b''.join(output)


def check_png_header(body: bytes) -> Tuple[int, int]:
    width, height, depth, color, compression, filtering, interlace = struct.unpack(
        '>IIBBBBB', body)
    if (not 1 <= width <= PNG_SIDE_LIMIT or not 1 <= height <= PNG_SIDE_LIMIT
            or width * height > PNG_PIXEL_LIMIT):
        raise Invalid('invalid PNG dimensions')
    if depth not in PNG_DEPTHS.get(color, ()):
        raise Invalid('invalid PNG bit depth or color type')
    if compression or filtering or interlace > 1:
        raise Invalid('invalid PNG header')
    return depth, color


def check_png(data: bytes, inspect: Callable[[bytes], None]) -> None:
    """Accept only the closed list of chunks, in a valid order, with valid lengths and CRCs.

    Every chunk body, the color profile name and the decompressed profile go to inspect as
    fields of their own: a body follows its chunk type without a separator, so a whole-word
    term at its edges would be invisible to the raw scan.
    """
    if len(data) > IMAGE_LIMIT:
        raise Invalid('image too large')
    if not data.startswith(PNG_SIGNATURE):
        raise Invalid('invalid PNG signature')
    seen: Set[bytes] = set()
    depth = color = 0
    palette = 0
    after_data = False
    ended = False
    chunks = 0
    cursor = len(PNG_SIGNATURE)
    while cursor < len(data):
        if ended:
            raise Invalid('data after PNG end')
        chunks += 1
        if chunks > CONTAINER_ELEMENTS:
            raise Invalid('too many PNG chunks')
        if cursor + 8 > len(data):
            raise Invalid('truncated PNG chunk')
        length, kind = struct.unpack_from('>I4s', data, cursor)
        if length > PNG_CHUNK_LENGTH_LIMIT or cursor + 12 + length > len(data):
            raise Invalid('PNG chunk past the end')
        body = data[cursor + 8:cursor + 8 + length]
        if zlib.crc32(kind + body) & 0xffffffff != struct.unpack_from(
                '>I', data, cursor + 8 + length)[0]:
            raise Invalid('PNG CRC mismatch')
        if kind not in PNG_ALLOWED_CHUNKS:
            raise Invalid('PNG chunk not allowed')
        inspect(body)
        if not seen and kind != b'IHDR':
            raise Invalid('PNG header is not first')
        if kind in seen and kind != b'IDAT':
            raise Invalid('duplicate PNG chunk')
        if kind in PNG_FIXED_LENGTHS and length != PNG_FIXED_LENGTHS[kind]:
            raise Invalid('invalid PNG chunk length')
        if kind == b'IDAT':
            if after_data:
                raise Invalid('PNG data is not contiguous')
        elif b'IDAT' in seen:
            after_data = True
            if kind != b'IEND':
                raise Invalid('PNG chunk after the image data')
        if kind == b'IHDR':
            depth, color = check_png_header(body)
        elif kind == b'PLTE':
            if color in (0, 4):
                raise Invalid('PNG palette not allowed')
            if b'tRNS' in seen or b'bKGD' in seen:
                raise Invalid('PNG palette out of order')
            limit = 1 << depth if color == 3 else 256
            if not length or length % 3 or length // 3 > limit:
                raise Invalid('invalid PNG palette')
            palette = length // 3
        elif kind in PNG_BEFORE_PALETTE:
            if b'PLTE' in seen:
                raise Invalid('PNG chunk after the palette')
            if kind == b'sBIT' and length != PNG_SBIT_LENGTHS[color]:
                raise Invalid('invalid PNG chunk length')
            if kind == b'iCCP':
                for field_bytes in icc_profile(body):
                    inspect(field_bytes)
        elif kind == b'tRNS':
            if color in (4, 6):
                raise Invalid('PNG transparency not allowed')
            if color == 3:
                if b'PLTE' not in seen:
                    raise Invalid('PNG transparency out of order')
                if not 1 <= length <= palette:
                    raise Invalid('invalid PNG chunk length')
            elif length != PNG_TRNS_LENGTHS[color]:
                raise Invalid('invalid PNG chunk length')
        elif kind == b'bKGD':
            if color == 3 and b'PLTE' not in seen:
                raise Invalid('PNG background out of order')
            if length != PNG_BKGD_LENGTHS[color]:
                raise Invalid('invalid PNG chunk length')
        elif kind == b'IEND':
            ended = True
        seen.add(kind)
        cursor += 12 + length
    if not ended:
        raise Invalid('missing PNG end')
    if b'IDAT' not in seen:
        raise Invalid('missing PNG image data')
    if color == 3 and b'PLTE' not in seen:
        raise Invalid('missing PNG palette')


def check_icns(data: bytes, inspect: Callable[[bytes], None]) -> None:
    """Every element must fit the file exactly; PNG elements pass the PNG check, and every other
    element body goes to inspect as a field of its own."""
    if len(data) > IMAGE_LIMIT:
        raise Invalid('image too large')
    if len(data) < 8 or data[:4] != ICNS_MAGIC:
        raise Invalid('invalid ICNS header')
    if struct.unpack_from('>I', data, 4)[0] != len(data):
        raise Invalid('ICNS length mismatch')
    cursor = 8
    elements = 0
    while cursor < len(data):
        elements += 1
        if elements > CONTAINER_ELEMENTS:
            raise Invalid('too many ICNS elements')
        if cursor + 8 > len(data):
            raise Invalid('truncated ICNS element')
        length = struct.unpack_from('>I', data, cursor + 4)[0]
        if length < 8 or cursor + length > len(data):
            raise Invalid('invalid ICNS element length')
        body = data[cursor + 8:cursor + length]
        if body.startswith(PNG_SIGNATURE):
            check_png(body, inspect)
        else:
            inspect(body)
        cursor += length


# Mach-O ---------------------------------------------------------------------------------------

def exact(read: Callable[[int, int], bytes], offset: int, length: int) -> bytes:
    data = read(offset, length)
    if len(data) != length:
        raise Invalid('truncated Mach-O')
    return data


def overlaps(first: Tuple[int, int], second: Tuple[int, int]) -> bool:
    return first[0] < second[1] and second[0] < first[1]


def thin_regions(read: Callable[[int, int], bytes], base: int, size: int) -> List[Tuple[int, int]]:
    """Return the code signature super blob of one thin Mach-O as an absolute range."""
    magic = exact(read, base, 4) if size >= 4 else b''
    if magic not in MACHO_THIN:
        raise Invalid('invalid Mach-O')
    header_size, alignment, segment_kind, segment_size = MACHO_THIN[magic]
    if size < header_size:
        raise Invalid('truncated Mach-O')
    count, commands_size = struct.unpack('<II', exact(read, base + 16, 8))
    if count > LOAD_COMMAND_LIMIT or commands_size > LOAD_COMMANDS_BYTES_LIMIT:
        raise Invalid('too many Mach-O load commands')
    commands_end = header_size + commands_size
    if commands_end > size:
        raise Invalid('Mach-O load commands past the end')
    commands = exact(read, base, commands_end)
    signature = None
    segments = []
    linkedits = []
    cursor = header_size
    for _ in range(count):
        if cursor + 8 > commands_end:
            raise Invalid('Mach-O load command past the end')
        kind, command_size = struct.unpack_from('<II', commands, cursor)
        if command_size < 8 or command_size % alignment or cursor + command_size > commands_end:
            raise Invalid('invalid Mach-O load command size')
        if kind == LC_CODE_SIGNATURE:
            if signature is not None:
                raise Invalid('duplicate Mach-O code signature')
            if command_size != 16:
                raise Invalid('invalid Mach-O load command size')
            signature = struct.unpack_from('<II', commands, cursor + 8)
        elif kind == segment_kind:
            if command_size < segment_size:
                raise Invalid('invalid Mach-O load command size')
            # initprot is the protection the segment is mapped with; maxprot of older x86_64
            # slices is rwx even for data.
            if segment_kind == 0x19:
                fileoff, filesize, _, initprot, sections = struct.unpack_from(
                    '<QQiiI', commands, cursor + 40)
            else:
                fileoff, filesize, _, initprot, sections = struct.unpack_from(
                    '<IIiiI', commands, cursor + 32)
            if command_size != segment_size + sections * SECTION_SIZES[segment_kind]:
                raise Invalid('invalid Mach-O load command size')
            if fileoff + filesize > size:
                raise Invalid('Mach-O segment past the end')
            extent = (fileoff, fileoff + filesize)
            segments.append((extent, initprot & VM_PROT_EXECUTE))
            if commands[cursor + 8:cursor + 24].rstrip(b'\0') == b'__LINKEDIT':
                linkedits.append(extent)
        cursor += command_size
    if cursor != commands_end:
        raise Invalid('Mach-O load command sizes disagree with the header')
    if signature is None:
        return []
    offset, length = signature
    region = (offset, offset + length)
    if not length or region[1] > size:
        raise Invalid('Mach-O code signature past the end')
    if overlaps(region, (0, commands_end)):
        raise Invalid('Mach-O code signature overlaps the load commands')
    if any(executable and overlaps(region, extent) for extent, executable in segments):
        raise Invalid('Mach-O code signature overlaps executable code')
    if len(linkedits) != 1 or not (linkedits[0][0] <= offset < region[1] <= linkedits[0][1]):
        raise Invalid('Mach-O code signature outside LINKEDIT')
    if length < 12:
        raise Invalid('invalid Mach-O code signature')
    blob_magic, blob_length, count = struct.unpack('>III', exact(read, base + offset, 12))
    if blob_magic != CODE_SIGNATURE_MAGIC or not 12 <= blob_length <= length:
        raise Invalid('invalid Mach-O code signature')
    index_end = 12 + 8 * count
    if index_end > blob_length or count > CONTAINER_ELEMENTS:
        raise Invalid('invalid Mach-O code signature index')
    index = exact(read, base + offset + 12, 8 * count)
    children = []
    slots: Set[int] = set()
    for position in range(count):
        slot, child = struct.unpack_from('>II', index, position * 8)
        if slot in slots or slot not in SIGNATURE_SLOTS or not index_end <= child <= blob_length - 8:
            raise Invalid('invalid Mach-O code signature index')
        slots.add(slot)
        magic, child_length = struct.unpack('>II', exact(read, base + offset + child, 8))
        if magic != SIGNATURE_SLOTS[slot] or child_length < 8 or child + child_length > blob_length:
            raise Invalid('invalid Mach-O code signature child')
        children.append((child, child + child_length))
    # Each byte excluded must belong to the header, index or one non-overlapping child.
    cursor = index_end
    for first, last in sorted(children):
        if first != cursor:
            raise Invalid('overlapping or unreferenced Mach-O code signature bytes')
        cursor = last
    if cursor != blob_length:
        raise Invalid('unreferenced Mach-O code signature bytes')
    return [(base + offset, base + offset + blob_length)]


def macho_regions(read: Callable[[int, int], bytes], size: int) -> Optional[List[Tuple[int, int]]]:
    """Return the validated signature regions of a Mach-O, or None for any other file."""
    magic = read(0, 4) if size >= 4 else b''
    if magic in MACHO_THIN:
        return thin_regions(read, 0, size)
    if magic not in MACHO_FAT:
        return None
    wide = MACHO_FAT[magic]
    entry_size = 32 if wide else 20
    if size < 8:
        raise Invalid('truncated Mach-O')
    count = struct.unpack('>I', exact(read, 4, 4))[0]
    if not 1 <= count <= FAT_SLICE_LIMIT:
        raise Invalid('invalid Mach-O slice count')
    header_end = 8 + count * entry_size
    if header_end > size:
        raise Invalid('truncated Mach-O')
    entries = exact(read, 8, count * entry_size)
    slices = []
    for index in range(count):
        if wide:
            offset, length = struct.unpack_from('>QQ', entries, index * entry_size + 8)
        else:
            offset, length = struct.unpack_from('>II', entries, index * entry_size + 8)
        if not length or offset < header_end or offset + length > size:
            raise Invalid('invalid Mach-O slice')
        slices.append((offset, offset + length))
    slices.sort()
    for previous, current in zip(slices, slices[1:]):
        if current[0] < previous[1]:
            raise Invalid('overlapping Mach-O slices')
    regions = []
    for start, end in slices:
        regions.extend(thin_regions(read, start, end - start))
    return regions


# Files and trees -------------------------------------------------------------------------------

def parse_property_list(data: bytes) -> Tuple[dict, bytes]:
    """Parse bounded XML only, without comments, custom DTDs, references or duplicate keys.

    The five predefined XML entities are the only references accepted. Return normalized
    UTF-8 source too, so raw occurrence counts use the same characters as the parsed values.
    """
    if len(data) > PROPERTY_LIST_LIMIT:
        raise Invalid('property list too large')

    class UniqueKeys(dict):
        def __setitem__(self, key: str, value: object) -> None:
            if key in self:
                raise Invalid('duplicate property list key')
            super().__setitem__(key, value)

    depth = 0

    def start_element(name: str, attributes: dict) -> None:
        nonlocal depth
        depth += 1
        if depth > PROPERTY_LIST_DEPTH:
            raise Invalid('property list too deep')

    def end_element(name: str) -> None:
        nonlocal depth
        depth -= 1

    def doctype(name: str, system: str, public: str, internal: int) -> None:
        if (name != 'plist' or system != 'http://www.apple.com/DTDs/PropertyList-1.0.dtd'
                or public != '-//Apple//DTD PLIST 1.0//EN' or internal):
            raise Invalid('property list doctype not allowed')

    def refuse(*arguments: object) -> None:
        raise Invalid('property list XML construct not allowed')

    try:
        if data.startswith((b'\xff\xfe', b'\xfe\xff')):
            text = data.decode('utf-16')
        elif data.startswith(b'<\0'):
            text = data.decode('utf-16-le')
        elif data.startswith(b'\0<'):
            text = data.decode('utf-16-be')
        else:
            text = data.decode('utf-8-sig')
        if re.search(r'&(?!amp;|lt;|gt;|quot;|apos;)', text):
            raise Invalid('property list reference not allowed')
        parser = expat.ParserCreate()
        parser.StartElementHandler = start_element
        parser.EndElementHandler = end_element
        parser.StartDoctypeDeclHandler = doctype
        parser.CommentHandler = refuse
        parser.EntityDeclHandler = refuse
        parser.Parse(data, True)
        document = plistlib.loads(data, fmt=plistlib.FMT_XML, dict_type=UniqueKeys)
        return document, text.encode('utf-8')
    except Invalid:
        raise
    except Exception as error:
        # Parser failures, including recursion/encoding failures, are always clean refusals.
        raise Invalid('invalid property list') from error


def check_property_list(data: bytes, names: Sequence[Term],
                        general: Sequence[Term] = ()) -> None:
    """Names may appear only in the copyright value of the bundle property list."""
    document, data = parse_property_list(data)
    check_terms(general, data)
    if not isinstance(document, dict):
        raise Invalid('invalid property list')
    copyright_value = document.get(COPYRIGHT_KEY, '')
    if not isinstance(copyright_value, str):
        raise Invalid('invalid property list')

    def visit(value: object, top: bool) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if not isinstance(key, str):
                    raise Invalid('invalid property list')
                check_terms((*general, *names), key.encode('utf-8', 'surrogatepass'))
                if top and key == COPYRIGHT_KEY:
                    check_terms(general, item.encode('utf-8', 'surrogatepass'))
                else:
                    visit(item, False)
        elif isinstance(value, list):
            for item in value:
                visit(item, False)
        elif isinstance(value, str):
            check_terms((*general, *names), value.encode('utf-8', 'surrogatepass'))
        elif isinstance(value, bytes):
            check_terms((*general, *names), value)

    try:
        visit(document, True)
    except RecursionError as error:
        raise Invalid('property list too deep') from error
    allowed = copyright_value.encode('utf-8', 'surrogatepass')
    for term in names:
        if matches(term, data) > matches(term, allowed):
            raise Invalid(term.label)


def scan_file(path: str, relative: str, policy: Policy,
              image_kinds: Optional[Set[str]] = None) -> None:
    """Check one regular file that is not a link; raise ScanFailure on any refusal."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ScanFailure(relative, 'unreadable file') from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise Invalid('unsupported file type')
        suffix = os.path.splitext(relative)[1].lower()
        kinds = image_kinds if image_kinds is not None else {suffix} & {'.png', '.icns'}
        if policy.structures and kinds:
            data = read_all(descriptor, info.st_size, IMAGE_LIMIT, 'image too large')

            def inspect(profile: bytes) -> None:
                check_terms((*policy.general, *policy.names), profile)

            for kind in sorted(kinds):
                if kind == '.png':
                    check_png(data, inspect)
                else:
                    check_icns(data, inspect)
            check_terms((*policy.general, *policy.names), data)
        elif policy.property_list:
            data = read_all(descriptor, info.st_size, PROPERTY_LIST_LIMIT,
                            'property list too large')
            check_terms(policy.general, data)
            check_property_list(data, policy.names, policy.general)
        else:
            regions = None
            if policy.structures:
                regions = macho_regions(positional_reader(descriptor), info.st_size)
            os.lseek(descriptor, 0, os.SEEK_SET)
            scan_stream(descriptor, policy, regions or (), policy.names)
    except Invalid as refusal:
        raise ScanFailure(relative, str(refusal)) from refusal
    except OSError as error:
        raise ScanFailure(relative, 'unreadable file') from error
    finally:
        os.close(descriptor)


@dataclass(frozen=True)
class Scan:
    """Root, terms, excluded prefixes and name-allowed paths as path components."""

    root: str
    general: Tuple[Term, ...]
    names: Tuple[Term, ...]
    excluded: Tuple[Tuple[str, ...], ...] = ()
    allowed: Tuple[Tuple[str, ...], ...] = ()
    bundle: bool = False

    def is_excluded(self, parts: Tuple[str, ...]) -> bool:
        return any(parts[:len(prefix)] == prefix for prefix in self.excluded)

    def inside(self, path: str) -> bool:
        return path == self.root or path.startswith(self.root + os.sep)

    def check_text(self, relative: str, data: bytes) -> None:
        term = first_match((*self.general, *self.names), data)
        if term is not None:
            raise ScanFailure(relative, term.label)


@dataclass
class Entry:
    """One real file and every path that reaches it."""

    relative: str
    path: str
    paths: Set[Tuple[str, ...]] = field(default_factory=set)
    excluded: bool = True
    linked: bool = False


def relative_name(parts: Tuple[str, ...]) -> str:
    return '/'.join(parts)


def resolve_link(scan: Scan, path: str, relative: str) -> str:
    """Return the destination of a relative link that resolves inside the root.

    realpath follows the chain the way the kernel does; a cycle or a missing target leaves a
    path that does not exist. Every link of an inside chain is itself visited by the walk.
    """
    if os.path.isabs(os.readlink(path)):
        raise ScanFailure(relative, 'absolute link')
    final = os.path.realpath(path)
    if not os.path.exists(final):
        raise ScanFailure(relative, 'dangling or cyclic link')
    if not scan.inside(final):
        raise ScanFailure(relative, 'link outside the root')
    return final


def walk(scan: Scan, directory: str, parts: Tuple[str, ...], files: Dict, links: List,
         check_names: bool, aliases: Optional[Dict] = None) -> None:
    """Visit the physical tree once without following links.

    Every link is validated. Links outside the excluded prefixes (all links when names are not
    checked, that is below a folder already reached through an alias) are returned in links.
    """
    with os.scandir(directory) as entries:
        children = sorted(entries, key=lambda entry: entry.name)
    for entry in children:
        child = (*parts, entry.name)
        relative = relative_name(child)
        excluded = check_names and scan.is_excluded(child)
        if check_names and not excluded:
            scan.check_text(relative, os.fsencode(relative))
        info = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode):
            if not excluded:
                scan.check_text(relative, os.fsencode(os.readlink(entry.path)))
            final = resolve_link(scan, entry.path, relative)
            if not excluded:
                links.append(final)
                if aliases is not None:
                    target = os.stat(final)
                    if stat.S_ISREG(target.st_mode):
                        key = (target.st_dev, target.st_ino)
                        aliases.setdefault(key, set()).add(child)
        elif stat.S_ISDIR(info.st_mode):
            walk(scan, entry.path, child, files, links, check_names, aliases)
        elif stat.S_ISREG(info.st_mode):
            key = (info.st_dev, info.st_ino)
            record = files.get(key)
            if record is None:
                record = files[key] = Entry(relative, entry.path)
            elif record.excluded and not excluded:
                record.relative, record.path = relative, entry.path
            record.paths.add(child)
            record.excluded = record.excluded and excluded
        else:
            raise ScanFailure(relative, 'unsupported file type')


def reachable(scan: Scan, links: List) -> Set:
    """Real files that links outside the exclusions expose, followed transitively."""
    selected = set()
    visited = set()
    pending = list(links)
    while pending:
        final = pending.pop()
        if final in visited:
            continue
        visited.add(final)
        info = os.lstat(final)
        if stat.S_ISREG(info.st_mode):
            selected.add((info.st_dev, info.st_ino))
        elif stat.S_ISDIR(info.st_mode):
            found: Dict = {}
            walk(scan, final, (), found, pending, False)
            selected.update(found)
    return selected


def file_policy(scan: Scan, record: Entry) -> Policy:
    direct = not record.linked
    names_allowed = direct and all(path in scan.allowed for path in record.paths)
    property_list = scan.bundle and direct and record.paths == {INFO_PLIST}
    general = bundle_terms(scan.general) if scan.bundle else scan.general
    names = bundle_terms(scan.names) if scan.bundle else scan.names
    return Policy(general=general, names=() if names_allowed else names,
                  property_list=property_list)


def scan_root(scan: Scan, path: str) -> int:
    """Return the number of real files under a bundle or tree, or raise ScanFailure."""
    if not stat.S_ISDIR(os.lstat(path).st_mode):
        raise ScanFailure('.', 'root is not a directory')
    files: Dict = {}
    links: List = []
    aliases: Dict = {}
    walk(scan, scan.root, (), files, links, True, aliases)
    if not files:
        raise ScanFailure('.', 'root has no files')
    for key in reachable(scan, links):
        if key in files:
            files[key].linked = True
            files[key].excluded = False
    for key, paths in aliases.items():
        files[key].paths.update(paths)
    for record in sorted(files.values(), key=lambda record: record.relative):
        if not record.excluded:
            kinds = {os.path.splitext(path[-1])[1].lower() for path in record.paths}
            scan_file(record.path, record.relative, file_policy(scan, record),
                      kinds & {'.png', '.icns'})
    return len(files)


def scan_texts(general: Tuple[Term, ...], names: Tuple[Term, ...], paths: List[str]) -> int:
    policy = Policy(general=general, names=names, structures=False)
    for path in paths:
        scan_file(path, path, policy)
    return len(paths)


def redacted(text: str, terms: Sequence[Term]) -> str:
    data = text.encode('utf-8', 'surrogateescape')
    for term in sorted(terms, key=lambda term: len(term.data), reverse=True):
        data = data.replace(term.data, f'[{term.label}]'.encode())
    return data.decode('utf-8', 'replace')


def relative_parts(value: str) -> Tuple[str, ...]:
    parts = tuple(part for part in value.split('/') if part)
    if not parts or value.startswith('/') or any(part in ('.', '..') for part in parts):
        raise UsageError('invalid relative path')
    return parts


def parser() -> Parser:
    root = Parser(prog='artifact-scan.py', add_help=False)
    commands = root.add_subparsers(dest='command', required=True)
    for name in ('bundle', 'tree', 'text'):
        command = commands.add_parser(name, add_help=False)
        if name == 'text':
            command.add_argument('paths', nargs='+')
        else:
            command.add_argument('root')
            command.add_argument('--allow-name', action='append', default=[])
        if name == 'bundle':
            command.add_argument('--exclude-prefix', action='append', default=[])
        command.add_argument('--forbid', action='append', default=[])
        command.add_argument('--terms-file')
        command.add_argument('--name-terms-file')
    return root


def main(arguments: List[str]) -> int:
    options = parser().parse_args(arguments)
    if not options.forbid and options.terms_file is None:
        raise UsageError('no terms')
    general = make_terms(options.forbid, 'term', False)
    if options.terms_file is not None:
        general += make_terms(read_terms_file(options.terms_file), 'term', True, len(general))
    names: Tuple[Term, ...] = ()
    if options.name_terms_file is not None:
        names = make_terms(read_terms_file(options.name_terms_file), 'name', True)
    every = (*general, *names)
    try:
        if options.command == 'text':
            count = scan_texts(general, names, options.paths)
        else:
            excluded = tuple(map(relative_parts, getattr(options, 'exclude_prefix', [])))
            allowed = tuple(map(relative_parts, options.allow_name))
            path = os.path.abspath(options.root)
            scan = Scan(root=os.path.realpath(path), general=general, names=names,
                        excluded=excluded, allowed=allowed, bundle=options.command == 'bundle')
            count = scan_root(scan, path)
    except ScanFailure as failure:
        print(f'artifact scan failed: {redacted(failure.relative, every)} ({failure.reason})',
              file=sys.stderr)
        return 1
    except OSError:
        print('artifact scan failed: . (unreadable artifact)', file=sys.stderr)
        return 1
    print(f'artifact scan passed: {count} files')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except UsageError:
        print('Usage: artifact-scan.py bundle BUNDLE [--exclude-prefix RELPATH...]'
              ' | tree DIR | text FILE...,'
              ' with --forbid TERM... and/or --terms-file FILE, [--name-terms-file FILE]'
              ' [--allow-name RELPATH...]', file=sys.stderr)
        sys.exit(USAGE_EXIT)
