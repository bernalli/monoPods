"""Artifact scan for forbidden terms and image metadata, exercised only against temporary files."""
import importlib.util
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


SCRIPTS = Path(__file__).resolve().parents[1]
TERM = 'Q7forbiddenQ7'
OTHER = 'Z9otherZ9'
# Invented terms only: the real lists live outside the repository.
NAME = 'Qorvath'
SURNAME = 'Belmundix'
WORD = 'Plonkle'
PHRASE = '/Vbox/qhome'
EVERY_TERM = (TERM, OTHER, NAME, SURNAME, WORD, PHRASE)
COPYRIGHT = f'Copyright (c) 2026 {NAME} {SURNAME}'
BLOCK = 1 << 20
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1d


def load_scanner():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('artifact_scan', SCRIPTS / 'artifact-scan.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scanner = load_scanner()


def chunk(kind, body):
    return (struct.pack('>I', len(body)) + kind + body
            + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff))


def header(width=1, height=1, depth=8, color=6, interlace=0):
    return chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, interlace))


IDAT = chunk(b'IDAT', zlib.compress(b'\0' * 5))
IEND = chunk(b'IEND', b'')
SRGB = chunk(b'sRGB', b'\0')
PHYS = chunk(b'pHYs', struct.pack('>IIB', 2835, 2835, 1))
PALETTE = chunk(b'PLTE', b'\0\0\0\xff\xff\xff')


def png(*ancillary, head=None, data=(IDAT,), tail=IEND):
    return PNG_SIGNATURE + (head or header()) + b''.join(ancillary) + b''.join(data) + tail


def profile(content, name=b'ICC Profile', method=b'\0', stream=None):
    body = zlib.compress(content) if stream is None else stream
    return chunk(b'iCCP', name + b'\0' + method + body)


def icns(*elements):
    body = b''.join(struct.pack('>4sI', kind, 8 + len(data)) + data for kind, data in elements)
    return b'icns' + struct.pack('>I', 8 + len(body)) + body


def segment(name, fileoff, filesize, protection):
    return struct.pack('<II16sQQQQiiII', LC_SEGMENT_64, 72, name, 0, filesize, fileoff, filesize,
                       protection, protection, 0, 0)


class Thin:
    """A thin 64-bit Mach-O: __TEXT covers header, commands and code; __LINKEDIT holds the
    signature super blob followed by padding, as codesign lays it out."""

    def __init__(self, code=b'\0' * 64, payload=b'\0' * 32, padding=16, signed=True,
                 extra=()):
        commands_size = 72 * 2 + (16 if signed else 0) + sum(map(len, extra))
        count = 2 + (1 if signed else 0) + len(extra)
        self.code_start = 32 + commands_size
        self.text_end = self.code_start + len(code)
        blob = (struct.pack('>IIIII', 0xfade0cc0, 28 + len(payload), 1, 0x10000, 20)
                + struct.pack('>II', 0xfade0b01, 8 + len(payload)) + payload)
        linkedit = blob + b'\0' * padding if signed else b''
        commands = (segment(b'__TEXT', 0, self.text_end, 5)
                    + segment(b'__LINKEDIT', self.text_end, len(linkedit), 1))
        self.signature_command = 32 + 144
        if signed:
            commands += struct.pack('<IIII', LC_CODE_SIGNATURE, 16, self.text_end, len(linkedit))
        commands += b''.join(extra)
        head = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, count, commands_size, 0, 0)
        self.data = head + commands + code + linkedit
        self.region = (self.text_end, self.text_end + 28 + len(payload))
        self.payload = (self.text_end + 28, self.region[1])

    def patch(self, offset, fmt, *values):
        data = bytearray(self.data)
        struct.pack_into(fmt, data, offset, *values)
        return bytes(data)


def fat(*slices, magic=0xcafebabe, layout=None):
    """A universal binary; layout overrides (offset, size) of each entry."""
    wide = magic == 0xcafebabf
    entry = 32 if wide else 20
    position = (8 + entry * len(slices) + 15) // 16 * 16
    places = []
    body = b''
    for item in slices:
        places.append((position, len(item)))
        body += b'\0' * (position - 8 - entry * len(slices) - len(body)) + item
        position = (position + len(item) + 15) // 16 * 16
    entries = b''
    for index, (offset, size) in enumerate(layout or places):
        if wide:
            entries += struct.pack('>IIQQII', 0x0100000c, 0, offset, size, 4, 0)
        else:
            entries += struct.pack('>IIIII', 0x0100000c, 0, offset, size, 4)
    return struct.pack('>II', magic, len(slices)) + entries + body, places


def reader(data):
    return lambda offset, length: data[offset:offset + length]


class TemporaryFiles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def put(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, str):
            data = data.encode()
        path.write_bytes(data)
        return path

    def run_scan(self, *arguments):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / 'artifact-scan.py'), *map(str, arguments)],
            capture_output=True, text=True, timeout=60,
            env={'PATH': '/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'})
        for term in EVERY_TERM:
            self.assertNotIn(term, result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        return result

    def terms_file(self, *lines, name='terms.txt'):
        return self.put(f'lists/{name}', '\n'.join(lines) + '\n')

    def assert_passed(self, result, files):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, f'artifact scan passed: {files} files\n')

    def assert_failed(self, result, relative=None, reason=None):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        output = result.stdout + result.stderr
        self.assertIn('artifact scan failed: ', output)
        if relative is not None:
            self.assertIn(relative, output)
        if reason is not None:
            self.assertIn(f'({reason})', output)

    def assert_usage(self, result):
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertNotIn('passed', result.stdout)


class ArtifactScanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bundle = self.root / 'MonoPods.app'
        self.write('Contents/Info.plist', plistlib.dumps({}))
        self.write('Contents/MacOS/MonoPods', Thin().data)

    def write(self, relative, data):
        path = self.bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def link(self, relative, target):
        path = self.bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return path

    def scan(self, *extra, bundle=None, terms=(TERM, OTHER)):
        args = [sys.executable, str(SCRIPTS / 'artifact-scan.py'), 'bundle',
                str(bundle or self.bundle)]
        for term in terms:
            args += ['--forbid', term]
        result = subprocess.run([*args, *extra], capture_output=True, text=True, timeout=20,
                                env={'PATH': '/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'})
        for term in terms:
            if term:
                self.assertNotIn(term, result.stdout + result.stderr)
        return result

    def assert_passed(self, result, files):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, f'artifact scan passed: {files} files\n')

    def assert_failed(self, result, relative=None, term=None):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        output = result.stdout + result.stderr
        self.assertIn('artifact scan failed: ', output)
        if relative is not None:
            self.assertIn(relative, output)
        if term is not None:
            self.assertIn(f'(term {term})', output)

    def test_clean_bundle_passes_and_counts_files(self):
        self.assert_passed(self.scan(), 2)

    def test_binary_info_is_refused_without_name_terms(self):
        self.write('Contents/Info.plist', plistlib.dumps({}, fmt=plistlib.FMT_BINARY))
        self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_term_anywhere_in_binary_content_fails(self):
        for prefix, suffix in ((b'', b'\0\xff tail'), (b'\0\xff head', b'\0\xff tail'),
                               (b'\0\xff head', b'')):
            with self.subTest(prefix=prefix, suffix=suffix):
                self.write('Contents/Resources/data', prefix + OTHER.encode() + suffix)
                self.assert_failed(self.scan(), 'Contents/Resources/data', 1)

    def test_term_in_a_file_name_fails_without_printing_it(self):
        self.write(f'Contents/Resources/a-{TERM}-b', b'clean')
        self.assert_failed(self.scan(), 'Contents/Resources/a-', 0)

    def test_valid_internal_relative_links_pass(self):
        self.write('Contents/Frameworks/F.framework/Versions/B/F', b'clean')
        self.link('Contents/Frameworks/F.framework/Versions/Current', 'B')
        self.link('Contents/Frameworks/F.framework/F', 'Versions/Current/F')
        self.assert_passed(self.scan(), 3)

    def test_absolute_escaping_cyclic_and_dangling_links_fail(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'clean')
        cases = {
            'absolute': [('Contents/Resources/link', str(self.bundle / 'Contents/Info.plist'))],
            'escape': [('Contents/Resources/first', 'second'),
                       ('Contents/Resources/second', '../../../outside')],
            'cycle': [('Contents/Resources/first', 'second'),
                      ('Contents/Resources/second', 'first')],
            'dangling': [('Contents/Resources/link', 'missing')],
        }
        for name, links in cases.items():
            with self.subTest(name=name):
                for relative, target in links:
                    self.link(relative, target)
                self.assert_failed(self.scan(), 'Contents/Resources/')
                for relative, _ in links:
                    (self.bundle / relative).unlink()

    def test_term_in_link_name_or_target_fails(self):
        self.write(f'Contents/Resources/{TERM}', b'clean')
        self.link('Contents/Resources/alias', TERM)
        self.assert_failed(self.scan(), term=0)
        (self.bundle / 'Contents/Resources/alias').unlink()
        (self.bundle / f'Contents/Resources/{TERM}').unlink()
        self.link(f'Contents/Resources/{OTHER}', '../Info.plist')
        self.assert_failed(self.scan(), term=1)

    def test_excluded_content_reached_through_an_alias_is_scanned(self):
        self.write('Contents/Frameworks/X/data', TERM.encode())
        excluded = ('--exclude-prefix', 'Contents/Frameworks/X/')
        self.assert_passed(self.scan(*excluded), 3)
        self.link('Contents/Resources/alias', '../Frameworks/X/data')
        self.assert_failed(self.scan(*excluded), term=0)
        (self.bundle / 'Contents/Resources/alias').unlink()
        self.link('Contents/Resources/folder', '../Frameworks/X')
        self.assert_failed(self.scan(*excluded), term=0)

    def test_exclusion_matches_whole_components_only(self):
        self.write('Contents/Frameworks/X/data', TERM.encode())
        excluded = ('--exclude-prefix', 'Contents/Frameworks/X/')
        self.assert_passed(self.scan(*excluded), 3)
        self.write('Contents/FrameworksX/data', TERM.encode())
        self.assert_failed(self.scan(*excluded), 'Contents/FrameworksX/data', 0)
        (self.bundle / 'Contents/FrameworksX/data').unlink()
        self.write('Contents/Frameworks/XY/data', TERM.encode())
        self.assert_failed(self.scan(*excluded), 'Contents/Frameworks/XY/data', 0)

    def test_special_files_fail(self):
        os.mkfifo(self.bundle / 'Contents/Resources-fifo')
        self.assert_failed(self.scan(), 'Contents/Resources-fifo')

    def test_bundle_link_and_empty_bundle_fail(self):
        link = self.root / 'Link.app'
        link.symlink_to(self.bundle)
        self.assert_failed(self.scan(bundle=link))
        empty = self.root / 'Empty.app'
        (empty / 'Contents').mkdir(parents=True)
        self.assert_failed(self.scan(bundle=empty))
        self.assert_failed(self.scan(bundle=self.root / 'Missing.app'))

    def test_usage_errors(self):
        for terms in ((), ('',), ('abc',), (TERM, 'abc')):
            with self.subTest(terms=terms):
                result = self.scan(terms=terms)
                self.assertEqual(result.returncode, 64)
                self.assertNotIn('passed', result.stdout)
        result = subprocess.run([sys.executable, str(SCRIPTS / 'artifact-scan.py')],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 64)

    def test_hardlink_scan_does_not_depend_on_excluded_alias_order(self):
        for excluded_name, included_name in (('A', 'Z'), ('Z', 'A')):
            with self.subTest(excluded=excluded_name):
                source = self.write(f'{excluded_name}/data', TERM.encode())
                alias = self.bundle / included_name
                os.link(source, alias)
                try:
                    self.assert_failed(
                        self.scan('--exclude-prefix', excluded_name),
                        included_name, 0,
                    )
                finally:
                    alias.unlink()
                    source.unlink()
                    source.parent.rmdir()

    def test_forbid_terms_stay_literal_substrings(self):
        self.write('Contents/Resources/data', b'x' + TERM.encode() + b'x')
        self.assert_failed(self.scan(), 'Contents/Resources/data', 0)

    def test_bundle_checks_images_and_mach_o_structure(self):
        self.write('Contents/Resources/Icon.png', png(chunk(b'tEXt', b'Comment\0x')))
        self.assert_failed(self.scan(), 'Contents/Resources/Icon.png')
        (self.bundle / 'Contents/Resources/Icon.png').unlink()
        self.write('Contents/Resources/AppIcon.icns', icns((b'ic07', png(chunk(b'eXIf', b'MM')))))
        self.assert_failed(self.scan(), 'Contents/Resources/AppIcon.icns')
        (self.bundle / 'Contents/Resources/AppIcon.icns').unlink()
        self.write('Contents/MacOS/MonoPods', b'\xcf\xfa\xed\xfe binary')
        self.assert_failed(self.scan(), 'Contents/MacOS/MonoPods')

    def test_excluded_images_are_not_parsed(self):
        self.write('Contents/Frameworks/X/Icon.png', b'not an image')
        self.assert_passed(self.scan('--exclude-prefix', 'Contents/Frameworks/X'), 3)


class ReadLimitTests(unittest.TestCase):
    def test_read_all_refuses_an_initially_oversized_file_before_reading(self):
        from unittest.mock import patch
        with patch.object(scanner.os, 'read', side_effect=AssertionError('unexpected read')) as read:
            with self.assertRaises(scanner.Invalid):
                scanner.read_all(7, 8, 7, 'too large')
            read.assert_not_called()

    def test_read_all_checks_the_running_total(self):
        from unittest.mock import patch
        for blocks, refused in (([b'abcd', b'efg', b''], False),
                                ([b'abcd', b'efgh', b''], True)):
            with self.subTest(refused=refused):
                with patch.object(scanner.os, 'read', side_effect=blocks):
                    if refused:
                        with self.assertRaises(scanner.Invalid):
                            scanner.read_all(7, 0, 7, 'too large')
                    else:
                        self.assertEqual(scanner.read_all(7, 0, 7, 'too large'), b'abcdefg')

    def test_stream_checks_the_running_total(self):
        from unittest.mock import patch
        for blocks, refused in (([b'abcd', b'efg', b''], False),
                                ([b'abcd', b'efgh', b''], True)):
            with self.subTest(refused=refused):
                with patch.object(scanner, 'READ_LIMIT', 7), patch.object(
                        scanner.os, 'read', side_effect=blocks):
                    if refused:
                        with self.assertRaises(scanner.Invalid):
                            scanner.scan_stream(7, scanner.Policy(general=()), (), ())
                    else:
                        scanner.scan_stream(7, scanner.Policy(general=()), (), ())


