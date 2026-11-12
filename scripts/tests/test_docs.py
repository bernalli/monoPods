"""README and technical notes: the statements a public release depends on."""
from pathlib import Path
import re
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / 'README.md'
TECHNICAL = ROOT / 'docs/TECHNICAL.md'
COMMENT = re.compile(r'<!--.*?-->', re.S)
NUMBERED = re.compile(r'^\s*[0-9]+[.)]\s')
LINK = re.compile(r'\]\(([^)\s]+)\)')
BLUETOOTH_ASKED = ('- macOS may ask again for Bluetooth access after an update, because each '
                   'version has a new ad hoc signature. If it asks, allow it to keep automatic '
                   'switching working.')
BLUETOOTH_KEPT = '- Updates keep the Bluetooth access you already granted.'
NETWORK_LINE = ('- Apart from update checks, MonoPods makes no network requests. '
                'It reads the local system log.')
README_TITLES = ['Install', 'Updates', 'Requirements', 'Good to know', 'License']
README_UPDATES = [
    'Choose Check for Updates… to check for a new version. MonoPods never checks automatically '
    'and downloads an update only when you choose to install it.',
    '- Before downloading, MonoPods must return the sound to stereo or confirm that there is '
    'nothing to restore. From that confirmation until the new version runs, automatic switching '
    'is paused.',
    '- If MonoPods cannot confirm this in time, it does not install the update and keeps '
    'working. Quit and reopen MonoPods before you check again.',
    '- After a crash, MonoPods finishes its crash recovery before it allows updates. During '
    'installation, other launches of MonoPods stay inactive until the new version is complete '
    'and verified.',
]
AUTOMATIC_MODE_PHRASES = ('Automatic Updates', 'retries at the next launch', 'Enable Automatic Updates', 'Not Now',
                          'asks once', 'about once a day', 'by itself, ',
                          'downloads and installs new versions by itself', 'this takes seconds')
RELEASE_CHECK = ('MonoPods checks for updates only when the user asks. '
                 'To verify a release, install the previous release, choose Check for Updates… '
                 'in its menu and install the offered update.')
TECHNICAL_UPDATES = [
    'Installation is allowed only after MonoPods confirms stereo or confirms that there is '
    'nothing to restore.',
    'Automation is suspended during this handoff, which starts before the download.',
    'If confirmation misses the restore deadline, no update installs until the next launch.',
    'A zero exit status alone does not authorize installation.',
    'Mono switching is suspended only from the restore confirmation until the new version is '
    'active, including the download.',
    'If the update cannot start in time, the app keeps working, and the user can check again '
    'after the next launch.',
    'Sparkle checks for updates only when the user chooses Check for Updates… in the menu.',
    'At every launch, the app turns off Sparkle\'s automatic checks and automatic downloads.',
    'If either is turned on later, the app turns both off again.',
    'The app refuses every scheduled check.',
    'After a crash, the next owner performs journal recovery before resuming operation or '
    'updates.',
    'During replacement, an old version restarted by the launch agent remains inactive.',
    'The new version validates its complete bundle and acquires the runtime lock before recovery '
    'and activation; concurrent launches cannot operate the audio engine.',
    'A failed or unconfirmed replacement blocks operation until its outcome is established.',
    'Sparkle starts only in the instance that owns the runtime lock, and only in builds with an '
    'update channel.',
    'Release builds, including Sparkle\'s helper tools, are signed ad hoc and are not notarized.',
    'Sparkle installs an update only when its disk image carries a valid EdDSA signature from the '
    'key embedded in the installed app and the new version\'s ad hoc code signature is valid.',
]
UNTESTED_ON_INSTALLED_APP = (
    'Deferral of an update when stereo restoration misses its deadline is covered only by '
    'automated tests; it has not been measured on an installed app.')
UNMEASURED_UPDATE = ('An update from one installed release to the next, including how long '
                     'automatic switching stays suspended, has not been measured.')
RELEASING = ROOT / 'docs/RELEASING.md'


def visible_lines(path):
    """The lines of a Markdown file without HTML comments and without trailing spaces."""
    return [line.rstrip() for line in COMMENT.sub('', path.read_text()).splitlines()]


