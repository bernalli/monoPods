"""Source-level links that the compiler cannot check: dependency pins and update wiring."""

import json
from pathlib import Path
import re
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPARKLE_VERSION = '2.10.1'
SPARKLE_REVISION = 'ab7d71291238df6e0492143b120c9b696a35f603'
SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle'


def swift_sources():
    """Every Swift source file of the package targets, with its path relative to the root."""
    return sorted((ROOT / 'Sources').rglob('*.swift'))


class DependencyPinTests(unittest.TestCase):
    def test_package_pins_the_exact_sparkle_version(self):
        text = (ROOT / 'Package.swift').read_text()
        pins = re.findall(r'\.package\(url: "([^"]+)", exact: "([^"]+)"\)', text)
        self.assertEqual(pins, [(SPARKLE_URL, SPARKLE_VERSION)])
        self.assertEqual(text.count('.package('), 1)

    def test_only_the_app_target_links_sparkle(self):
        text = (ROOT / 'Package.swift').read_text()
        self.assertEqual(text.count('.product(name: "Sparkle", package: "Sparkle")'), 1)
        target = text[text.index('name: "MonoPods",') :]
        target = target[: target.index(')),') if ')),' in target else len(target)]
        self.assertIn('.product(name: "Sparkle", package: "Sparkle")', target)
        self.assertIn('"@executable_path/../Frameworks"', target)

    def test_release_tools_use_the_same_version(self):
        text = (ROOT / 'scripts/sparkle-tools.sh').read_text()
        self.assertEqual(
            re.findall(r'^SPARKLE_VERSION=(\S+)$', text, re.M), [SPARKLE_VERSION]
        )

    def test_resolved_file_pins_the_same_version_and_revision(self):
        document = json.loads((ROOT / 'Package.resolved').read_text())
        pins = document['pins']
        self.assertEqual(len(pins), 1)
        pin = pins[0]
        self.assertEqual(pin['identity'], 'sparkle')
        self.assertEqual(pin['location'], SPARKLE_URL)
        self.assertEqual(
            pin['state'], {'revision': SPARKLE_REVISION, 'version': SPARKLE_VERSION}
        )


class UpdateWiringTests(unittest.TestCase):
    def test_sparkle_is_imported_only_by_the_app_target(self):
        for path in swift_sources():
            with self.subTest(path=path.relative_to(ROOT)):
                if re.search(
                    r"^\s*(@preconcurrency\s+)?import Sparkle\b", path.read_text(), re.M
                ):
                    self.assertEqual(
                        path.relative_to(ROOT).parts[:2], ('Sources', 'MonoPods')
                    )

    def test_feed_overrides_are_absent(self):
        for path in swift_sources():
            text = path.read_text()
            for name in ('setFeedURL', 'feedURLString', 'feedURLStringForUpdater'):
                with self.subTest(path=path.relative_to(ROOT), name=name):
                    self.assertNotIn(name, text)

    def test_background_check_is_requested_only_by_the_installation_gate(self):
        for path in swift_sources():
            text = path.read_text()
            with self.subTest(path=path.relative_to(ROOT)):
                if path.name == 'UpdateController.swift':
                    self.assertEqual(text.count('checkForUpdatesInBackground()'), 1)
                    body = text[text.index('func resumeAfterPreparation(') :]
                    self.assertIn(
                        'checkForUpdatesInBackground()', body[: body.index('\n  }\n')]
                    )
                else:
                    self.assertNotIn('checkForUpdatesInBackground', text)

    def test_raw_preferences_and_sparkle_setters_are_switched_off_before_sync(self):
        names = ('automaticallyDownloadsUpdates =', 'automaticallyChecksForUpdates =')
        for path in swift_sources():
            text = path.read_text()
            for name in names:
                with self.subTest(path=path.relative_to(ROOT), name=name):
                    if path.name != 'UpdateController.swift':
                        self.assertNotIn(name, text)
                        continue
                    self.assertEqual(text.count(name), 1)
                    self.assertEqual(text.count(name + ' false'), 1)
            if path.name == 'UpdateController.swift':
                body = text[text.index('func switchOffAutomatic(') :]
                body = body[: body.index('\n  }\n')]
                for key in ('downloadsKey', 'checksKey'):
                    self.assertIn(f'CFPreferencesSetAppValue({key}, kCFBooleanFalse, domain)', body)
                positions = [
                    body.index('CFPreferencesSetAppValue(downloadsKey, kCFBooleanFalse, domain)'),
                    body.index('CFPreferencesSetAppValue(checksKey, kCFBooleanFalse, domain)'),
                    *(body.index(name + ' false') for name in names),
                ]
                self.assertEqual(positions, sorted(positions))
                sync = text[text.index('func synchronizeAutomaticPreferences(') :]
                self.assertIn('return CFPreferencesAppSynchronize(domain)', sync)
                self.assertIn('CFPreferencesCopyValue(', text)
                self.assertIn('kCFPreferencesCurrentUser, kCFPreferencesAnyHost', text)
                self.assertIn('SparklePort(updater: updater, preferencesDomain: bundle.bundleIdentifier)', text)


class UpdateContractTests(unittest.TestCase):
    def test_update_events_have_closed_payloads_and_positive_uint64_ids(self):
        definitions = json.loads((ROOT / 'schemas/contract.schema.json').read_text())['$defs']
        for kind, names in [('input', ['prepareUpdate', 'endUpdateHold']),
                            ('action', ['updatePrepared'])]:
            for name in names:
                with self.subTest(name=name):
                    variants = [item for item in definitions[kind]['oneOf']
                                if name in item.get('properties', {})]
                    self.assertEqual(len(variants), 1)
                    variant = variants[0]
                    self.assertEqual(variant['required'], [name])
                    self.assertIs(variant['additionalProperties'], False)
                    payload = variant['properties'][name]
                    fields = {'id', 'result'} if name == 'updatePrepared' else {'id'}
                    self.assertEqual(set(payload['properties']), fields)
                    self.assertEqual(set(payload['required']), fields)
                    self.assertIs(payload['additionalProperties'], False)
                    identifier = payload['properties']['id']
                    self.assertEqual(identifier, {'type': 'integer', 'minimum': 1,
                                                  'maximum': 18446744073709551615})
                    if name == 'updatePrepared':
                        self.assertEqual(payload['properties']['result'], {
                            'type': 'string',
                            'enum': ['stereoConfirmed', 'nothingToRestore', 'unconfirmed']})


class UpdateChannelTests(unittest.TestCase):
    def test_production_channel_file_is_valid_and_names_the_production_feed(self):
        rules = runpy.run_path(str(ROOT / 'scripts/bundle-info.py'))
        feed, _ = rules['read_channel'](ROOT / 'Resources/UpdateChannel.json')
        self.assertEqual(feed, rules['PRODUCTION_FEED_URL'])


if __name__ == '__main__':
    unittest.main()
