"""Ad hoc signature inspection, exercised against a fake codesign with prepared output."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ITEMS = ('', 'Contents/Frameworks/Sparkle.framework',
         'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
         'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app')
# The format of `codesign --display --verbose=2` on an ad hoc bundle; the last line is required,
# so every truncation at a line boundary removes a required line.
VALID = ['Executable=/fixture/MonoPods', 'Identifier=io.github.bernalli.monopods',
         'Format=app bundle with Mach-O thin (arm64)',
         'CodeDirectory v=20400 size=1234 flags=0x2(adhoc) hashes=30+7 location=embedded',
         'Hash type=sha256 size=32', 'Signature=adhoc', 'Info.plist entries=14',
         'Sealed Resources version=2 rules=13 files=9', 'TeamIdentifier=not set']
FAKE_CODESIGN = '''#!{python}
import json, os, sys
fixture = json.load(open(os.environ['FIXTURE']))
with open(os.environ['FIXTURE_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['--display', '--verbose=2'] and len(sys.argv) == 4:
    entry = fixture['items'][sys.argv[3]]
    sys.stderr.buffer.write(bytes.fromhex(entry['stderr']))
    sys.exit(entry['rc'])
if sys.argv[1:5] == ['--display', '--entitlements', '-', '--xml'] and len(sys.argv) == 6:
    sys.stdout.buffer.write(bytes.fromhex(fixture['entitlements']))
    sys.exit(0)
sys.exit(89)
'''


class AdHocCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / 'MonoPods.app'
        for relative in ITEMS[1:]:
            (self.app / relative).mkdir(parents=True)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        fake = self.tools / 'codesign'
        fake.write_text(FAKE_CODESIGN.format(python=sys.executable))
        fake.chmod(0o700)
        self.fixture = self.root / 'fixture.json'
        self.log = self.root / 'codesign.log'
        self.outputs = [list(VALID) for _ in ITEMS]
        self.codes = [0 for _ in ITEMS]
        self.entitlements = b''

    def path(self, index):
        return str(self.app / ITEMS[index]) if ITEMS[index] else str(self.app)

    def run_check(self, app=None, raw=None):
        items = {}
        for index in range(len(ITEMS)):
            data = raw[index] if raw and index in raw else '\n'.join(self.outputs[index]).encode()
            items[self.path(index)] = {'stderr': data.hex(), 'rc': self.codes[index]}
        self.fixture.write_text(json.dumps({'items': items, 'entitlements': self.entitlements.hex()}))
        environment = dict(os.environ, PATH=str(self.tools) + os.pathsep + '/usr/bin:/bin',
                           FIXTURE=str(self.fixture), FIXTURE_LOG=str(self.log),
                           PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, str(SCRIPTS / 'adhoc-check.py'), str(app or self.app)],
                              capture_output=True, text=True, timeout=20, env=environment)

    def assert_failed(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('passed', result.stdout + result.stderr)

    def test_valid_output_for_four_items_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'ad hoc signature check passed: 4 items\n')
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(calls[:4], [['--display', '--verbose=2', self.path(i)] for i in range(4)])
        self.assertEqual(calls[4], ['--display', '--entitlements', '-', '--xml', str(self.app)])

    def test_every_broken_line_of_every_item_fails(self):
        mutations = [
            lambda lines: [line for line in lines if not line.startswith('Signature=')],
            lambda lines: [line.replace('Signature=adhoc', 'Signature=Developer ID Application: X')
                           for line in lines],
            lambda lines: lines + ['Signature=adhoc'],
            lambda lines: [line.replace('not set', 'ABCDE12345') for line in lines],
            lambda lines: [line for line in lines if not line.startswith('TeamIdentifier=')],
            lambda lines: lines + ['TeamIdentifier=not set'],
            lambda lines: [line.replace('flags=0x2(adhoc)', 'flags=0x10002(adhoc,runtime)')
                           for line in lines],
            lambda lines: [line.replace('flags=0x2(adhoc)', 'flags=0x0(none)') for line in lines],
            lambda lines: [line for line in lines if not line.startswith('CodeDirectory ')],
            lambda lines: lines + [lines[3]],
        ]
        for index in range(len(ITEMS)):
            for number, mutate in enumerate(mutations):
                with self.subTest(item=index, mutation=number):
                    self.outputs = [list(VALID) for _ in ITEMS]
                    self.outputs[index] = mutate(list(VALID))
                    self.assert_failed(self.run_check())

    def test_codesign_failure_invalid_bytes_and_truncation_fail(self):
        for index in range(len(ITEMS)):
            with self.subTest(item=index, case='rc'):
                self.codes = [0 for _ in ITEMS]
                self.codes[index] = 1
                self.assert_failed(self.run_check())
            self.codes = [0 for _ in ITEMS]
            with self.subTest(item=index, case='utf8'):
                self.assert_failed(self.run_check(raw={index: '\n'.join(VALID).encode() + b'\xff'}))
            for end in range(len(VALID)):
                with self.subTest(item=index, end=end):
                    self.assert_failed(self.run_check(raw={index: '\n'.join(VALID[:end]).encode()}))

    def test_order_and_foreign_lines_do_not_matter(self):
        self.outputs = [list(reversed(VALID)) + ['Identifier=extra', 'Format=other', 'Hash type=x']
                        for _ in ITEMS]
        self.assertEqual(self.run_check().returncode, 0)

    def test_entitlements_must_be_empty(self):
        for data, code in ((plistlib.dumps({}), 0), (b'', 0),
                           (plistlib.dumps({'com.apple.security.get-task-allow': True}), 1),
                           (b'<?xml version="1.0"?><plist><dict><key>x', 1), (b'not a plist', 1),
                           (plistlib.dumps(['x']), 1)):
            with self.subTest(data=data[:40]):
                self.entitlements = data
                self.assertEqual(self.run_check().returncode, code)

    def test_unsafe_bundle_paths_fail_before_codesign(self):
        link = self.root / 'Linked.app'
        link.symlink_to(self.app)
        plain = self.root / 'Plain.app'
        plain.write_text('file')
        other = self.root / 'MonoPods'
        other.mkdir()
        for app in (link, plain, other, self.root / 'Missing.app'):
            with self.subTest(app=app.name):
                self.assert_failed(self.run_check(app=app))
                self.assertFalse(self.log.exists())
        for index in range(1, len(ITEMS)):
            item = self.app / ITEMS[index]
            target = self.root / f'target-{index}'
            item.rename(target)
            for linked in (False, True):
                with self.subTest(item=index, linked=linked):
                    if linked:
                        item.symlink_to(target)
                    self.assert_failed(self.run_check())
                    self.assertFalse(self.log.exists())
                    if linked:
                        item.unlink()
            target.rename(item)

    def test_errors_name_only_the_item_index(self):
        self.outputs[2] = ['Signature=adhoc secret-marker']
        result = self.run_check()
        self.assert_failed(result)
        self.assertNotIn('secret-marker', result.stdout + result.stderr)
        self.assertNotIn('Executable=', result.stdout + result.stderr)
        self.assertIn('2', result.stderr)


if __name__ == '__main__':
    unittest.main()