class TermFileTests(TemporaryFiles):
    def setUp(self):
        super().setUp()
        self.tree = self.root / 'tree'
        self.put('tree/a.txt', 'clean')

    def test_comments_blank_lines_and_spaces_are_ignored(self):
        terms = self.terms_file(f'# {NAME} is only a comment', '', f'  {WORD}  \r', '   ',
                                f'\t# {SURNAME}')
        self.put('tree/a.txt', f'{NAME} {SURNAME}')
        self.assert_passed(self.run_scan('tree', self.tree, '--terms-file', terms), 1)
        self.put('tree/a.txt', f'see {WORD}.')
        self.assert_failed(self.run_scan('tree', self.tree, '--terms-file', terms), 'a.txt',
                           'term 0')

    def test_terms_of_four_characters_are_accepted(self):
        terms = self.terms_file('Qwex', 'ñàéü')
        self.put('tree/a.txt', 'a ñàéü b')
        self.assert_failed(self.run_scan('tree', self.tree, '--terms-file', terms), 'a.txt',
                           'term 1')

    def test_invalid_term_files_are_usage_errors(self):
        cases = {
            'short': self.terms_file(WORD, 'abc', name='short'),
            'short-characters': self.terms_file('ñàé', name='short-characters'),
            'empty': self.put('lists/empty', b''),
            'comments-only': self.terms_file('# comment', '', name='comments-only'),
            'invalid-utf8': self.put('lists/invalid', b'\xff\xfeabcd\n'),
            'missing': self.root / 'lists/missing',
            'directory': self.root / 'lists',
        }
        for option in ('--terms-file', '--name-terms-file'):
            for name, path in cases.items():
                with self.subTest(option=option, case=name):
                    arguments = ['tree', self.tree, option, path]
                    if option == '--name-terms-file':
                        arguments += ['--terms-file', self.terms_file(WORD)]
                    self.assert_usage(self.run_scan(*arguments))

    def test_general_terms_are_required(self):
        names = self.terms_file(NAME, name='names.txt')
        self.assert_usage(self.run_scan('tree', self.tree))
        self.assert_usage(self.run_scan('tree', self.tree, '--name-terms-file', names))
        self.assert_passed(self.run_scan('tree', self.tree, '--forbid', TERM), 1)

    def test_terms_from_options_and_files_are_numbered_in_order(self):
        terms = self.terms_file(WORD, PHRASE)
        self.put('tree/a.txt', f'x{PHRASE}x')
        self.assert_failed(self.run_scan('tree', self.tree, '--forbid', TERM, '--terms-file',
                                         terms), 'a.txt', 'term 2')


class WordMatchTests(TemporaryFiles):
    def setUp(self):
        super().setUp()
        self.terms = self.terms_file(WORD, PHRASE)
        self.names = self.terms_file(NAME, SURNAME, name='names.txt')

    def text(self, data):
        path = self.put('notes.txt', data)
        return self.run_scan('text', path, '--terms-file', self.terms, '--name-terms-file',
                             self.names)

    def test_word_terms_match_whole_words_only(self):
        for content in (f'{NAME}e', f'x{NAME}', f'_{NAME}', f'{NAME}_', f'{NAME}9',
                        f'9{NAME}', f'{WORD}s', f'a{WORD}', NAME.lower(), NAME.upper()):
            with self.subTest(content=content):
                self.assert_passed(self.text(f'head {content} tail'), 1)
        for content in (NAME, f'{NAME}.', f'({NAME})', f'-{NAME}-', f'"{NAME}"', f'é{NAME}',
                        f'{NAME}\0', f'/{WORD}/', f'{WORD},'):
            with self.subTest(content=content):
                self.assert_failed(self.text(f'head {content} tail'), 'notes.txt')

    def test_word_terms_at_the_edges_of_the_file(self):
        for content in (NAME, f'{NAME} tail', f'head {NAME}', f'{NAME}\n'):
            with self.subTest(content=content):
                self.assert_failed(self.text(content), 'notes.txt', 'name 0')
        for content in (f'{NAME}x', f'x{NAME}'):
            with self.subTest(content=content):
                self.assert_passed(self.text(content), 1)

    def test_phrases_match_as_literal_substrings(self):
        for content in (f'a{PHRASE}b', f'{PHRASE}/x', PHRASE):
            with self.subTest(content=content):
                self.assert_failed(self.text(content), 'notes.txt', 'term 1')
        self.assert_passed(self.text(PHRASE.upper()), 1)

    def test_word_terms_across_one_mebibyte_blocks(self):
        token = NAME.encode()
        for start in range(BLOCK - len(token) - 2, BLOCK + 3):
            for filler, failed in ((b'a', False), (b'.', True)):
                with self.subTest(start=start, filler=filler):
                    data = filler * start + token + filler * 64
                    result = self.text(data)
                    if failed:
                        self.assert_failed(result, 'notes.txt', 'name 0')
                    else:
                        self.assert_passed(result, 1)

    def test_word_extended_by_the_first_byte_of_the_next_block_is_not_a_match(self):
        token = NAME.encode()
        before = b'.' * (BLOCK - len(token)) + token
        self.assert_passed(self.text(before + b's' + b'.' * 64), 1)
        self.assert_failed(self.text(before + b'.' * 64), 'notes.txt', 'name 0')
        self.assert_failed(self.text(before), 'notes.txt', 'name 0')
        after = b'.' * BLOCK + token
        self.assert_passed(self.text(b'.' * (BLOCK - 1) + b'x' + token + b'.'), 1)
        self.assert_failed(self.text(after), 'notes.txt', 'name 0')

    def test_phrase_across_one_mebibyte_blocks(self):
        token = PHRASE.encode()
        for start in range(BLOCK - len(token) - 1, BLOCK + 2):
            with self.subTest(start=start):
                self.assert_failed(self.text(b'a' * start + token + b'a' * 8), 'notes.txt',
                                   'term 1')


class TextCommandTests(TemporaryFiles):
    def setUp(self):
        super().setUp()
        self.terms = self.terms_file(WORD)

    def test_clean_files_pass_and_their_paths_are_not_scanned(self):
        first = self.put(f'{WORD}/appcast.xml', '<rss/>')
        second = self.put('notes.md', 'First public release.')
        self.assert_passed(self.run_scan('text', first, second, '--terms-file', self.terms), 2)

    def test_term_in_any_file_fails(self):
        first = self.put('appcast.xml', '<rss/>')
        second = self.put('notes.md', f'by {WORD}')
        self.assert_failed(self.run_scan('text', first, second, '--terms-file', self.terms),
                           'notes.md', 'term 0')

    def test_links_directories_and_missing_files_fail(self):
        target = self.put('notes.md', 'clean')
        link = self.root / 'link.md'
        link.symlink_to(target)
        for path in (link, self.root, self.root / 'missing.md'):
            with self.subTest(path=path.name):
                self.assert_failed(self.run_scan('text', path, '--terms-file', self.terms))

    def test_text_usage_errors(self):
        notes = self.put('notes.md', 'clean')
        self.assert_usage(self.run_scan('text', '--terms-file', self.terms))
        self.assert_usage(self.run_scan('text', notes, '--terms-file', self.terms,
                                        '--allow-name', 'notes.md'))
        self.assert_usage(self.run_scan('text', notes, '--terms-file', self.terms,
                                        '--exclude-prefix', 'x'))


