"""About metadata is generated without compiling or launching the application."""
import base64
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bundle-info.py'


class BundleInfoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.template = self.root / 'Info.plist'
        self.license = self.root / 'LICENSE'
        self.output = self.root / 'Output.plist'
        self.info = {'CFBundleName': 'MonoPods', 'CFBundleVersion': '91',
                     'CFBundleShortVersionString': '4.5.6', 'CFBundleIconFile': 'AppIcon',
                     'LSUIElement': True}
        self.template.write_bytes(plistlib.dumps(self.info))
        self.license.write_text('Copyright (c) 2030 Example. All rights reserved.\n\nTerms.\n')

    def generate(self):
        return subprocess.run(['python3', str(SCRIPT), str(self.template),
                               str(self.license), str(self.output)],
                              capture_output=True, text=True, timeout=10)

    def test_preserves_version_build_icon_and_accessory_policy(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = plistlib.loads(self.output.read_bytes())
        for key, value in self.info.items():
            self.assertEqual(output[key], value)
        self.assertEqual(output['NSHumanReadableCopyright'],
                         'Copyright (c) 2030 Example. All rights reserved.')
        self.assertEqual(plistlib.loads(self.template.read_bytes()), self.info)

    def test_product_template_has_visible_name_and_stable_identity(self):
        info = plistlib.loads((SCRIPT.parent.parent / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleName'], 'MonoPods')
        self.assertEqual(info['CFBundleIdentifier'], 'io.github.bernalli.monopods')
        for key in ('NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription'):
            self.assertTrue(info[key].startswith('MonoPods '))

    def test_product_template_has_a_release_version_above_every_candidate(self):
        info = plistlib.loads((SCRIPT.parent.parent / 'Resources/Info.plist').read_bytes())
        self.assertRegex(info['CFBundleShortVersionString'], r'^[0-9]+\.[0-9]+\.[0-9]+$')
        build = info['CFBundleVersion']
        self.assertRegex(build, r'^[1-9][0-9]*$')
        self.assertGreaterEqual(int(build), 10)

    def test_uses_current_license_instead_of_stale_template_copyright(self):
        self.info['NSHumanReadableCopyright'] = 'Old copyright'
        self.template.write_bytes(plistlib.dumps(self.info))
        self.license.write_text('Copyright (c) 2031 New Owner.\n')
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(self.output.read_bytes())['NSHumanReadableCopyright'],
                         'Copyright (c) 2031 New Owner.')

    def test_missing_copyright_fails_without_output(self):
        self.license.write_text('Terms only.\n')
        self.assertNotEqual(self.generate().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_every_incomplete_xml_prefix_is_rejected_without_writing(self):
        import runpy
        from unittest.mock import patch
        main = runpy.run_path(str(SCRIPT))['main']
        data = self.template.read_bytes()
        required_end = data.index(b'</plist>') + len(b'</plist>')
        arguments = ['bundle-info.py', str(self.template), str(self.license), str(self.output)]
        for end in range(required_end):
            with self.subTest(end=end), patch('sys.argv', arguments):
                with patch.object(Path, 'read_bytes', return_value=data[:end]):
                    with patch.object(Path, 'write_bytes') as write:
                        with self.assertRaises(Exception):
                            main()
                        write.assert_not_called()

    def test_non_dictionary_roots_are_rejected_without_output(self):
        for value in ([], [1], 'text', 1, False):
            with self.subTest(value=value):
                self.template.write_bytes(plistlib.dumps(value))
                self.assertNotEqual(self.generate().returncode, 0)
                self.assertFalse(self.output.exists())

    def test_missing_extra_and_reordered_metadata_is_preserved(self):
        sources = ({}, dict(reversed(list(self.info.items()))),
                   dict(self.info, ExtraMetadata=['kept', 7]))
        for source in sources:
            with self.subTest(source=source):
                self.template.write_bytes(plistlib.dumps(source, sort_keys=False))
                result = self.generate()
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = dict(source, NSHumanReadableCopyright=
                                'Copyright (c) 2030 Example. All rights reserved.')
                output = plistlib.loads(self.output.read_bytes())
                self.assertEqual(output, expected)
                self.assertEqual(list(output), list(expected))


MIT_TERMS = '''Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'''


class RepositoryLicenseTests(unittest.TestCase):
    def setUp(self):
        self.path = SCRIPT.parent.parent / 'LICENSE'
        self.lines = self.path.read_text().splitlines(keepends=True)

    def test_license_is_the_standard_mit_text(self):
        self.assertEqual(self.lines[0], 'MIT License\n')
        self.assertEqual(self.lines[1], '\n')
        self.assertRegex(self.lines[2], r'^Copyright \(c\) 2026 [^\n]+[^.\n]\n$')
        self.assertEqual(self.lines[3], '\n')
        self.assertEqual(''.join(self.lines[4:]), MIT_TERMS)

    def test_license_reserves_no_rights(self):
        self.assertNotIn('All rights reserved', self.path.read_text())

    def test_bundle_copyright_is_the_license_copyright_line(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'Output.plist'
            result = subprocess.run(['python3', str(SCRIPT),
                                     str(SCRIPT.parent.parent / 'Resources/Info.plist'),
                                     str(self.path), str(output)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads(output.read_bytes())
        self.assertEqual(info['NSHumanReadableCopyright'], self.lines[2].rstrip('\n'))


KEY = base64.b64encode(bytes(range(32))).decode()
FEED = 'https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml'
SPARKLE_KEYS = {'SUAutomaticallyUpdate': False, 'SUEnableSystemProfiling': False,
                'SUVerifyUpdateBeforeExtraction': True, 'SUShowReleaseNotes': False}


class UpdateChannelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.template = self.root / 'Info.plist'
        self.license = self.root / 'LICENSE'
        self.output = self.root / 'Output.plist'
        self.channel = self.root / 'UpdateChannel.json'
        self.info = dict({'CFBundleIdentifier': 'io.github.bernalli.monopods',
                          'CFBundleVersion': '4', 'CFBundleShortVersionString': '0.2.0'},
                         **SPARKLE_KEYS)
        self.template.write_bytes(plistlib.dumps(self.info))
        self.license.write_text('Copyright (c) 2030 Example.\n')
        self.write_channel({'v': 1, 'feedURL': FEED, 'publicEDKey': KEY})

    def write_channel(self, value):
        text = value if isinstance(value, str) else json.dumps(value)
        self.channel.write_text(text)

    def generate(self, *extra):
        return subprocess.run(['python3', str(SCRIPT), str(self.template), str(self.license),
                               str(self.output), *extra],
                              capture_output=True, text=True, timeout=10)

    def assert_refused(self, *extra):
        result = self.generate(*extra)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.output.exists())

    def test_product_template_has_exactly_the_sparkle_settings(self):
        info = plistlib.loads((SCRIPT.parent.parent / 'Resources/Info.plist').read_bytes())
        keys = {key: value for key, value in info.items() if key.startswith('SU')}
        self.assertEqual(keys, SPARKLE_KEYS)
        for key, value in keys.items():
            self.assertIs(type(value), bool, key)

    def test_without_a_channel_the_bundle_has_no_feed_and_no_key(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = plistlib.loads(self.output.read_bytes())
        self.assertNotIn('SUFeedURL', output)
        self.assertNotIn('SUPublicEDKey', output)

    def test_a_valid_channel_adds_the_production_feed_and_the_key(self):
        result = self.generate('--update-channel', str(self.channel))
        self.assertEqual(result.returncode, 0, result.stderr)
        output = plistlib.loads(self.output.read_bytes())
        self.assertEqual(output['SUFeedURL'], FEED)
        self.assertEqual(output['SUPublicEDKey'], KEY)
        self.assertEqual(output['CFBundleVersion'], '4')

    def test_malformed_channels_are_refused_without_output(self):
        valid = {'v': 1, 'feedURL': FEED, 'publicEDKey': KEY}
        cases = [
            '{"v": 1, "v": 1, "feedURL": "%s", "publicEDKey": "%s"}' % (FEED, KEY),
            dict(valid, extra=1),
            {'v': 1, 'feedURL': FEED},
            {'v': 1, 'publicEDKey': KEY},
            {'feedURL': FEED, 'publicEDKey': KEY},
            dict(valid, v=2), dict(valid, v=True), dict(valid, v='1'), dict(valid, v=1.0),
            dict(valid, feedURL=FEED.replace('https:', 'http:')),
            dict(valid, feedURL=FEED.replace('github.com', 'example.com')),
            dict(valid, feedURL=FEED.replace('/bernalli/', '/other/')),
            dict(valid, feedURL=FEED.replace('monoPods', 'monopods')),
            dict(valid, feedURL=FEED + '?q=1'), dict(valid, feedURL=FEED + '#part'),
            dict(valid, feedURL=FEED + '/'),
            dict(valid, feedURL='file:///tmp/appcast.xml'), dict(valid, feedURL=7),
            dict(valid, publicEDKey=base64.b64encode(bytes(31)).decode()),
            dict(valid, publicEDKey=base64.b64encode(bytes(33)).decode()),
            dict(valid, publicEDKey=base64.urlsafe_b64encode(bytes([251] * 32)).decode()),
            dict(valid, publicEDKey=' ' + KEY), dict(valid, publicEDKey=KEY[:20] + ' ' + KEY[20:]),
            dict(valid, publicEDKey=''), dict(valid, publicEDKey=None),
            [valid], 'not json', '',
        ]
        for case in cases:
            with self.subTest(case=case):
                self.write_channel(case)
                self.assert_refused('--update-channel', str(self.channel))

    def test_every_truncation_of_a_valid_channel_is_refused(self):
        text = json.dumps({'v': 1, 'feedURL': FEED, 'publicEDKey': KEY})
        for end in range(len(text)):
            with self.subTest(end=end):
                self.write_channel(text[:end])
                self.assert_refused('--update-channel', str(self.channel))

    def test_a_linked_missing_or_oversized_channel_is_refused(self):
        link = self.root / 'Linked.json'
        link.symlink_to(self.channel)
        self.assert_refused('--update-channel', str(link))
        self.assert_refused('--update-channel', str(self.root / 'Missing.json'))
        self.write_channel(json.dumps({'v': 1, 'feedURL': FEED, 'publicEDKey': KEY})
                           + ' ' * 65536)
        self.assert_refused('--update-channel', str(self.channel))

    def test_candidate_version_needs_a_channel_and_a_greater_integer(self):
        self.assert_refused('--candidate-version', '5')
        for value in ('0', '01', '-3', '3.0', '1000000000', '4', '3', '', 'five'):
            with self.subTest(value=value):
                self.assert_refused('--update-channel', str(self.channel),
                                    '--candidate-version', value)

    def test_candidate_version_replaces_only_the_bundle_version(self):
        result = self.generate('--update-channel', str(self.channel), '--candidate-version', '5')
        self.assertEqual(result.returncode, 0, result.stderr)
        output = plistlib.loads(self.output.read_bytes())
        expected = dict(self.info, CFBundleVersion='5', SUFeedURL=FEED, SUPublicEDKey=KEY,
                        NSHumanReadableCopyright='Copyright (c) 2030 Example.')
        self.assertEqual(output, expected)

    def test_unknown_or_repeated_arguments_are_refused(self):
        for extra in (('--update-channel',), ('--other', 'x'),
                      ('--update-channel', str(self.channel), '--update-channel', str(self.channel)),
                      ('--candidate-version', '5', '--update-channel', str(self.channel),
                       '--candidate-version', '6')):
            with self.subTest(extra=extra):
                self.assert_refused(*extra)

    def test_template_with_a_feed_or_a_key_is_refused(self):
        for key, value in (('SUFeedURL', FEED), ('SUPublicEDKey', KEY)):
            with self.subTest(key=key):
                self.template.write_bytes(plistlib.dumps(dict(self.info, **{key: value})))
                self.assert_refused()
                self.assert_refused('--update-channel', str(self.channel))