def prose(path):
    """The visible text of a Markdown file with every run of whitespace made one space."""
    return ' '.join(COMMENT.sub('', path.read_text()).split())


def joined(lines):
    """Lines joined into one text with every run of whitespace made one space."""
    return ' '.join(' '.join(lines).split())


def titles(lines):
    """The level-two titles, in order."""
    return [line[3:] for line in lines if line.startswith('## ')]


def section(lines, title):
    """The lines under one level-two title, up to the next one."""
    start = lines.index('## ' + title) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith('## ')), len(lines))
    return lines[start:end]


def copyright_holder():
    """The holder named on the copyright line of LICENSE."""
    line = (ROOT / 'LICENSE').read_text().splitlines()[2]
    prefix = 'Copyright (c) 2026 '
    if not line.startswith(prefix):
        raise ValueError('unexpected copyright line')
    return line[len(prefix):]


def sparkle_versions():
    """The exact Sparkle versions pinned in Package.swift."""
    return re.findall(r'Sparkle", exact: "([^"]+)"', (ROOT / 'Package.swift').read_text())


class ReadmeTests(unittest.TestCase):
    def setUp(self):
        self.lines = visible_lines(README)
        self.text = '\n'.join(self.lines)

    def test_titles_are_exactly_the_public_sections_in_order(self):
        self.assertEqual(titles(self.lines), README_TITLES)

    def test_install_has_exactly_five_numbered_steps_in_order(self):
        steps = [line for line in section(self.lines, 'Install') if NUMBERED.match(line)]
        self.assertEqual(len(steps), 5)
        for number, step in enumerate(steps, start=1):
            self.assertTrue(step.startswith(f'{number}. '), step)

    def test_install_explains_the_first_launch_of_an_app_without_notarization(self):
        install = joined(section(self.lines, 'Install'))
        for phrase in ('Privacy & Security', 'Open Anyway', 'is not notarized by Apple',
                       'signed ad hoc, not with a Developer ID'):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, install)

    def test_no_signed_or_notarized_experience_is_promised(self):
        for phrase in ('signed with a Developer ID', 'and notarized by Apple'):
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, prose(README))

    def test_updates_carry_exactly_one_bluetooth_variant(self):
        found = [line for line in section(self.lines, 'Updates')
                 if line in (BLUETOOTH_ASKED, BLUETOOTH_KEPT)]
        self.assertEqual(len(found), 1, found)
        self.assertEqual(self.lines.count(BLUETOOTH_ASKED) + self.lines.count(BLUETOOTH_KEPT), 1)

    def test_updates_state_manual_checks_stereo_deferral_and_recovery(self):
        updates = section(self.lines, 'Updates')
        for line in README_UPDATES:
            with self.subTest(line=line):
                self.assertIn(line, updates)

    def test_updates_name_the_command_the_app_shows(self):
        source = (ROOT / 'Sources/MonoPodsRuntime/UpdatePolicy.swift').read_text()
        found = re.findall(r'static let check = "([^"]+)"', source)
        self.assertEqual(len(found), 1)
        command = found[0].replace('\\u{2026}', '…')
        self.assertIn(command, joined(section(self.lines, 'Updates')))

    def test_feed_url_is_the_production_feed(self):
        feed = runpy.run_path(str(ROOT / 'scripts/bundle-info.py'))['PRODUCTION_FEED_URL']
        self.assertIn(feed, self.text)

    def test_network_statement_admits_update_checks(self):
        self.assertIn(NETWORK_LINE, self.lines)
        self.assertIsNone(re.search(r'(^|[.!?]\s+)It makes no network requests\.',
                                    prose(README)))

    def test_requirements_name_apple_silicon(self):
        requirements = [line for line in section(self.lines, 'Requirements') if line]
        self.assertEqual(requirements[0], '- A Mac with Apple silicon and macOS 14.2 or later.')

    def test_runtime_override_file_is_not_mentioned(self):
        self.assertIsNone(re.search(r'\bRuntimeConfig\b', self.text))

    def test_license_section_names_mit_and_the_sparkle_notice(self):
        license_lines = section(self.lines, 'License')
        self.assertIn('MonoPods is released under the [MIT License](LICENSE). '
                      f'Copyright © 2026 {copyright_holder()}.', license_lines)
        self.assertIn('The app includes Sparkle, which has its own license; its notice is in '
                      '`MonoPods.app/Contents/Resources/Sparkle-LICENSE.txt`.', license_lines)
        before = [line for line in self.lines[:self.lines.index('## License')] if line]
        self.assertEqual(before[-1],
                         'See [technical notes and building from source](docs/TECHNICAL.md).')

    def test_login_start_is_explained_once_in_install(self):
        self.assertEqual(self.text.count('Launch at Login'), 1)
        self.assertIn('Launch at Login', joined(section(self.lines, 'Install')))