class TreeCommandTests(TemporaryFiles):
    def setUp(self):
        super().setUp()
        self.tree = self.root / 'tree'
        self.put('tree/LICENSE', f'MIT License\n\n{COPYRIGHT}\n')
        self.put('tree/README.md', f'# App\n\nBy {NAME} {SURNAME}.\n')
        self.put('tree/scripts/tool.py', 'print(1)\n')
        self.put('tree/docs/images/banner.png', png(SRGB, PHYS))
        self.put('tree/Assets/AppIcon.icns', icns((b'is32', b'\x01' * 20), (b'ic07', png(SRGB))))
        self.terms = self.terms_file(WORD, PHRASE)
        self.names = self.terms_file(NAME, SURNAME, name='names.txt')

    def scan(self, *extra, allow=('LICENSE', 'README.md')):
        arguments = ['tree', self.tree, '--terms-file', self.terms, '--name-terms-file',
                     self.names]
        for relative in allow:
            arguments += ['--allow-name', relative]
        return self.run_scan(*arguments, *extra)

    def test_clean_tree_passes_with_names_only_in_allowed_files(self):
        self.assert_passed(self.scan(), 5)

    def test_names_outside_allowed_files_fail(self):
        self.assert_failed(self.scan(allow=('LICENSE',)), 'README.md', 'name 0')
        self.put('tree/scripts/tool.py', f'# {SURNAME}\n')
        self.assert_failed(self.scan(), 'scripts/tool.py', 'name 1')

    def test_allowed_names_are_exact_paths(self):
        self.put('tree/docs/LICENSE', f'{COPYRIGHT}\n')
        self.assert_failed(self.scan(), 'docs/LICENSE', 'name 0')

    def test_general_terms_fail_even_in_allowed_files(self):
        self.put('tree/README.md', f'{NAME} {WORD}\n')
        self.assert_failed(self.scan(), 'README.md', 'term 0')

    def test_names_in_file_names_fail(self):
        self.put(f'tree/docs/{SURNAME}.txt', 'clean')
        self.assert_failed(self.scan(), 'docs/', 'name 1')

    def test_aliases_of_allowed_files_fail(self):
        os.link(self.tree / 'LICENSE', self.tree / 'docs/copy.txt')
        self.assert_failed(self.scan(), reason='name 0')
        (self.tree / 'docs/copy.txt').unlink()
        (self.tree / 'docs/license-link').symlink_to('../LICENSE')
        self.assert_failed(self.scan(), reason='name 0')

    def test_images_in_the_tree_are_checked(self):
        for relative, data in (('docs/images/banner.png', png(chunk(b'tIME', b'\0' * 7))),
                               ('docs/images/UPPER.PNG', png(chunk(b'zTXt', b'k\0\0x'))),
                               ('Assets/AppIcon.icns', icns((b'ic07', png(chunk(b'iTXt', b'k')))))):
            with self.subTest(relative=relative):
                original = (self.tree / relative).read_bytes() if (self.tree / relative).exists() \
                    else None
                self.put(f'tree/{relative}', data)
                self.assert_failed(self.scan(), relative)
                if original is None:
                    (self.tree / relative).unlink()
                else:
                    self.put(f'tree/{relative}', original)

    def test_term_inside_a_compressed_color_profile_fails(self):
        for terms in ((WORD.encode(), 'term 0'), (NAME.encode(), 'name 0')):
            with self.subTest(term=terms[1]):
                self.put('tree/docs/images/banner.png',
                         png(profile(b'\0' * 40 + b' ' + terms[0] + b' ' + b'\0' * 40)))
                self.assert_failed(self.scan(), 'docs/images/banner.png', terms[1])

    def test_terms_in_raw_image_bytes_fail(self):
        cases = (
            ('Assets/AppIcon.icns', icns((b'is32', b' ' + WORD.encode() + b' ')), 'term 0'),
            ('Assets/AppIcon.icns', icns((b'info', b'<' + SURNAME.encode() + b'>')), 'name 1'),
            ('docs/images/banner.png', png(profile(b'x', name=NAME.encode())), 'name 0'),
            ('docs/images/banner.png', png(chunk(b'PLTE', NAME.encode() + b'\0\0'),
                                           head=header(color=3)), 'name 0'),
            # Element length 65 ends in the byte 'A', glued to the term that follows it.
            ('Assets/AppIcon.icns', icns((b'it32', WORD.encode() + b'\0' * 50)), 'term 0'),
        )
        for relative, data, reason in cases:
            with self.subTest(relative=relative, reason=reason):
                original = (self.tree / relative).read_bytes()
                self.put(f'tree/{relative}', data)
                self.assert_failed(self.scan(), relative, reason)
                self.put(f'tree/{relative}', original)

    def test_image_checks_use_every_alias_name(self):
        cases = (('.PNG', png(SRGB), png(chunk(b'tIME', b'\0' * 7))),
                 ('.icns', icns((b'ic07', png(SRGB))),
                  icns((b'ic07', png(chunk(b'eXIf', b'MM'))))))
        for suffix, clean, bad in cases:
            for linked in (False, True):
                with self.subTest(suffix=suffix, symlink=linked):
                    source = self.put('tree/a.data', clean)
                    alias = self.tree / ('z' + suffix)
                    if linked:
                        alias.symlink_to('a.data')
                    else:
                        os.link(source, alias)
                    try:
                        self.assert_passed(self.scan(), 6)
                        source.write_bytes(bad)
                        self.assert_failed(self.scan())
                    finally:
                        alias.unlink()
                        source.unlink()

    def test_tree_root_must_be_a_real_directory(self):
        link = self.root / 'link'
        link.symlink_to(self.tree)
        for path in (link, self.root / 'missing', self.tree / 'LICENSE'):
            with self.subTest(path=path.name):
                self.assert_failed(self.run_scan('tree', path, '--terms-file', self.terms))

    def test_tree_usage_errors(self):
        for allow in ('/LICENSE', '../LICENSE', 'docs/../LICENSE', './LICENSE', ''):
            with self.subTest(allow=allow):
                self.assert_usage(self.scan(allow=(allow,)))
        self.assert_usage(self.scan('--exclude-prefix', 'docs'))


