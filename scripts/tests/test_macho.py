"""Mach-O load command parsing, exercised only against synthetic binaries."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('macho', SCRIPTS / 'macho.py')
assert SPEC is not None and SPEC.loader is not None
macho = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(macho)

ARM64 = 0x0100000c
X86_64 = 0x01000007
LC_RPATH = 0x8000001c
LC_LOAD_DYLIB = 0xc
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001f
LC_UUID = 0x1b


def padded(text):
    data = text.encode() + b'\0'
    return data + bytes(-len(data) % 8)


def rpath_command(path):
    payload = padded(path)
    return struct.pack('<III', LC_RPATH, 16 + len(payload), 16) + bytes(4) + payload


def dylib_command(path, kind=LC_LOAD_DYLIB):
    payload = padded(path)
    return struct.pack('<IIIIII', kind, 24 + len(payload), 24, 2, 0x10000, 0x10000) + payload


def uuid_command():
    return struct.pack('<II', LC_UUID, 24) + bytes(16)


def binary(commands, cputype=ARM64, ncmds=None, magic=b'\xcf\xfa\xed\xfe', sizeofcmds=None):
    body = b''.join(commands)
    header = magic + struct.pack(
        '<iiIIIII', cputype, 0, 2, len(commands) if ncmds is None else ncmds,
        len(body) if sizeofcmds is None else sizeofcmds, 0, 0)
    return header + body + b'code'


SPARKLE_RPATH = '@executable_path/../Frameworks'
SPARKLE_LIBRARY = '@rpath/Sparkle.framework/Versions/B/Sparkle'
COMMANDS = [
    uuid_command(),
    rpath_command('/usr/lib/swift'),
    dylib_command('/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'),
    rpath_command('@loader_path'),
    dylib_command('/usr/lib/libSystem.B.dylib', LC_LOAD_WEAK_DYLIB),
    dylib_command('/usr/lib/swift/libswiftCore.dylib', LC_REEXPORT_DYLIB),
]
SPARKLE_COMMANDS = [rpath_command(SPARKLE_RPATH), dylib_command(SPARKLE_LIBRARY)]
VALID = binary(COMMANDS)
VALID_APP = binary(COMMANDS + SPARKLE_COMMANDS)


class MachOTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def app(self, data):
        app = self.root / 'MonoPods.app'
        executable = app / 'Contents/MacOS/MonoPods'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(data)
        return app

    def command(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / 'macho.py'), *map(str, args)],
                              capture_output=True, text=True, timeout=20,
                              env={'PATH': '/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'})

    def assert_invalid(self, data):
        with self.assertRaises(ValueError):
            macho.parse(data)

    def test_valid_binary_lists_rpaths_and_libraries_in_order(self):
        parsed = macho.parse(VALID)
        self.assertEqual(parsed.cputype, ARM64)
        self.assertEqual(parsed.rpaths, ['/usr/lib/swift', '@loader_path'])
        self.assertEqual(parsed.libraries, [
            '/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit',
            '/usr/lib/libSystem.B.dylib', '/usr/lib/swift/libswiftCore.dylib'])

    def test_rpaths_command_prints_one_per_line(self):
        path = self.root / 'binary'
        path.write_bytes(VALID)
        result = self.command('rpaths', path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '/usr/lib/swift\n@loader_path\n')

    def test_duplicate_rpaths_are_both_read(self):
        data = binary([rpath_command('/a/b'), rpath_command('/a/b')])
        self.assertEqual(macho.parse(data).rpaths, ['/a/b', '/a/b'])

    def test_truncation_at_every_offset_raises_only_value_error(self):
        end = 32 + struct.unpack_from('<I', VALID, 20)[0]
        for length in range(end):
            with self.subTest(length=length):
                self.assert_invalid(VALID[:length])

    def test_malformed_command_sizes_are_rejected(self):
        command = rpath_command('/usr/lib/swift')
        for size in (0, 4, len(command) - 4, len(command) + 4, len(command) + 8, 4096):
            with self.subTest(size=size):
                changed = struct.pack('<II', LC_RPATH, size) + command[8:]
                self.assert_invalid(binary([changed]))
        self.assert_invalid(binary([command], sizeofcmds=len(command) + 4096))
        self.assert_invalid(binary([command], sizeofcmds=len(command) - 8))

    def test_more_commands_than_present_are_rejected(self):
        self.assert_invalid(binary([rpath_command('/usr/lib/swift')], ncmds=2))

    def test_string_offsets_outside_the_command_are_rejected(self):
        command = bytearray(rpath_command('/usr/lib/swift'))
        for offset in (0, 8, 11, len(command), len(command) + 8):
            with self.subTest(offset=offset):
                struct.pack_into('<I', command, 8, offset)
                self.assert_invalid(binary([bytes(command)]))

    def test_strings_without_terminator_or_utf8_are_rejected(self):
        unterminated = struct.pack('<III', LC_RPATH, 24, 12) + b'abcdefghijkl'
        self.assert_invalid(binary([unterminated]))
        not_utf8 = struct.pack('<III', LC_RPATH, 24, 12) + b'\xff\xfe\0' + bytes(9)
        self.assert_invalid(binary([not_utf8]))

    def test_big_endian_and_fat_magics_are_rejected(self):
        for magic in (b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            with self.subTest(magic=magic):
                data = binary([rpath_command('/usr/lib/swift')], magic=magic)
                self.assert_invalid(data)
                result = self.command('check-app', self.app(data))
                self.assertEqual(result.returncode, 1)

    def test_check_app_accepts_the_closed_lists(self):
        result = self.command('check-app', self.app(VALID_APP))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_app_requires_the_framework_run_path_and_library(self):
        for commands in (COMMANDS, COMMANDS + SPARKLE_COMMANDS[:1], COMMANDS + SPARKLE_COMMANDS[1:]):
            with self.subTest(count=len(commands)):
                self.assertEqual(self.command('check-app', self.app(binary(commands))).returncode, 1)

    def test_check_app_accepts_only_the_exact_sparkle_library(self):
        for library in ('@rpath/Sparkle.framework/Versions/A/Sparkle',
                        '@rpath/Sparkle.framework/Sparkle', '@rpath/Other.framework/Versions/B/Other',
                        '@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle'):
            with self.subTest(library=library):
                data = binary(COMMANDS + SPARKLE_COMMANDS + [dylib_command(library)])
                self.assertEqual(self.command('check-app', self.app(data)).returncode, 1)

    def test_check_app_rejects_other_architectures(self):
        result = self.command('check-app', self.app(binary([rpath_command('/usr/lib/swift')],
                                                           cputype=X86_64)))
        self.assertEqual(result.returncode, 1)

    def test_check_app_rejects_rpaths_and_libraries_outside_the_lists(self):
        for command in (rpath_command('/Applications/Xcode.app/Contents/Developer/usr/lib'),
                        rpath_command('@executable_path/../Library'),
                        dylib_command('@rpath/Example.framework/Example'),
                        dylib_command('/opt/local/lib/libexample.dylib', LC_LOAD_WEAK_DYLIB),
                        dylib_command('/System/Library/PrivateFrameworks/X.framework/X',
                                      LC_REEXPORT_DYLIB)):
            with self.subTest(command=command[12:40]):
                result = self.command('check-app',
                                      self.app(binary(COMMANDS + SPARKLE_COMMANDS + [command])))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')

    def test_check_app_rejects_a_linked_executable(self):
        app = self.app(VALID)
        executable = app / 'Contents/MacOS/MonoPods'
        target = self.root / 'elsewhere'
        executable.rename(target)
        executable.symlink_to(target)
        self.assertEqual(self.command('check-app', app).returncode, 1)

    def test_errors_print_a_generic_message(self):
        path = self.root / 'binary'
        path.write_bytes(b'secret contents')
        result = self.command('rpaths', path)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('secret', result.stderr + result.stdout)
        self.assertEqual(self.command('unknown', path).returncode, 1)


    def test_dylib_fixed_header_cannot_be_used_as_its_name(self):
        for kind in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            for offset in range(12, 24):
                command = bytearray(dylib_command('/usr/lib/X', kind))
                struct.pack_into('<I', command, 8, offset)
                with self.subTest(kind=kind, offset=offset):
                    self.assert_invalid(binary([bytes(command)]))
            for size in (8, 16, 24):
                command = bytearray(dylib_command('/usr/lib/X', kind)[:size])
                struct.pack_into('<I', command, 4, size)
                with self.subTest(kind=kind, size=size):
                    self.assert_invalid(binary([bytes(command)]))

    def test_library_paths_must_have_canonical_components(self):
        for path in (
            '/usr/lib/../../opt/libX.dylib',
            '/usr/lib/./X',
            '/usr/lib//X',
            '/System/Library/Frameworks/../../../opt/X',
        ):
            with self.subTest(path=path):
                self.assertEqual(self.command(
                    'check-app', self.app(binary([dylib_command(path)]))
                ).returncode, 1)


if __name__ == '__main__':
    unittest.main()