class TechnicalNotesTests(unittest.TestCase):
    def setUp(self):
        self.lines = visible_lines(TECHNICAL)
        self.text = prose(TECHNICAL)

    def test_old_statements_about_network_and_dependencies_are_gone(self):
        for phrase in ('There are no external package dependencies',
                       'The app makes no network requests.'):
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, self.text)

    def test_names_the_pinned_sparkle_version(self):
        versions = sparkle_versions()
        self.assertEqual(len(versions), 1)
        self.assertIn(f'The only package dependency is Sparkle {versions[0]}, pinned in '
                      '`Package.resolved`.', self.text)

    def test_update_section_comes_before_building_from_source(self):
        found = titles(self.lines)
        self.assertIn('Updates and helper processes', found)
        self.assertLess(found.index('Updates and helper processes'),
                        found.index('Build from source'))

    def test_update_section_states_deadline_handoff_recovery_and_validation(self):
        updates = joined(section(self.lines, 'Updates and helper processes'))
        for sentence in TECHNICAL_UPDATES:
            with self.subTest(sentence=sentence):
                self.assertIn(sentence, updates)

    def test_case_without_installed_app_measurement_is_declared(self):
        self.assertIn(UNTESTED_ON_INSTALLED_APP, self.text)

    def test_unmeasured_update_between_installed_releases_is_declared(self):
        self.assertIn(UNMEASURED_UPDATE, self.text)

    def test_source_builds_have_no_channel_and_run_on_apple_silicon(self):
        for sentence in ('Builds from source have no update channel, so they never check for '
                         'updates.',
                         'Release builds are described in [RELEASING.md](RELEASING.md).',
                         'MonoPods runs on Apple silicon only.',
                         'Apart from Sparkle update checks, described in the README, the app '
                         'makes no network requests.'):
            with self.subTest(sentence=sentence):
                self.assertIn(sentence, self.text)


class ConsistencyTests(unittest.TestCase):
    def test_a_deferred_update_waits_for_the_next_launch_not_the_next_check(self):
        for path in (README, TECHNICAL):
            with self.subTest(path=path.name):
                self.assertNotIn('next check', prose(path))

    def test_relative_links_point_to_files_of_the_repository(self):
        for path in (README, TECHNICAL):
            for target in LINK.findall(COMMENT.sub('', path.read_text())):
                if re.match(r'^[a-z]+:', target):
                    continue
                with self.subTest(path=path.name, target=target):
                    self.assertTrue((path.parent / target.split('#')[0]).exists())

    def test_no_pending_marker_remains(self):
        for path in (README, TECHNICAL, RELEASING):
            with self.subTest(path=path.name):
                self.assertNotIn('pending', path.read_text())

    def test_no_automatic_update_mode_is_described(self):
        for path in (README, TECHNICAL, RELEASING):
            for phrase in AUTOMATIC_MODE_PHRASES:
                with self.subTest(path=path.name, phrase=phrase):
                    self.assertNotIn(phrase, prose(path))


    def test_readme_mentions_no_automatic_download(self):
        self.assertNotIn('automatic download', prose(README).lower())


class ReleasingGuideTests(unittest.TestCase):
    def test_release_check_is_the_manual_check_from_an_installed_version(self):
        self.assertIn(RELEASE_CHECK, prose(RELEASING))

    def test_guided_update_probe_is_gone(self):
        text = prose(RELEASING)
        for phrase in ('Guided local update check', 'update probe', 'E1', 'E3'):
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, text)


if __name__ == '__main__':
    unittest.main()