class BundleNameTests(TemporaryFiles):
    def setUp(self):
        super().setUp()
        self.bundle = self.root / 'MonoPods.app'
        self.info = {'CFBundleName': 'MonoPods', 'NSHumanReadableCopyright': COPYRIGHT,
                     'CFBundleIdentifier': 'io.example.monopods'}
        self.write_info()
        self.put('MonoPods.app/Contents/MacOS/MonoPods', Thin().data)
        self.terms = self.terms_file(WORD, PHRASE)
        self.names = self.terms_file(NAME, SURNAME, name='names.txt')

    def write_info(self, data=None, binary=False):
        if data is None:
            data = plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY if binary
                                  else plistlib.FMT_XML)
        self.put('MonoPods.app/Contents/Info.plist', data)

    def scan(self):
        return self.run_scan('bundle', self.bundle, '--terms-file', self.terms,
                             '--name-terms-file', self.names)

    def test_names_in_the_copyright_value_pass(self):
        self.assert_passed(self.scan(), 2)
        self.write_info(binary=True)
        self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_names_elsewhere_in_the_property_list_fail(self):
        cases = {
            'value': {'CFBundleName': NAME},
            'key': {f'X{NAME}': NAME + 's', f'{NAME}': 'x'},
            'nested': {'List': ['a', {'b': f'by {SURNAME}'}]},
            'data': {'Blob': f' {NAME} '.encode()},
        }
        for case, extra in cases.items():
            for binary in (False, True):
                with self.subTest(case=case, binary=binary):
                    self.info = {'NSHumanReadableCopyright': COPYRIGHT, **extra}
                    self.write_info(binary=binary)
                    self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_names_hidden_in_the_raw_property_list_fail(self):
        data = plistlib.dumps(self.info).replace(b'<dict>', f'<!-- {NAME} --><dict>'.encode())
        self.write_info(data)
        self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_xml_comments_entities_and_nonstandard_doctypes_fail(self):
        clean = plistlib.dumps(self.info)
        doctype = (b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                   b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
        cases = {
            'comment': clean.replace(b'<dict>', b'<!-- harmless --><dict>'),
            'comment-with-encoded-copyright': clean.replace(
                NAME.encode(), b'&#81;orvath').replace(
                    b'<dict>', f'<!-- {NAME} --><dict>'.encode()),
            'decimal-reference': clean.replace(NAME.encode(), b'&#81;orvath'),
            'hex-reference': clean.replace(NAME.encode(), b'&#x51;orvath'),
            'unknown-entity': clean.replace(NAME.encode(), b'&someone;'),
            'custom-doctype': clean.replace(doctype, b'<!DOCTYPE plist SYSTEM "local.dtd">'),
            'internal-subset': clean.replace(doctype, b'<!DOCTYPE plist [<!ENTITY who "a">]>'),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.write_info(data)
                self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_duplicate_keys_fail_at_every_dictionary_depth(self):
        for depth in (0, 1, 12):
            with self.subTest(depth=depth):
                data = (b'<plist><dict><key>Container</key>'
                        + b'<array><dict><key>Child</key>' * depth
                        + b'<dict><key>same</key><string>first</string>'
                        b'<key>same</key><string>second</string></dict>'
                        + b'</dict></array>' * depth + b'</dict></plist>')
                self.write_info(data)
                self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_xml_depth_limit_is_explicit_and_refusal_is_clean(self):
        for depth, passes in ((60, True), (64, False), (1500, False)):
            with self.subTest(depth=depth):
                self.write_info(b'<plist><dict><key>Nested</key>' + b'<array>' * depth
                                + b'<string>clean</string>' + b'</array>' * depth
                                + b'</dict></plist>')
                if passes:
                    self.assert_passed(self.scan(), 2)
                else:
                    self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_cyclic_binary_property_list_is_refused_cleanly(self):
        # One array referring to itself; no recursive semantic walk is permitted.
        data = (b'bplist00' + b'\xa1\x00' + b'\x08'
                + struct.pack('>6xBBQQQ', 1, 1, 1, 0, 10))
        self.write_info(data)
        self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_standard_xml_entities_and_absent_doctype_pass(self):
        self.info['Other'] = '& < > " \' '
        clean = plistlib.dumps(self.info)
        self.write_info(clean)
        self.assert_passed(self.scan(), 2)
        first, last = clean.index(b'<!DOCTYPE'), clean.index(b'>', clean.index(b'<!DOCTYPE'))
        self.write_info(clean[:first] + clean[last + 1:])
        self.assert_passed(self.scan(), 2)

    def test_general_terms_fail_in_the_copyright_value(self):
        self.info['NSHumanReadableCopyright'] = f'{COPYRIGHT} {WORD}'
        self.write_info()
        self.assert_failed(self.scan(), 'Contents/Info.plist', 'term 0')

    def test_invalid_property_lists_fail_when_names_are_checked(self):
        for data in (b'<plist', b'bplist00garbage', plistlib.dumps(['not', 'a', 'dict']),
                     plistlib.dumps({'NSHumanReadableCopyright': 7})):
            with self.subTest(data=data[:12]):
                self.write_info(data)
                self.assert_failed(self.scan(), 'Contents/Info.plist')

    def test_only_the_bundle_property_list_carries_the_copyright(self):
        nested = plistlib.dumps({'NSHumanReadableCopyright': COPYRIGHT})
        self.put('MonoPods.app/Contents/Frameworks/F.framework/Resources/Info.plist', nested)
        self.assert_failed(self.scan(), 'Contents/Frameworks/F.framework/Resources/Info.plist',
                           'name 0')

    def test_utf16_resources_with_and_without_bom_fail(self):
        for encoding, bom in (('utf-16-le', b'\xff\xfe'), ('utf-16-be', b'\xfe\xff')):
            for marker in (b'', bom):
                for text in (f' {NAME} ', f' {WORD} ', f'x{PHRASE}y'):
                    with self.subTest(encoding=encoding, bom=bool(marker), text=text):
                        self.put('MonoPods.app/Contents/Resources/localized',
                                 marker + text.encode(encoding))
                        self.assert_failed(self.scan(), 'Contents/Resources/localized')

    def test_utf16_matches_across_block_boundaries(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for text in (f' {NAME} ', f' {WORD} ', f'x{PHRASE}y'):
                token = text.encode(encoding)
                for start in (BLOCK - 1, BLOCK - len(token) + 1, BLOCK - len(token)):
                    with self.subTest(encoding=encoding, text=text, start=start):
                        self.put('MonoPods.app/Contents/Resources/localized',
                                 b'\0' * start + token + b'\0' * 4)
                        self.assert_failed(self.scan(), 'Contents/Resources/localized')

    def test_utf16_whole_word_one_unit_before_a_block_edge_is_found(self):
        # The longest term is a whole word; a non-zero filler keeps the other byte order
        # from masking a missed occurrence.
        terms = scanner.bundle_terms(scanner.make_terms([WORD], 'term', True))
        policy = scanner.Policy(general=terms)
        longest = max(len(term.data) for term in terms)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'resource')
            for encoding in ('utf-16-le', 'utf-16-be'):
                token = WORD.encode(encoding)
                data = bytearray(b'\x01' * (2 * scanner.BLOCK_SIZE + 64))
                start = scanner.BLOCK_SIZE - longest - 1
                data[start:start + len(token)] = token
                with open(path, 'wb') as stream:
                    stream.write(data)
                descriptor = os.open(path, os.O_RDONLY)
                try:
                    with self.subTest(encoding=encoding):
                        with self.assertRaises(scanner.Invalid):
                            scanner.scan_stream(descriptor, policy, (), ())
                finally:
                    os.close(descriptor)

    def test_utf16_whole_words_and_case_are_preserved(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for text, fails in ((f'x{NAME}', False), (f'{NAME}_', False),
                                (NAME.lower(), False), (f'x{WORD}', False),
                                (f'{WORD}9', False), (f'é{NAME}!', True)):
                with self.subTest(encoding=encoding, text=text):
                    self.put('MonoPods.app/Contents/Resources/localized', text.encode(encoding))
                    if fails:
                        self.assert_failed(self.scan(), 'Contents/Resources/localized')
                    else:
                        self.assert_passed(self.scan(), 3)

    def test_utf16_bundle_info_keeps_only_the_copyright_exception(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            clean = plistlib.dumps(self.info).decode().replace('encoding="UTF-8"',
                                                             'encoding="UTF-16"')
            bom = b'\xff\xfe' if encoding.endswith('le') else b'\xfe\xff'
            with self.subTest(encoding=encoding):
                self.write_info(bom + clean.encode(encoding))
                self.assert_passed(self.scan(), 2)
                self.write_info(bom + clean.replace(COPYRIGHT, COPYRIGHT + ' ' + WORD).encode(
                    encoding))
                self.assert_failed(self.scan(), 'Contents/Info.plist', 'term 0')
                self.write_info(bom + clean.replace('<dict>', '<dict><key>Other</key>'
                                                   f'<string>{NAME}</string>').encode(encoding))
                self.assert_failed(self.scan(), 'Contents/Info.plist', 'name 0')

    def test_utf16_signature_names_pass_but_general_terms_fail(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for text, fails in ((f' {NAME} ', False), (f' {WORD} ', True)):
                with self.subTest(encoding=encoding, text=text):
                    self.put('MonoPods.app/Contents/MacOS/MonoPods',
                             Thin(payload=text.encode(encoding)).data)
                    if fails:
                        self.assert_failed(self.scan(), 'Contents/MacOS/MonoPods', 'term 0')
                    else:
                        self.assert_passed(self.scan(), 2)

    def test_general_terms_in_copyright_references_fail(self):
        clean = plistlib.dumps(self.info)
        self.write_info(clean.replace(COPYRIGHT.encode(), (COPYRIGHT + ' &#80;lonkle').encode()))
        self.assert_failed(self.scan(), 'Contents/Info.plist')
        # A literal term containing XML punctuation must also be checked after parsing.
        terms = self.terms_file('Bex&Co', name='punctuation.txt')
        self.write_info(clean.replace(COPYRIGHT.encode(), (COPYRIGHT + ' Bex&amp;Co').encode()))
        self.assert_failed(self.run_scan('bundle', self.bundle, '--terms-file', terms,
                                        '--name-terms-file', self.names), 'Contents/Info.plist',
                           'term 0')

    def test_names_in_the_signature_region_pass_and_in_code_fail(self):
        signed = Thin(payload=b'\0' + f'{NAME} {SURNAME}'.encode() + b'\0' * 8)
        self.put('MonoPods.app/Contents/MacOS/MonoPods', signed.data)
        self.assert_passed(self.scan(), 2)
        code = Thin(code=b'\0' + NAME.encode() + b'\0' * 56)
        self.put('MonoPods.app/Contents/MacOS/MonoPods', code.data)
        self.assert_failed(self.scan(), 'Contents/MacOS/MonoPods', 'name 0')

    def test_general_terms_in_the_signature_region_fail(self):
        signed = Thin(payload=b'\0' + WORD.encode() + b'\0' * 8)
        self.put('MonoPods.app/Contents/MacOS/MonoPods', signed.data)
        self.assert_failed(self.scan(), 'Contents/MacOS/MonoPods', 'term 0')

    def test_names_in_the_signature_of_every_fat_slice_pass(self):
        first = Thin(payload=b'\0' + NAME.encode() + b'\0' * 8)
        second = Thin(payload=b'\0' + SURNAME.encode() + b'\0' * 8)
        data, _ = fat(first.data, second.data)
        self.put('MonoPods.app/Contents/MacOS/MonoPods', data)
        self.assert_passed(self.scan(), 2)
        broken, _ = fat(first.data, Thin(code=b'\0' + SURNAME.encode() + b'\0' * 54).data)
        self.put('MonoPods.app/Contents/MacOS/MonoPods', broken)
        self.assert_failed(self.scan(), 'Contents/MacOS/MonoPods', 'name 1')


class PngTests(unittest.TestCase):
    def check(self, data):
        profiles = []
        scanner.check_png(data, profiles.append)
        return profiles

    def assert_invalid(self, data):
        with self.assertRaises(scanner.Invalid):
            self.check(data)

    def test_png_without_metadata_passes(self):
        for data in (png(), png(SRGB, PHYS), png(chunk(b'gAMA', b'\0\0\xb1\x8f'),
                                                 chunk(b'cHRM', b'\0' * 32),
                                                 chunk(b'sBIT', b'\x08' * 4),
                                                 chunk(b'cICP', b'\x01\x0d\x00\x01'),
                                                 chunk(b'iDOT', b'\0' * 28), PHYS,
                                                 chunk(b'bKGD', b'\0' * 6)),
                     png(PALETTE, chunk(b'tRNS', b'\0'), chunk(b'bKGD', b'\x01'),
                         head=header(depth=8, color=3)),
                     png(head=header(width=16384, height=3906)),
                     png(data=(IDAT, IDAT, IDAT))):
            with self.subTest(data=data[:40]):
                self.check(data)

    def test_color_profile_is_decompressed_for_inspection(self):
        fields = self.check(png(profile(b'profile bytes')))
        self.assertIn(b'ICC Profile', fields)
        self.assertIn(b'profile bytes', fields)

    def test_every_chunk_body_is_inspected_as_a_field(self):
        palette = b'\x01\x02\x03' + b'Qor' + b'vat'
        fields = self.check(png(chunk(b'PLTE', palette), head=header(color=3)))
        self.assertIn(palette, fields)
        self.assertIn(header()[8:-4], self.check(png()))

    def test_metadata_and_unknown_chunks_fail(self):
        for kind in (b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'tIME', b'vpAg', b'caNv', b'orNT',
                     b'acTL', b'hIST', b'sPLT', b'IDOT', b'idot'):
            with self.subTest(kind=kind):
                self.assert_invalid(png(chunk(kind, b'\0' * 8)))
                self.assert_invalid(png(tail=chunk(kind, b'\0' * 8) + IEND))

    def test_crc_errors_fail(self):
        data = bytearray(png(SRGB))
        for offset in range(8, len(data)):
            with self.subTest(offset=offset):
                mutated = bytearray(data)
                mutated[offset] ^= 0x01
                self.assert_invalid(bytes(mutated))

    def test_every_truncation_fails_cleanly(self):
        data = png(SRGB, PHYS, profile(b'p' * 40))
        for length in range(len(data)):
            with self.subTest(length=length):
                self.assert_invalid(data[:length])

    def test_chunk_order_and_cardinality(self):
        cases = {
            'ihdr-not-first': PNG_SIGNATURE + SRGB + header() + IDAT + IEND,
            'ihdr-twice': png(header()),
            'iend-not-last': png(tail=IEND + IEND),
            'iend-before-idat': PNG_SIGNATURE + header() + IEND + IDAT,
            'bytes-after-iend': png() + b'\0',
            'missing-iend': png(tail=b''),
            'missing-idat': png(data=()),
            'idat-not-contiguous': png(data=(IDAT, PHYS, IDAT)),
            'ancillary-after-idat': png(tail=PHYS + IEND),
            'srgb-twice': png(SRGB, SRGB),
            'phys-twice': png(PHYS, PHYS),
            'iccp-twice': png(profile(b'a'), profile(b'a')),
            'palette-twice': png(PALETTE, PALETTE, head=header(color=3)),
            'palette-after-trns': png(chunk(b'tRNS', b'\0'), PALETTE, head=header(color=3)),
            'trns-without-palette': png(chunk(b'tRNS', b'\0'), head=header(color=3)),
            'bkgd-before-palette': png(chunk(b'bKGD', b'\0'), PALETTE, head=header(color=3)),
            'srgb-after-palette': png(PALETTE, SRGB, head=header(color=3)),
            'missing-palette': png(head=header(color=3)),
            'palette-in-grey': png(PALETTE, head=header(color=0)),
            'palette-in-grey-alpha': png(PALETTE, head=header(color=4)),
            'trns-with-alpha': png(chunk(b'tRNS', b'\0' * 6), head=header(color=6)),
            'trns-too-long': png(PALETTE, chunk(b'tRNS', b'\0\0\0'), head=header(color=3)),
            'palette-too-long': png(chunk(b'PLTE', b'\0' * 9), head=header(depth=1, color=3)),
            'palette-not-triplets': png(chunk(b'PLTE', b'\0' * 4), head=header(color=3)),
            'short-ihdr': PNG_SIGNATURE + chunk(b'IHDR', b'\0' * 12) + IDAT + IEND,
            'long-iend': png(tail=chunk(b'IEND', b'\0')),
            'short-srgb': png(chunk(b'sRGB', b'')),
            'short-phys': png(chunk(b'pHYs', b'\0' * 8)),
            'wrong-sbit': png(chunk(b'sBIT', b'\x08' * 3)),
            'wrong-bkgd': png(chunk(b'bKGD', b'\0' * 2)),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)

    def test_header_values(self):
        for width, height in ((0, 1), (1, 0), (16385, 1), (1, 16385), (16384, 3907),
                              (0xffffffff, 0xffffffff)):
            with self.subTest(width=width, height=height):
                self.assert_invalid(png(head=header(width=width, height=height)))
        valid = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
        for color in range(8):
            for depth in (0, 1, 2, 3, 4, 8, 16, 32):
                with self.subTest(color=color, depth=depth):
                    extra = (PALETTE,) if color == 3 else ()
                    data = png(*extra, head=header(depth=depth, color=color))
                    if depth in valid.get(color, ()):
                        self.check(data)
                    else:
                        self.assert_invalid(data)
        for compression, filtering, interlace in ((1, 0, 0), (0, 1, 0), (0, 0, 2)):
            body = struct.pack('>IIBBBBB', 1, 1, 8, 6, compression, filtering, interlace)
            self.assert_invalid(PNG_SIGNATURE + chunk(b'IHDR', body) + IDAT + IEND)

    def test_chunk_length_past_the_end_fails(self):
        data = bytearray(png(SRGB))
        struct.pack_into('>I', data, 33, 0x7fffffff)
        self.assert_invalid(bytes(data))
        struct.pack_into('>I', data, 33, 0x80000000)
        self.assert_invalid(bytes(data))

    def test_invalid_color_profiles_fail(self):
        stream = zlib.compress(b'profile')
        cases = {
            'no-name': profile(b'x', name=b''),
            'long-name': profile(b'x', name=b'n' * 80),
            'method': profile(b'x', method=b'\x01'),
            'no-separator': chunk(b'iCCP', b'name'),
            'truncated-stream': profile(b'', stream=stream[:-3]),
            'trailing-data': profile(b'', stream=stream + b'\0'),
            'garbage': profile(b'', stream=b'\x00\x01\x02\x03'),
            'empty-stream': profile(b'', stream=b''),
        }
        for name, iccp in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(png(iccp))

    def test_color_profile_limit_is_applied_while_decompressing(self):
        limit = 4 << 20
        self.assertEqual(max(map(len, self.check(png(profile(b'\0' * limit))))), limit)
        bomb = zlib.compress(b'\0' * (64 << 20), 9)
        self.assertLess(len(bomb), 1 << 20)
        self.assert_invalid(png(profile(b'', stream=bomb)))
        self.assert_invalid(png(profile(b'\0' * (limit + 1))))

    def test_size_and_chunk_limits(self):
        self.assert_invalid(png(data=(IDAT,) * 4095))
        self.check(png(data=(IDAT,) * 4094))
        self.assert_invalid(PNG_SIGNATURE + b'\0' * (64 << 20))


class IcnsTests(unittest.TestCase):
    def check(self, data):
        profiles = []
        scanner.check_icns(data, profiles.append)
        return profiles

    def assert_invalid(self, data):
        with self.assertRaises(scanner.Invalid):
            self.check(data)

    def sample(self):
        return icns((b'TOC ', b'is32\0\0\0\x14'), (b'is32', b'\x01' * 12), (b'ic07', png(SRGB)),
                    (b'ic08', png(profile(b'abc'))))

    def test_valid_icns_passes_and_inspects_png_profiles(self):
        fields = self.check(self.sample())
        for field in (b'is32\0\0\0\x14', b'\x01' * 12, b'ICC Profile', b'abc'):
            self.assertIn(field, fields)
        self.assertEqual(self.check(icns()), [])

    def test_header_length_must_match_the_file(self):
        data = self.sample()
        for delta in (-1, 1, 8):
            with self.subTest(delta=delta):
                mutated = bytearray(data)
                struct.pack_into('>I', mutated, 4, len(data) + delta)
                self.assert_invalid(bytes(mutated))
        self.assert_invalid(data + b'\0')
        self.assert_invalid(b'icnx' + data[4:])

    def test_every_truncation_fails(self):
        data = self.sample()
        for length in range(len(data)):
            with self.subTest(length=length):
                self.assert_invalid(data[:length])

    def test_inconsistent_element_lengths_fail(self):
        data = self.sample()
        offsets = []
        cursor = 8
        while cursor < len(data):
            offsets.append(cursor)
            cursor += struct.unpack_from('>I', data, cursor + 4)[0]
        for offset in offsets:
            length = struct.unpack_from('>I', data, offset + 4)[0]
            for value in (*range(8), length - 1, length + 1, len(data), 0xffffffff):
                with self.subTest(offset=offset, value=value):
                    mutated = bytearray(data)
                    struct.pack_into('>I', mutated, offset + 4, value)
                    self.assert_invalid(bytes(mutated))

    def test_png_elements_with_metadata_fail(self):
        for kind in (b'eXIf', b'tEXt', b'iTXt', b'zTXt', b'tIME'):
            with self.subTest(kind=kind):
                self.assert_invalid(icns((b'ic07', png(chunk(kind, b'\0' * 4)))))
        self.assert_invalid(icns((b'ic07', png()[:-1])))

    def test_limits(self):
        self.assert_invalid(icns(*[(b'is32', b'')] * 4097))
        self.check(icns(*[(b'is32', b'')] * 4096))
        self.assert_invalid(icns((b'is32', b'\0' * (64 << 20))))


class MachOTests(unittest.TestCase):
    def regions(self, data):
        return scanner.macho_regions(reader(data), len(data))

    def assert_invalid(self, data):
        with self.assertRaises(scanner.Invalid):
            self.regions(data)

    def test_signature_region_of_a_thin_binary(self):
        binary = Thin()
        self.assertEqual(self.regions(binary.data), [binary.region])
        self.assertEqual(self.regions(Thin(signed=False).data), [])
        self.assertIsNone(self.regions(b'plain text'))
        self.assertIsNone(self.regions(b'\xcf\xfa'))

    def test_every_truncation_fails(self):
        data = Thin().data
        for length in range(4, len(data)):
            with self.subTest(length=length):
                self.assert_invalid(data[:length])

    def test_duplicate_code_signature_fails(self):
        binary = Thin()
        duplicate = struct.pack('<IIII', LC_CODE_SIGNATURE, 16, binary.text_end, 60)
        self.assert_invalid(Thin(extra=(duplicate,)).data)

    def test_inconsistent_command_sizes_fail(self):
        binary = Thin()
        cases = {
            'sizeofcmds-short': binary.patch(20, '<I', 160 - 8),
            'sizeofcmds-long': binary.patch(20, '<I', 160 + 8),
            'sizeofcmds-huge': binary.patch(20, '<I', 0xffffffff),
            'ncmds-more': binary.patch(16, '<I', 4),
            'ncmds-fewer': binary.patch(16, '<I', 2),
            'ncmds-limit': binary.patch(16, '<I', 65537),
            'cmdsize-small': binary.patch(36, '<I', 4),
            'cmdsize-zero': binary.patch(36, '<I', 0),
            'cmdsize-unaligned': binary.patch(36, '<I', 76),
            'cmdsize-past-commands': binary.patch(36, '<I', 72 + 160),
            'signature-cmdsize': binary.patch(binary.signature_command + 4, '<I', 24),
            'segment-cmdsize': binary.patch(36, '<I', 64),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)

    def test_signature_must_not_cover_header_commands_or_code(self):
        binary = Thin()
        command = binary.signature_command
        cases = {
            'header': binary.patch(command + 8, '<I', 0),
            'commands': binary.patch(command + 8, '<I', 40),
            'executable-segment': binary.patch(32 + 48, '<Q', len(binary.data)),
            'executable-linkedit': binary.patch(32 + 72 + 56, '<ii', 7, 7),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)

    def test_signature_bounds_and_super_blob(self):
        binary = Thin()
        command = binary.signature_command
        start = binary.text_end
        cases = {
            'past-the-end': binary.patch(command + 12, '<I', len(binary.data)),
            'overflow': binary.patch(command + 8, '<II', 0xfffffff0, 0x20),
            'empty': binary.patch(command + 12, '<I', 0),
            'magic': binary.patch(start, '>I', 0xfade0c02),
            'blob-longer-than-data': binary.patch(start + 4, '>I', binary.region[1] - start + 17),
            'blob-shorter-than-header': binary.patch(start + 4, '>I', 11),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)

    def test_signature_requires_linkedit_containment(self):
        binary = Thin()
        linkedit = 32 + 72
        cases = {
            'data-segment': binary.patch(linkedit + 8, '16s', b'__DATA'),
            'starts-before-linkedit': binary.patch(linkedit + 40, '<QQ',
                                                  binary.text_end + 1,
                                                  len(binary.data) - binary.text_end - 1),
            'extends-past-linkedit': binary.patch(linkedit + 48, '<Q', 28),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)

    def test_superblob_index_and_child_bounds(self):
        binary = Thin()
        start = binary.text_end
        cases = {
            'count-overflow': binary.patch(start + 8, '>I', 0xffffffff),
            'index-too-long': binary.patch(start + 8, '>I', 7),
            'offset-in-header': binary.patch(start + 16, '>I', 0),
            'offset-in-index': binary.patch(start + 16, '>I', 12),
            'offset-at-end': binary.patch(start + 16, '>I', 60),
            'offset-overflow': binary.patch(start + 16, '>I', 0xffffffff),
            'child-magic': binary.patch(start + 20, '>I', 0),
            'child-length-small': binary.patch(start + 24, '>I', 7),
            'child-length-large': binary.patch(start + 24, '>I', 0xffffffff),
            'unreferenced-content': binary.patch(start + 8, '>I', 0),
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(data)
        # A malformed child in either fat slice must refuse the entire file.
        self.assert_invalid(fat(Thin().data, cases['count-overflow'])[0])

    def test_superblob_duplicate_and_overlapping_references(self):
        binary = Thin(payload=b'\0' * 64)
        start = binary.text_end
        data = bytearray(binary.data)
        # Two contiguous child blobs, with index order deliberately reversed.
        struct.pack_into('>III', data, start, 0xfade0cc0, 92, 2)
        struct.pack_into('>IIII', data, start + 12, 0x10000, 60, 2, 28)
        struct.pack_into('>II', data, start + 28, 0xfade0c01, 32)
        struct.pack_into('>II', data, start + 60, 0xfade0b01, 32)
        self.assertEqual(self.regions(bytes(data)), [binary.region])
        for name, location, value in (
                ('duplicate-offset', 24, 60), ('overlap', 32, 40),
                ('duplicate-slot', 20, 0x10000), ('unknown-slot', 20, 0x77777777),
                ('slot-magic-mismatch', 28, 0xfade0b01)):
            with self.subTest(name=name):
                mutated = bytearray(data)
                struct.pack_into('>I', mutated, start + location, value)
                self.assert_invalid(bytes(mutated))

    def test_segments_must_stay_inside_the_file(self):
        binary = Thin()
        for name, offset, value in (('fileoff', 32 + 72 + 40, 0xffffffffffffffff),
                                    ('filesize', 32 + 72 + 48, 0xffffffffffffff00),
                                    ('past-the-end', 32 + 72 + 48, 1 << 20)):
            with self.subTest(name=name):
                self.assert_invalid(binary.patch(offset, '<Q', value))

    def test_fat_binaries_report_the_region_of_every_slice(self):
        first, second = Thin(), Thin(code=b'\x01' * 96)
        for magic in (0xcafebabe, 0xcafebabf):
            with self.subTest(magic=magic):
                data, places = fat(first.data, second.data, magic=magic)
                expected = [(places[0][0] + first.region[0], places[0][0] + first.region[1]),
                            (places[1][0] + second.region[0], places[1][0] + second.region[1])]
                self.assertEqual(sorted(self.regions(data)), expected)

    def test_invalid_fat_layouts_fail(self):
        first, second = Thin().data, Thin(code=b'\x01' * 96).data
        data, places = fat(first, second)
        (a, a_size), (b, b_size) = places
        cases = {
            'offset-past-the-end': [(a, a_size), (len(data) + 16, b_size)],
            'size-past-the-end': [(a, a_size), (b, b_size + 16)],
            'overlap': [(a, a_size), (a + 16, b_size)],
            'same-slice': [(a, a_size), (a, a_size)],
            'header-overlap': [(0, a_size), (b, b_size)],
            'empty-slice': [(a, 0), (b, b_size)],
            'overflow': [(a, a_size), (0xfffffff0, 0x20)],
        }
        for name, layout in cases.items():
            with self.subTest(name=name):
                self.assert_invalid(fat(first, second, layout=layout)[0])
        _, wide_places = fat(first, second, magic=0xcafebabf)
        wide = fat(first, second, magic=0xcafebabf,
                   layout=[wide_places[0], (0xfffffffffffffff0, 0x20)])[0]
        self.assert_invalid(wide)

    def test_fat_counts_and_slice_types(self):
        first = Thin().data
        self.assert_invalid(struct.pack('>II', 0xcafebabe, 0))
        self.assert_invalid(fat(*[first] * 65)[0])
        self.assertEqual(len(self.regions(fat(*[first] * 64)[0])), 64)
        nested, _ = fat(first)
        self.assert_invalid(fat(nested)[0])
        self.assert_invalid(fat(b'\0' * 64)[0])
        self.assert_invalid(fat(first[:-1])[0])
        data, _ = fat(first)
        for length in range(4, len(data)):
            with self.subTest(length=length):
                self.assert_invalid(data[:length])

    def test_thin_32_bit_binary(self):
        commands = (struct.pack('<II16sIIIIiiII', LC_SEGMENT, 56, b'__TEXT', 0, 160, 0, 160, 5,
                                5, 0, 0)
                    + struct.pack('<II16sIIIIiiII', LC_SEGMENT, 56, b'__LINKEDIT', 0, 28, 160, 28,
                                  1, 1, 0, 0)
                    + struct.pack('<IIII', LC_CODE_SIGNATURE, 16, 160, 28))
        head = struct.pack('<IIIIIII', 0xfeedface, 12, 0, 2, 3, len(commands), 0)
        body = head + commands
        self.assertEqual(len(body), 156)
        data = (body + b'\0' * 4 + struct.pack('>IIIII', 0xfade0cc0, 28, 1, 0x10000, 20)
                + struct.pack('>II', 0xfade0b01, 8))
        self.assertEqual(self.regions(data), [(160, 188)])
        self.assert_invalid(data[:-1])
        self.assert_invalid(data[:32] + struct.pack('<I', 58) + data[36:])


class RepositoryImageTests(unittest.TestCase):
    def test_repository_images_carry_no_metadata(self):
        repository = SCRIPTS.parent
        images = sorted(path for path in repository.rglob('*')
                        if path.suffix.lower() in ('.png', '.icns')
                        and not any(part == 'build' or part.startswith('.')
                                    for part in path.relative_to(repository).parts))
        self.assertTrue(any(path.suffix == '.icns' for path in images))
        self.assertTrue(any(path.suffix == '.png' for path in images))
        for path in images:
            with self.subTest(path=str(path.relative_to(repository))):
                check = scanner.check_icns if path.suffix.lower() == '.icns' else scanner.check_png
                check(path.read_bytes(), lambda profile: None)


class MutationVisibilityTests(TemporaryFiles):
    """Every name written outside a validated signature region is reported."""

    def setUp(self):
        super().setUp()
        self.policy = scanner.Policy(
            general=scanner.make_terms([WORD], 'term', True),
            names=scanner.make_terms([NAME], 'name', True))
        self.token = b'\0' + NAME.encode() + b'\0'

    def scan(self, data):
        path = self.put('binary', data)
        scanner.scan_file(str(path), 'binary', self.policy)

    def mutations(self, data, regions):
        for offset in range(len(data) - len(self.token) + 1):
            end = offset + len(self.token)
            inside = any(start <= offset and end <= stop for start, stop in regions)
            outside = all(end <= start or offset >= stop for start, stop in regions)
            mutated = data[:offset] + self.token + data[end:]
            yield offset, inside, outside, mutated

    def check_binary(self, data, regions, payloads):
        self.scan(data)
        for offset, _, outside, mutated in self.mutations(data, regions):
            if outside:
                with self.subTest(offset=offset):
                    with self.assertRaises(scanner.ScanFailure):
                        self.scan(mutated)
        for offset, inside, _, mutated in self.mutations(data, payloads):
            if inside:
                with self.subTest(offset=offset, inside=True):
                    self.scan(mutated)

    def test_thin_binary(self):
        binary = Thin()
        self.check_binary(binary.data, [binary.region], [binary.payload])

    def test_fat_binary(self):
        first, second = Thin(), Thin(code=b'\x01' * 96)
        data, places = fat(first.data, second.data)
        regions = [(base + first.region[0], base + first.region[1]) if index == 0
                   else (base + second.region[0], base + second.region[1])
                   for index, (base, _) in enumerate(places)]
        payloads = [(places[0][0] + first.payload[0], places[0][0] + first.payload[1]),
                    (places[1][0] + second.payload[0], places[1][0] + second.payload[1])]
        self.check_binary(data, regions, payloads)


if __name__ == '__main__':
    unittest.main()
