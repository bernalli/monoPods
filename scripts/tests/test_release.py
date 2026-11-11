"""Release identity properties, exercised only against temporary artifacts."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import struct
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
COMMIT = '0123456789abcdef0123456789abcdef01234567'
FILES = (
    'Contents/MacOS/MonoPods', 'Contents/Info.plist', 'Contents/Resources/AppIcon.icns',
    'Contents/Resources/MenuBarIcon.png', 'Contents/Resources/MenuBarIcon@2x.png',
    'Contents/Resources/GitHubMark.pdf', 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
    'Contents/Resources/Sparkle-LICENSE.txt',
)
SOURCE_ARTIFACTS = ('Assets/AppIcon.icns', 'Assets/MenuBarIcon.png', 'Assets/MenuBarIcon@2x.png',
                    'Assets/GitHubMark.pdf', 'Resources/Info.plist', 'LICENSE',
                    'ThirdParty/Sparkle-LICENSE.txt')
SPARKLE_LICENSE_SHA256 = '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe'
FRAMEWORK = '$app/Contents/Frameworks/Sparkle.framework'
ARTIFACT = b'artifact\n'
DIGEST = hashlib.sha256(ARTIFACT).hexdigest()
RELEASE_FEED = 'https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml'
RELEASE_KEY = base64.b64encode(bytes(range(32))).decode()
RELEASE_SIGNATURE = base64.b64encode(bytes(range(64))).decode()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        (self.repo / 'scripts').mkdir()
        for name in ('bundle.sh', 'bundle-info.py', 'manifest.py', 'release-receipt.py',
                     'appcast.py', 'release_contract.py'):
            if (SCRIPTS / name).exists():
                shutil.copy2(SCRIPTS / name, self.repo / 'scripts' / name)
        self.bundle = self.repo / 'dist/MonoPods.app'
        for name in FILES:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(ARTIFACT)
        self.manifest = self.bundle / 'Contents/Resources/Manifest.json'
        self.document = {'v': 1, 'sourceCommit': COMMIT, 'build': DIGEST,
                         'files': dict.fromkeys(FILES, DIGEST)}
        self.save_manifest(self.document)
        self.dmg = self.repo / 'dist/MonoPods.dmg'
        self.dmg.write_bytes(b'disk image\n')
        self.output = self.root / 'receipt.json'
        self.tools = self.root / 'commands'
        self.tools.mkdir()
        self.command('codesign', '[ "$#" = 3 ] || exit 89\n'
                     '[ "$1" = --verify ] && [ "$2" = --strict ] || exit 89\n'
                     'exit "${FIXTURE_SIGN_EXIT:-0}"')
        self.command('swift', '[ "$*" = --version ] || exit 89\nprintf "Swift fixture\\nTarget: fixture\\n"')
        self.command('sw_vers', 'case "$*" in\n-productVersion) echo 14.2;;\n'
                     '-buildVersion) echo 23C64;;\n*) exit 89;;\nesac')
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith('GIT_')}
        self.environment.update(PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                                PYTHONDONTWRITEBYTECODE='1', GIT_CONFIG_NOSYSTEM='1',
                                GIT_CONFIG_GLOBAL=os.devnull)

    def command(self, name, body):
        path = self.tools / name
        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
        path.chmod(0o700)

    def run_command(self, *args):
        return subprocess.run(args, cwd=self.repo, env=self.environment,
                              capture_output=True, text=True, timeout=20)

    def manifest_command(self, action='verify', commit=None, bundle=None):
        args = ['python3', str(self.repo / 'scripts/manifest.py'), action,
                str(bundle or self.bundle)]
        if commit is not None:
            args.append(commit)
        return self.run_command(*args)

    def receipt_command(self, output=None, bundle=None, dmg=None, appcast=None):
        extra = () if appcast is None else ('--appcast', str(appcast))
        return self.run_command('python3', str(self.repo / 'scripts/release-receipt.py'),
                                str(bundle or self.bundle), str(dmg or self.dmg),
                                str(output or self.output), *extra)

    def save_manifest(self, value):
        self.manifest.write_text(json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n')

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_packaging_paths_and_volume_use_the_visible_name(self):
        # Packaging is inspected without building, mounting, or executing a disk image.
        bundle_lines = (SCRIPTS / 'bundle.sh').read_text().splitlines()
        self.assertIn('app=dist/MonoPods.app', bundle_lines)
        commands = [shlex.split(line) for line in (SCRIPTS / 'dmg.sh').read_text().splitlines()
                    if line.startswith(('ditto ', 'cp ', 'hdiutil ', 'codesign ',
                                        'python3 scripts/manifest'))]
        self.assertIn(['ditto', 'dist/MonoPods.app', '$stage/MonoPods.app'], commands)
        self.assertNotIn('cp -R', (SCRIPTS / 'dmg.sh').read_text())
        self.assertIn('test -L "$mountpoint/MonoPods.app/Contents/Frameworks/Sparkle.framework/'
                      'Versions/Current"', (SCRIPTS / 'dmg.sh').read_text())
        self.assertIn(['hdiutil', 'create', '-volname', 'MonoPods', '-srcfolder', '$stage',
                       '-format', 'UDZO', '-o', 'dist/MonoPods.dmg'], commands)
        self.assertIn(['hdiutil', 'verify', 'dist/MonoPods.dmg'], commands)
        self.assertIn(['codesign', '--verify', '--strict', 'dist/MonoPods.app'], commands)
        self.assertIn(['python3', 'scripts/manifest.py', 'verify', 'dist/MonoPods.app'], commands)

    def test_bundle_embeds_and_signs_sparkle_from_the_inside_out(self):
        text = (SCRIPTS / 'bundle.sh').read_text()
        lines = text.splitlines()
        def position(fragment):
            matches = [index for index, line in enumerate(lines) if fragment in line]
            self.assertEqual(len(matches), 1, fragment)
            return matches[0]
        ditto = position('ditto "$framework_src" "' + FRAMEWORK + '"')
        xpc = position("'Versions/B/XPCServices'")
        license_copy = position('Contents/Resources/Sparkle-LICENSE.txt')
        autoupdate = position('codesign --force --sign - "' + FRAMEWORK + '/Versions/B/Autoupdate"')
        updater = position('codesign --force --sign - "' + FRAMEWORK + '/Versions/B/Updater.app"')
        framework = position('codesign --force --sign - "' + FRAMEWORK + '"')
        signs = [index for index, line in enumerate(lines)
                 if line.startswith('codesign --force --sign - "$app"')]
        verify = position('codesign --verify --deep --strict "$app"')
        adhoc = position('python3 scripts/adhoc-check.py "$app"')
        manifest = position('python3 scripts/manifest.py write "$app"')
        self.assertEqual(len(signs), 2)
        self.assertLess(ditto, xpc)
        self.assertLess(xpc, autoupdate)
        self.assertLess(autoupdate, updater)
        self.assertLess(updater, framework)
        self.assertLess(framework, signs[0])
        self.assertLess(signs[0], manifest)
        self.assertLess(manifest, signs[1])
        self.assertLess(signs[1], verify)
        self.assertLess(verify, adhoc)
        self.assertLess(license_copy, signs[0])
        self.assertIn("'XPCServices'", text)
        self.assertIn(SPARKLE_LICENSE_SHA256, text)
        for line in lines:
            if line.lstrip().startswith('codesign '):
                with self.subTest(line=line):
                    words = shlex.split(line.strip())
                    for forbidden in ('--options', '-o', '--timestamp', '--entitlements'):
                        self.assertNotIn(forbidden, words)
                    if '--sign' in words:
                        self.assertEqual(words[words.index('--sign') + 1], '-')
                    if '--deep' in words:
                        self.assertIn('--verify', words)

    def test_sparkle_license_is_the_pinned_text(self):
        data = (SCRIPTS.parent / 'ThirdParty/Sparkle-LICENSE.txt').read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), SPARKLE_LICENSE_SHA256)

    def test_bundle_copies_every_resource_the_manifest_requires(self):
        lines = (SCRIPTS / 'bundle.sh').read_text().splitlines()
        copies = [shlex.split(line) for line in lines if line.startswith('cp Assets/')]
        self.assertEqual(copies, [['cp', 'Assets/AppIcon.icns', 'Assets/MenuBarIcon.png',
                                   'Assets/MenuBarIcon@2x.png', 'Assets/GitHubMark.pdf',
                                   '$app/Contents/Resources/']])
        resources = {name for name in FILES if name.startswith('Contents/Resources/')
                     and not name.endswith('Sparkle-LICENSE.txt')}
        copied = {'Contents/Resources/' + Path(name).name for name in copies[0][1:-1]}
        self.assertEqual(resources, copied)

    def test_manifest_records_full_source_commit(self):
        result = self.manifest_command('write', COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.manifest.read_text()), self.document)

    def test_manifest_verifies_without_expected_commit(self):
        result = self.manifest_command()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_manifest_verifies_matching_expected_commit(self):
        result = self.manifest_command(commit=COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_manifest_rejects_mismatching_expected_commit(self):
        self.assert_rejected(self.manifest_command(commit='f' * 40))

    def test_manifest_write_requires_valid_source_commit(self):
        for commit in (None, '', 'a' * 39, 'A' * 40, 'g' * 40, 'a' * 41):
            with self.subTest(commit=commit):
                before = self.manifest.read_bytes()
                self.assert_rejected(self.manifest_command('write', commit))
                self.assertEqual(self.manifest.read_bytes(), before)

    def test_manifest_rejects_changed_artifacts(self):
        for name in FILES:
            with self.subTest(name=name):
                path = self.bundle / name
                path.write_bytes(b'changed\n')
                self.assert_rejected(self.manifest_command())
                path.write_bytes(ARTIFACT)

    def test_manifest_rejects_incoherent_schema(self):
        mutations = []
        for key in self.document:
            missing = copy.deepcopy(self.document)
            del missing[key]
            mutations.append(missing)
        for key, values in {
            'v': [True, 1.0, 2, '1', None],
            'build': [True, [], '0' * 64],
            'sourceCommit': [None, 1, [], '', 'a' * 39, 'A' * 40, 'g' * 40, 'a' * 41],
            'files': [None, [], {}, dict(self.document['files'], extra=DIGEST)],
        }.items():
            for value in values:
                changed = copy.deepcopy(self.document)
                changed[key] = value
                mutations.append(changed)
        mutations.append(dict(self.document, extra=1))
        for value in mutations:
            with self.subTest(value=value):
                self.save_manifest(value)
                self.assert_rejected(self.manifest_command())

    def test_manifest_rejects_a_bundled_launch_agent(self):
        plist = 'Contents/Library/LaunchAgents/io.github.bernalli.monopods.agent.plist'
        path = self.bundle / plist
        path.parent.mkdir(parents=True)
        path.write_bytes(ARTIFACT)
        self.save_manifest(dict(self.document, files=dict(self.document['files'], **{plist: DIGEST})))
        self.assert_rejected(self.manifest_command())

    def test_manifest_rejects_duplicate_keys(self):
        self.manifest.write_text(self.manifest.read_text().replace('"v":1', '"v":2,"v":1'))
        self.assert_rejected(self.manifest_command())

    def test_manifest_rejects_malformed_documents(self):
        text = self.manifest.read_text()
        nested = text.replace('"files":{', '"files":{"Contents/Info.plist":"' + DIGEST + '",', 1)
        for value in ('', text[:len(text) // 2], text[:-2], '[]', 'null', '1', nested):
            with self.subTest(value=value[:40]):
                self.manifest.write_text(value)
                self.assert_rejected(self.manifest_command())

    def test_manifest_rejects_symlinks(self):
        for name in (*FILES, 'Contents/Resources/Manifest.json', 'Contents/Resources'):
            with self.subTest(name=name):
                path = self.bundle / name
                moved = self.root / 'moved'
                path.rename(moved)
                path.symlink_to(moved)
                self.assert_rejected(self.manifest_command())
                path.unlink()
                moved.rename(path)
        link = self.repo / 'dist/link.app'
        link.symlink_to(self.bundle)
        self.assert_rejected(self.manifest_command(bundle=link))

    def test_manifest_ignores_only_embedded_signature_bytes(self):
        binary = self.bundle / FILES[0]
        data = bytearray(32)
        data[:4] = b'\xcf\xfa\xed\xfe'
        struct.pack_into('<I', data, 16, 1)
        data.extend(struct.pack('<IIII', 0x1d, 16, 56, 8) + b'codecode' + b'signsign')
        binary.write_bytes(data)
        self.assertEqual(self.manifest_command('write', COMMIT).returncode, 0)
        expected = bytearray(data[:56])
        expected[40:48] = bytes(8)
        self.assertEqual(json.loads(self.manifest.read_text())['build'],
                         hashlib.sha256(expected).hexdigest())
        binary.write_bytes(data[:56] + b'resigned')
        self.assertEqual(self.manifest_command().returncode, 0)
        binary.write_bytes(data[:48] + b'new-code' + b'resigned')
        self.assert_rejected(self.manifest_command())

    def test_receipt_binds_artifacts_with_independent_hashes(self):
        result = self.receipt_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(self.output.read_text())
        self.assertEqual(set(value), {'v', 'sourceCommit', 'build', 'manifestSha256',
                                     'dmgSha256', 'bundleTreeSha256', 'toolchain', 'createdUTC',
                                     'signingMode'})
        self.assertEqual(value['signingMode'], 'ad-hoc')
        self.assertEqual(value['v'], 1)
        self.assertEqual(value['sourceCommit'], COMMIT)
        self.assertEqual(value['build'], DIGEST)
        self.assertEqual(value['manifestSha256'], hashlib.sha256(self.manifest.read_bytes()).hexdigest())
        self.assertEqual(value['dmgSha256'], hashlib.sha256(b'disk image\n').hexdigest())
        digest = hashlib.sha256()
        contents = dict.fromkeys(FILES, ARTIFACT)
        contents['Contents/Resources/Manifest.json'] = self.manifest.read_bytes()
        for relative in sorted(contents):
            name, data = relative.encode(), contents[relative]
            digest.update(b'F' + len(name).to_bytes(8, 'big') + name)
            digest.update(len(data).to_bytes(8, 'big') + data)
        self.assertEqual(value['bundleTreeSha256'], digest.hexdigest())
        self.assertEqual(value['toolchain'], {'swift': 'Swift fixture\nTarget: fixture',
                                           'macOSVersion': '14.2', 'macOSBuild': '23C64'})
        self.assertRegex(value['createdUTC'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')

    def test_receipt_tree_covers_extra_resources_and_paths(self):
        extra = self.bundle / 'Contents/Resources/extra'
        hashes = []
        for name, content in [('extra', b'one'), ('extra', b'two'), ('renamed', b'two')]:
            if extra.exists():
                extra.unlink()
            extra = extra.with_name(name)
            extra.write_bytes(content)
            result = self.receipt_command()
            self.assertEqual(result.returncode, 0, result.stderr)
            hashes.append(json.loads(self.output.read_text())['bundleTreeSha256'])
            self.output.unlink()
        self.assertEqual(len(set(hashes)), 3)

    def tree_hash(self):
        result = self.receipt_command()
        if self.output.exists():
            value = json.loads(self.output.read_text())['bundleTreeSha256']
            self.output.unlink()
            return result.returncode, value
        return result.returncode, None

    def test_receipt_tree_covers_internal_relative_links_without_following_them(self):
        versions = self.bundle / 'Contents/Frameworks/Sparkle.framework/Versions'
        (versions / 'A').mkdir()
        current = versions / 'Current'
        current.symlink_to('B')
        top = self.bundle / 'Contents/Frameworks/Sparkle.framework/Sparkle'
        top.symlink_to('Versions/Current/Sparkle')
        first = self.tree_hash()
        self.assertEqual(first[0], 0)
        current.unlink()
        current.symlink_to('A')
        top.unlink()
        top.symlink_to('Versions/B/Sparkle')
        second = self.tree_hash()
        self.assertEqual(second[0], 0)
        self.assertNotEqual(first[1], second[1])

    def test_receipt_tree_refuses_absolute_escaping_and_dangling_links(self):
        resources = self.bundle / 'Contents/Resources'
        for name, target in (('absolute', str(resources / 'AppIcon.icns')),
                             ('escaping', '../../../outside'), ('dangling', 'missing'),
                             ('escaping-directory', '../../..')):
            with self.subTest(name=name):
                (self.repo / 'dist/outside').write_bytes(ARTIFACT)
                link = resources / name
                link.symlink_to(target)
                self.assertNotEqual(self.tree_hash()[0], 0)
                self.assertFalse(self.output.exists())
                link.unlink()

    def test_receipt_tree_ignores_resource_seal(self):
        seal = self.bundle / 'Contents/_CodeSignature/CodeResources'
        seal.parent.mkdir()
        hashes = []
        for content in (b'first seal', b'new seal'):
            seal.write_bytes(content)
            result = self.receipt_command()
            self.assertEqual(result.returncode, 0, result.stderr)
            hashes.append(json.loads(self.output.read_text())['bundleTreeSha256'])
            self.output.unlink()
        self.assertEqual(*hashes)

    def test_receipt_tree_ignores_embedded_signature_but_covers_code(self):
        binary = self.bundle / FILES[0]
        header = bytearray(32)
        header[:4] = b'\xcf\xfa\xed\xfe'
        struct.pack_into('<I', header, 16, 1)
        prefix = header + struct.pack('<IIII', 0x1d, 16, 56, 8) + b'codecode'
        hashes = []
        for signature in (b'signsign', b'resigned'):
            binary.write_bytes(prefix + signature)
            self.assertEqual(self.manifest_command('write', COMMIT).returncode, 0)
            result = self.receipt_command()
            self.assertEqual(result.returncode, 0, result.stderr)
            hashes.append(json.loads(self.output.read_text())['bundleTreeSha256'])
            self.output.unlink()
        self.assertEqual(*hashes)
        binary.write_bytes(prefix[:48] + b'new-code' + b'resigned')
        self.assertEqual(self.manifest_command('write', COMMIT).returncode, 0)
        self.assertEqual(self.receipt_command().returncode, 0)
        self.assertNotEqual(hashes[0], json.loads(self.output.read_text())['bundleTreeSha256'])

    def release_info(self, **changes):
        # A real Info.plist with the production channel, bound into the manifest again.
        info = {'CFBundleVersion': '3', 'CFBundleShortVersionString': '1.2.3',
                'LSMinimumSystemVersion': '14.2', 'SUFeedURL': RELEASE_FEED,
                'SUPublicEDKey': RELEASE_KEY}
        info.update(changes)
        info = {key: value for key, value in info.items() if value is not None}
        data = plistlib.dumps(info)
        (self.bundle / 'Contents/Info.plist').write_bytes(data)
        files = dict(self.document['files'])
        files['Contents/Info.plist'] = hashlib.sha256(data).hexdigest()
        self.save_manifest(dict(self.document, files=files))

    def release_feed(self, build='3', url=None):
        url = url or 'https://github.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.dmg'
        feed = self.root / 'appcast.xml'
        feed.unlink(missing_ok=True)
        feed.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            '  <channel>\n    <title>MonoPods</title>\n    <item>\n'
            '      <title>Version 1.2.3</title>\n'
            '      <pubDate>Mon, 09 Nov 2026 10:11:12 +0000</pubDate>\n'
            f'      <sparkle:version>{build}</sparkle:version>\n'
            '      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>\n'
            '      <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>\n'
            f'      <enclosure url="{url}" length="{len(b"disk image" + bytes([10]))}" '
            f'type="application/octet-stream" sparkle:edSignature="{RELEASE_SIGNATURE}"/>\n'
            '    </item>\n  </channel>\n</rss>\n')
        return feed

    def test_release_receipt_records_feed_channel_version_and_signing_mode(self):
        self.release_info()
        for url in (None, 'file://' + str(self.root / 'MonoPods-3.dmg')):
            with self.subTest(url=url):
                feed = self.release_feed(url=url)
                self.output.unlink(missing_ok=True)
                result = self.receipt_command(appcast=feed)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(self.output.read_text())
                self.assertEqual(set(value), {'v', 'sourceCommit', 'build', 'manifestSha256',
                                             'dmgSha256', 'bundleTreeSha256', 'toolchain',
                                             'createdUTC', 'signingMode', 'appcastSha256',
                                             'bundleVersion', 'shortVersion', 'feedURL',
                                             'publicEDKey'})
                self.assertEqual(value['signingMode'], 'ad-hoc')
                self.assertEqual(value['appcastSha256'],
                                 hashlib.sha256(feed.read_bytes()).hexdigest())
                self.assertEqual((value['bundleVersion'], value['shortVersion']), ('3', '1.2.3'))
                self.assertEqual((value['feedURL'], value['publicEDKey']),
                                 (RELEASE_FEED, RELEASE_KEY))
                for key in value:
                    self.assertNotRegex(key.lower(), 'identity|team|notar|profile|private')

    def test_release_receipt_refuses_feeds_and_channels_that_differ_without_output(self):
        cases = [({}, dict(build='4')), ({}, dict(url='https://example.com/MonoPods.dmg')),
                 ({'SUFeedURL': 'https://example.com/appcast.xml'}, {}),
                 ({'SUFeedURL': None}, {}), ({'SUPublicEDKey': None}, {}),
                 ({'SUPublicEDKey': 'short'}, {}), ({'CFBundleShortVersionString': '1.2.4'}, {})]
        for info, feed in cases:
            with self.subTest(info=info, feed=feed):
                self.release_info(**info)
                self.assert_rejected(self.receipt_command(appcast=self.release_feed(**feed)))
                self.assertFalse(self.output.exists())

    def test_release_receipt_refuses_a_linked_or_invalid_feed_without_output(self):
        self.release_info()
        feed = self.release_feed()
        link = self.root / 'linked.xml'
        link.symlink_to(feed)
        self.assert_rejected(self.receipt_command(appcast=link))
        feed.write_text('<rss/>\n')
        self.assert_rejected(self.receipt_command(appcast=feed))
        self.assert_rejected(self.receipt_command(appcast=self.root / 'absent.xml'))
        self.assertFalse(self.output.exists())

    def test_receipt_rejects_invalid_signature_without_output(self):
        self.environment['FIXTURE_SIGN_EXIT'] = '1'
        self.assert_rejected(self.receipt_command())
        self.assertFalse(self.output.exists())

    def test_receipt_rejects_changed_build_without_output(self):
        (self.bundle / FILES[0]).write_bytes(b'wrong build')
        self.assert_rejected(self.receipt_command())
        self.assertFalse(self.output.exists())

    def test_receipt_rejects_invalid_manifest_without_output(self):
        self.save_manifest(dict(self.document, extra=1))
        self.assert_rejected(self.receipt_command())
        self.assertFalse(self.output.exists())

    def test_receipt_rejects_missing_toolchain_without_output(self):
        self.command('swift', 'exit 1')
        self.assert_rejected(self.receipt_command())
        self.assertFalse(self.output.exists())

    def test_receipt_refuses_outputs_in_repository(self):
        for output in (self.repo / 'receipt.json', self.repo / 'dist/receipt.json'):
            with self.subTest(output=output):
                self.assert_rejected(self.receipt_command(output))
                self.assertFalse(output.exists())

    def test_receipt_refuses_existing_output(self):
        self.output.write_text('preserve')
        self.assert_rejected(self.receipt_command())
        self.assertEqual(self.output.read_text(), 'preserve')

    def test_receipt_refuses_relative_output(self):
        self.assert_rejected(self.receipt_command(Path('../receipt.json')))
        self.assertFalse(self.output.exists())

    def test_receipt_refuses_symlinks(self):
        for path in (self.dmg, self.bundle / 'Contents/Resources/extra', self.output):
            with self.subTest(path=path):
                if path.exists():
                    path.unlink()
                path.symlink_to(self.root / 'absent')
                self.assert_rejected(self.receipt_command())
                path.unlink()
                self.dmg.write_bytes(b'disk image\n')
        link = self.root / 'linked'
        link.symlink_to(self.root)
        self.assert_rejected(self.receipt_command(link / 'receipt.json'))
        self.assertFalse(self.output.exists())

    def test_receipt_refuses_artifacts_outside_dist(self):
        elsewhere = self.root / 'elsewhere.app'
        self.bundle.rename(elsewhere)
        self.assert_rejected(self.receipt_command(bundle=elsewhere))
        elsewhere.rename(self.bundle)
        other_dmg = self.root / 'other.dmg'
        self.dmg.rename(other_dmg)
        self.assert_rejected(self.receipt_command(dmg=other_dmg))
        self.assertFalse(self.output.exists())

    def test_receipt_refuses_primary_checkout_output_from_linked_worktree(self):
        fixture = self.root / 'fixture.app'
        shutil.copytree(self.bundle, fixture)
        self.init_git()
        self.command('swift', '[ "$*" = --version ] || exit 89\nprintf "Swift fixture\\nTarget: fixture\\n"')
        worktree = self.repo / 'build/linked'
        result = self.run_command('git', 'worktree', 'add', '-q', '-b', 'feature/linked', str(worktree))
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = worktree / 'dist/MonoPods.app'
        shutil.copytree(fixture, bundle)
        shutil.copy2(self.dmg, worktree / 'dist/MonoPods.dmg')
        args = ('python3', str(worktree / 'scripts/release-receipt.py'),
                str(bundle), str(worktree / 'dist/MonoPods.dmg'))
        valid = self.run_command(*args, str(self.output))
        self.assertEqual(valid.returncode, 0, valid.stderr)
        output = self.repo / 'receipt.json'
        result = self.run_command(*args, str(output))
        self.assert_rejected(result)
        self.assertFalse(output.exists())

    def init_git(self):
        for relative in SOURCE_ARTIFACTS:
            path = self.repo / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(ARTIFACT)
        for args in (('init', '-q', '-b', 'feature/fixture'),
                     ('add', 'scripts', 'Assets', 'Resources', 'LICENSE', 'ThirdParty'),
                     ('-c', 'user.name=Release Fixture', '-c', 'user.email=fixture@example.invalid',
                      '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture')):
            result = self.run_command('git', *args)
            self.assertEqual(result.returncode, 0, result.stderr)
        shutil.rmtree(self.bundle)
        # A build marker proves that refusal happened before any build or signing.
        self.command('swift', 'touch "$PWD/build-reached"\nexit 91')

    def bundle_command(self, *arguments):
        return self.run_command('bash', 'scripts/bundle.sh', *arguments)

    def test_bundle_refuses_any_argument_before_build(self):
        self.init_git()
        runtime = str(self.root / 'runtime')
        channel = str(self.root / 'channel.json')
        for arguments in ((runtime,), (runtime, str(self.root / 'LaunchAgents')), ('',),
                          ('--update-channel',), ('--candidate-version', '5'),
                          ('--update-channel', channel, '--other', 'x'),
                          ('--update-channel', channel, '--candidate-version'),
                          ('--candidate-version', '5', '--update-channel', channel),
                          ('--update-channel', channel, '--update-channel', channel)):
            with self.subTest(arguments=arguments):
                result = self.bundle_command(*arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_embeds_no_paths_and_checks_the_built_app(self):
        text = (SCRIPTS / 'bundle.sh').read_text()
        # Split so that a repository search for the retired file name finds nothing.
        self.assertNotIn('Runtime' 'Config', text)
        lines = [shlex.split(line) for line in text.splitlines()
                 if line.startswith(('python3 scripts/macho.py', 'python3 scripts/artifact-scan.py'))]
        self.assertIn(['python3', 'scripts/macho.py', 'check-app', '$app'], lines)
        self.assertIn(['python3', 'scripts/artifact-scan.py', 'bundle', '$app',
                       '--forbid', '$PWD', '--forbid', '$HOME',
                       '--exclude-prefix', 'Contents/Frameworks/Sparkle.framework/'], lines)
        self.assertIn('python3 scripts/macho.py rpaths "$app/Contents/MacOS/MonoPods"', text)
        self.assertIn('install_name_tool -delete_rpath', text)

    def test_bundle_refuses_modified_and_staged_sources_before_build(self):
        self.init_git()
        source = self.repo / 'scripts/manifest.py'
        source.write_text(source.read_text() + '\n# changed\n')
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.run_command('git', 'add', 'scripts/manifest.py')
                self.assert_rejected(self.bundle_command())
                self.assertFalse((self.repo / 'build-reached').exists())

    def reset_repository(self):
        # Keep only the copied scripts, so each case starts from a fresh fixture checkout.
        for child in self.repo.iterdir():
            if child.name == 'scripts':
                continue
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        self.bundle.mkdir(parents=True)

    def commit_fixture(self, message):
        for args in (('add', '-A'),
                     ('-c', 'user.name=Release Fixture', '-c', 'user.email=fixture@example.invalid',
                      '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', message)):
            result = self.run_command('git', *args)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_bundle_refuses_committed_missing_or_linked_source_artifacts_before_build(self):
        # A clean checkout that lacks a source artifact, or carries it as a link, is refused.
        for relative in SOURCE_ARTIFACTS:
            for linked in (False, True):
                with self.subTest(relative=relative, linked=linked):
                    self.reset_repository()
                    self.init_git()
                    path = self.repo / relative
                    path.unlink()
                    if linked:
                        target = self.repo / 'linked-artifact'
                        target.write_bytes(ARTIFACT)
                        path.symlink_to(target)
                    self.commit_fixture('remove artifact')
                    self.assert_rejected(self.bundle_command())
                    self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_refuses_untracked_sources_before_build(self):
        self.init_git()
        (self.repo / 'unexpected').write_text('untracked')
        self.assert_rejected(self.bundle_command())
        self.assertFalse((self.repo / 'build-reached').exists())

    def assert_index_flag_refused(self, flag):
        self.init_git()
        source = self.repo / 'scripts/manifest.py'
        self.assertEqual(self.run_command('git', 'update-index', flag, 'scripts/manifest.py').returncode, 0)
        source.write_text(source.read_text() + '\n# hidden\n')
        self.assert_rejected(self.bundle_command())
        self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_refuses_assume_unchanged_sources(self):
        self.assert_index_flag_refused('--assume-unchanged')

    def test_bundle_refuses_skip_worktree_sources(self):
        self.assert_index_flag_refused('--skip-worktree')

    def test_bundle_refuses_ignored_sources_outside_artifact_directories(self):
        self.init_git()
        (self.repo / '.git/info/exclude').write_text('ignored-source\n')
        (self.repo / 'ignored-source').write_bytes(ARTIFACT)
        self.assert_rejected(self.bundle_command())
        self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_refuses_tracked_artifact_changes(self):
        self.init_git()
        tracked = self.repo / 'build/tracked'
        tracked.parent.mkdir()
        tracked.write_bytes(ARTIFACT)
        self.assertEqual(self.run_command('git', 'add', 'build/tracked').returncode, 0)
        self.assert_rejected(self.bundle_command())
        self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_allows_only_artifact_directories_for_untracked_files(self):
        self.init_git()
        for relative in ('build/cache/item', '.build/item', 'dist/item'):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(ARTIFACT)
        result = self.bundle_command()
        self.assertEqual(result.returncode, 91, result.stderr)
        self.assertTrue((self.repo / 'build-reached').exists())

    def test_bundle_refuses_detached_unreachable_commit(self):
        self.init_git()
        tree = self.run_command('git', 'rev-parse', 'HEAD^{tree}').stdout.strip()
        commit = self.run_command('git', '-c', 'user.name=Release Fixture', '-c',
                                  'user.email=fixture@example.invalid', 'commit-tree', tree,
                                  '-m', 'unreachable').stdout.strip()
        self.assertEqual(self.run_command('git', 'checkout', '-q', '--detach', commit).returncode, 0)
        self.assert_rejected(self.bundle_command())
        self.assertFalse((self.repo / 'build-reached').exists())

    def test_bundle_accepts_detached_reachable_commit(self):
        self.init_git()
        self.assertEqual(self.run_command('git', 'checkout', '-q', '--detach', 'HEAD').returncode, 0)
        result = self.bundle_command()
        self.assertEqual(result.returncode, 91, result.stderr)
        self.assertTrue((self.repo / 'build-reached').exists())

    def test_check_refuses_an_incomplete_swift_suite_before_python(self):
        shutil.copy2(SCRIPTS / 'check.sh', self.repo / 'scripts/check.sh')
        self.command('swift', 'echo "Test run with 490 tests passed"')
        self.command('python3', 'touch python-reached')
        for name in ('swift-format', 'swiftlint', 'plutil'):
            self.command(name, 'exit 0')
        self.environment['TMPDIR'] = str(self.root)
        result = self.run_command('bash', 'scripts/check.sh')
        self.assert_rejected(result)
        self.assertFalse((self.repo / 'python-reached').exists())

    def test_check_fails_when_python_tests_fail(self):
        shutil.copy2(SCRIPTS / 'check.sh', self.repo / 'scripts/check.sh')
        tests = self.repo / 'scripts/tests'
        tests.mkdir()
        (tests / 'test_failure.py').write_text(
            'import unittest\nclass Failure(unittest.TestCase):\n'
            '    def test_failure(self):\n        self.fail("fixture failure")\n')
        self.command('swift', 'echo "Test run with 498 tests passed"')
        for name in ('swift-format', 'swiftlint', 'plutil'):
            self.command(name, 'exit 0')
        self.environment['TMPDIR'] = str(self.root)
        result = self.run_command('bash', 'scripts/check.sh')
        self.assert_rejected(result)
        self.assertIn('fixture failure', result.stdout)


if __name__ == '__main__':
    unittest.main()
