"""Release flow scripts, exercised only with stand-in tools in temporary folders."""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
SPARKLE_SHA256 = "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
SPARKLE_URL = (
    "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/"
    "Sparkle-for-Swift-Package-Manager.zip"
)
FEED = "https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml"
PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode()
OTHER_KEY = base64.b64encode(bytes(range(1, 33))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
ACCOUNT = "monopods"


def write_tool(path, body):
    """A stand-in command that records its own name and arguments."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/bin/bash\nset -eu\n"
        'printf "%s" "$(basename "$0")" >> "$FIXTURE_LOG"\n'
        'for argument in "$@"; do printf " %s" "$argument" >> "$FIXTURE_LOG"; done\n'
        'printf "\\n" >> "$FIXTURE_LOG"\n' + body + "\n"
    )
    path.chmod(0o700)


class FlowFixture(unittest.TestCase):
    """A repository copy with a log of every stand-in tool call."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        self.tools = self.root / "commands"
        self.tools.mkdir()
        self.log = self.root / "tools.log"
        self.log.write_text("")
        self.environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "MONOPODS_", "FIXTURE_"))
        }
        self.environment.update(
            PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            PYTHONDONTWRITEBYTECODE="1",
            FIXTURE_LOG=str(self.log),
        )

    def calls(self):
        return [line.split(" ") for line in self.log.read_text().splitlines()]

    def names(self):
        return [call[0] for call in self.calls()]

    def run_script(self, name, *arguments):
        return subprocess.run(
            ["bash", str(self.repo / "scripts" / name), *arguments],
            cwd=self.repo,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=30,
        )


class SparkleToolsTests(FlowFixture):
    def setUp(self):
        super().setUp()
        shutil.copy2(
            SCRIPTS / "sparkle-tools.sh", self.repo / "scripts/sparkle-tools.sh"
        )
        self.archive = self.root / "archive.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name in ("generate_keys", "sign_update"):
                archive.writestr(f"bin/{name}", b"tool\n")
        self.cache = self.repo / "build/sparkle-tools"
        self.extracted = self.cache / "2.10.1"
        # The stand-ins accept the fixture archive as if it carried the pinned digest.
        write_tool(
            self.tools / "curl",
            'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\n'
            '[ -n "$out" ] || exit 89\n'
            'cp "$FIXTURE_ARCHIVE" "$out"\nexit "${FIXTURE_CURL_EXIT:-0}"',
        )
        write_tool(
            self.tools / "ditto",
            '[ "$1" = -x ] && [ "$2" = -k ] || exit 89\n'
            'mkdir -p "$4/bin"\n'
            "for tool in generate_keys sign_update generate_appcast BinaryDelta; do\n"
            '  printf "tool\\n" > "$4/bin/$tool"; chmod 700 "$4/bin/$tool"\ndone',
        )
        write_tool(
            self.tools / "codesign",
            '[ "$1" = --verify ] && [ "$2" = --strict ] || exit 89\n'
            'case "$3" in *"${FIXTURE_BAD_TOOL:-none}") exit 1;; esac',
        )
        self.environment.update(FIXTURE_ARCHIVE=str(self.archive))
        self.pin(hashlib.sha256(self.archive.read_bytes()).hexdigest())

    def pin(self, digest):
        """Point the copied script at the digest of the fixture archive."""
        script = self.repo / "scripts/sparkle-tools.sh"
        text = (SCRIPTS / "sparkle-tools.sh").read_text()
        self.assertEqual(text.count(SPARKLE_SHA256), 1)
        script.write_text(text.replace(SPARKLE_SHA256, digest))

    def test_constants_are_the_pinned_release(self):
        text = (SCRIPTS / "sparkle-tools.sh").read_text()
        self.assertIn("\nSPARKLE_VERSION=2.10.1\n", text)
        self.assertIn("\nSPARKLE_SPM_SHA256=" + SPARKLE_SHA256 + "\n", text)

    def test_downloads_verifies_extracts_and_prints_the_folder(self):
        result = self.run_script("sparkle-tools.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.extracted) + "\n")
        calls = self.calls()
        self.assertEqual(
            [call[0] for call in calls], ["curl", "ditto", "codesign", "codesign"]
        )
        self.assertIn(SPARKLE_URL, calls[0])
        self.assertEqual(calls[1][:3], ["ditto", "-x", "-k"])
        self.assertEqual(
            calls[2],
            [
                "codesign",
                "--verify",
                "--strict",
                str(self.extracted / "bin/generate_keys"),
            ],
        )
        self.assertEqual(
            calls[3],
            [
                "codesign",
                "--verify",
                "--strict",
                str(self.extracted / "bin/sign_update"),
            ],
        )
        self.assertTrue((self.extracted / "bin/sign_update").is_file())
        self.assertEqual(
            sorted(path.name for path in self.cache.iterdir()),
            ["2.10.1", "Sparkle-for-Swift-Package-Manager.zip"],
        )

    def test_mismatching_download_stops_without_extraction(self):
        self.pin("0" * 64)
        result = self.run_script("sparkle-tools.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.names(), ["curl"])
        self.assertFalse(self.extracted.exists())
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_failed_download_stops_without_extraction(self):
        self.environment["FIXTURE_CURL_EXIT"] = "22"
        result = self.run_script("sparkle-tools.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.names(), ["curl"])
        self.assertFalse(self.extracted.exists())
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_existing_archive_with_another_digest_stops_without_extraction(self):
        self.cache.mkdir(parents=True)
        (self.cache / "Sparkle-for-Swift-Package-Manager.zip").write_bytes(
            b"tampered\n"
        )
        result = self.run_script("sparkle-tools.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.names(), [])
        self.assertFalse(self.extracted.exists())

    def test_existing_folder_and_valid_archive_are_reused_without_download(self):
        self.assertEqual(self.run_script("sparkle-tools.sh").returncode, 0)
        marker = self.extracted / "bin/generate_keys"
        marker.write_text("tool\n")
        self.log.write_text("")
        result = self.run_script("sparkle-tools.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.extracted) + "\n")
        self.assertEqual(self.names(), ["codesign", "codesign"])
        self.assertEqual(marker.read_text(), "tool\n")

    def test_changed_cached_tool_stops_even_with_valid_signature(self):
        self.assertEqual(self.run_script("sparkle-tools.sh").returncode, 0)
        for name in ("generate_keys", "sign_update"):
            with self.subTest(name=name):
                tool = self.extracted / "bin" / name
                tool.write_bytes(b"evil\n")
                self.log.write_text("")
                result = self.run_script("sparkle-tools.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.names(), [])
                tool.write_bytes(b"tool\n")

    def test_valid_archive_without_folder_is_extracted_without_download(self):
        self.cache.mkdir(parents=True)
        shutil.copy2(self.archive, self.cache / "Sparkle-for-Swift-Package-Manager.zip")
        result = self.run_script("sparkle-tools.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names(), ["ditto", "codesign", "codesign"])

    def test_failed_signature_check_of_either_tool_stops(self):
        for tool in ("generate_keys", "sign_update"):
            with self.subTest(tool=tool):
                self.environment["FIXTURE_BAD_TOOL"] = tool
                result = self.run_script("sparkle-tools.sh")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_missing_or_linked_tool_stops_before_signature_check(self):
        self.assertEqual(self.run_script("sparkle-tools.sh").returncode, 0)
        tool = self.extracted / "bin/sign_update"
        for linked in (False, True):
            with self.subTest(linked=linked):
                tool.unlink(missing_ok=True)
                if linked:
                    tool.symlink_to(self.extracted / "bin/generate_keys")
                self.log.write_text("")
                result = self.run_script("sparkle-tools.sh")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn(
                    ["codesign", "--verify", "--strict", str(tool)], self.calls()
                )

    def test_linked_cache_folders_are_refused(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        for relative in ("build", "build/sparkle-tools", "build/sparkle-tools/2.10.1"):
            with self.subTest(relative=relative):
                build = self.repo / "build"
                if build.is_symlink():
                    build.unlink()
                shutil.rmtree(build, ignore_errors=True)
                path = self.repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(elsewhere)
                self.log.write_text("")
                result = self.run_script("sparkle-tools.sh")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(self.names(), [])
                self.assertEqual(list(elsewhere.iterdir()), [])

    def test_arguments_are_refused(self):
        result = self.run_script("sparkle-tools.sh", "--version", "2.9.0")
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.names(), [])


STEPS = (
    "sparkle-tools.sh",
    "generate_keys",
    "check.sh",
    "bundle.sh",
    "adhoc-check.py",
    "manifest.py",
    "dmg.sh",
    "sign_update",
    "sign_update",
)


class ReleaseScriptTests(FlowFixture):
    def setUp(self):
        super().setUp()
        scripts = self.repo / "scripts"
        for name in ("release.sh", "bundle-info.py"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        (self.repo / "Resources").mkdir()
        self.channel = self.repo / "Resources/UpdateChannel.json"
        self.channel.write_text(
            json.dumps({"v": 1, "feedURL": FEED, "publicEDKey": PUBLIC_KEY})
        )
        self.sparkle = self.root / "sparkle"
        write_tool(scripts / "sparkle-tools.sh", 'printf "%s\\n" "$FIXTURE_SPARKLE"')
        write_tool(
            self.sparkle / "bin/generate_keys",
            '[ "$1 $2 $3" = "--account monopods -p" ] || exit 89\n'
            'printf "%s\\n" "${FIXTURE_KEY}"',
        )
        write_tool(
            self.sparkle / "bin/sign_update",
            '[ "$1 $2" = "--account monopods" ] || exit 89\n'
            'if [ "$3" = -p ]; then printf "%s\\n" "$FIXTURE_SIGNATURE"; exit 0; fi\n'
            '[ "$3" = --verify ] && [ "$5" = "$FIXTURE_SIGNATURE" ] || exit 89\n'
            'exit "${FIXTURE_VERIFY_EXIT:-0}"',
        )
        write_tool(scripts / "check.sh", 'exit "${FIXTURE_CHECK_EXIT:-0}"')
        write_tool(
            scripts / "bundle.sh",
            "mkdir -p dist/MonoPods.app/Contents\n"
            'version=1; [ "${3:-}" = --candidate-version ] && version=$4\n'
            'python3 - "$version" <<"PY"\n'
            "import plistlib, sys\n"
            'info = {"CFBundleVersion": sys.argv[1], "CFBundleShortVersionString": "0.2.0",\n'
            '        "LSMinimumSystemVersion": "14.2"}\n'
            'open("dist/MonoPods.app/Contents/Info.plist", "wb").write(plistlib.dumps(info))\n'
            "PY",
        )
        write_tool(scripts / "dmg.sh", 'printf "image\\n" > dist/MonoPods.dmg')
        for name, variable in (
            ("adhoc-check.py", "FIXTURE_ADHOC_EXIT"),
            ("manifest.py", "FIXTURE_MANIFEST_EXIT"),
            ("appcast.py", "FIXTURE_APPCAST_EXIT"),
            ("release-receipt.py", "FIXTURE_RECEIPT_EXIT"),
            ("artifact-scan.py", "FIXTURE_SCAN_EXIT"),
        ):
            self.python_tool(name, variable)
        write_tool(
            self.tools / "curl",
            'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\n'
            '[ "${FIXTURE_PREVIOUS:-yes}" = yes ] || exit 22\n'
            'printf "previous\\n" > "$out"',
        )
        write_tool(self.tools / "ditto", 'cp "$1" "$2"')
        for name in ("codesign", "notarytool", "stapler", "spctl", "xcrun"):
            write_tool(self.tools / name, "exit 0")
        self.receipts = self.root / "receipts"
        self.receipts.mkdir()
        self.receipt = self.receipts / "release.json"
        self.staging = self.root / "staging"
        self.staging.mkdir()
        self.environment.update(
            FIXTURE_SPARKLE=str(self.sparkle),
            FIXTURE_KEY=PUBLIC_KEY,
            FIXTURE_SIGNATURE=SIGNATURE,
            MONOPODS_SPARKLE_ACCOUNT=ACCOUNT,
            MONOPODS_RECEIPT=str(self.receipt),
        )

    def python_tool(self, name, variable):
        path = self.repo / "scripts" / name
        path.write_text(
            "import os, sys\n"
            'with open(os.environ["FIXTURE_LOG"], "a") as log:\n'
            f'    log.write(" ".join(["{name}", *sys.argv[1:]]) + "\\n")\n'
            "arguments = sys.argv[1:]\n"
            'if "--output" in arguments:\n'
            '    open(arguments[arguments.index("--output") + 1], "x").write("feed\\n")\n'
            f'sys.exit(int(os.environ.get("{variable}", "0")))\n'
        )

    def release(self, *arguments):
        return self.run_script("release.sh", *arguments)

    def assert_stopped_before(self, result, step, code=1):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertNotIn("___RELEASE_END", result.stdout)
        if step is None:
            self.assertEqual(self.names(), [])
        else:
            self.assertNotIn(step, self.names())

    def test_production_release_runs_every_step_in_order(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        names = [call[0] for call in calls]
        self.assertEqual(
            names,
            [
                *STEPS,
                "curl",
                "appcast.py",
                "appcast.py",
                "release-receipt.py",
                "artifact-scan.py",
            ],
        )
        self.assertEqual(calls[1], ["generate_keys", "--account", ACCOUNT, "-p"])
        self.assertEqual(
            calls[3], ["bundle.sh", "--update-channel", "Resources/UpdateChannel.json"]
        )
        self.assertEqual(calls[4], ["adhoc-check.py", "dist/MonoPods.app"])
        self.assertEqual(calls[5], ["manifest.py", "verify", "dist/MonoPods.app"])
        self.assertEqual(
            calls[7], ["sign_update", "--account", ACCOUNT, "-p", "dist/MonoPods.dmg"]
        )
        self.assertEqual(
            calls[8],
            [
                "sign_update",
                "--account",
                ACCOUNT,
                "--verify",
                "dist/MonoPods.dmg",
                SIGNATURE,
            ],
        )
        self.assertIn(FEED, calls[9])
        self.assertEqual(
            calls[9][calls[9].index("-o") + 1], "dist/previous-appcast.xml"
        )
        build = calls[10]
        self.assertEqual(build[:2], ["appcast.py", "build"])
        self.assertNotIn("--candidate", build)
        self.assertEqual(
            build[build.index("--download-url") + 1],
            "https://github.com/bernalli/monoPods/releases/download/v0.2.0/MonoPods.dmg",
        )
        self.assertEqual(build[build.index("--signature") + 1], SIGNATURE)
        self.assertEqual(build[build.index("--output") + 1], "dist/appcast.xml")
        date = " ".join(
            build[build.index("--pub-date") + 1 : build.index("--pub-date") + 7]
        )
        self.assertRegex(
            date,
            r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d\d "
            r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} "
            r"\d\d:\d\d:\d\d \+0000$",
        )
        self.assertEqual(
            calls[11],
            [
                "appcast.py",
                "check",
                "--appcast",
                "dist/appcast.xml",
                "--bundle",
                "dist/MonoPods.app",
                "--dmg",
                "dist/MonoPods.dmg",
                "--previous",
                "dist/previous-appcast.xml",
            ],
        )
        self.assertEqual(
            calls[12],
            [
                "release-receipt.py",
                "dist/MonoPods.app",
                "dist/MonoPods.dmg",
                str(self.receipt),
                "--appcast",
                "dist/appcast.xml",
            ],
        )
        self.assertEqual(
            calls[13],
            [
                "artifact-scan.py",
                "bundle",
                "dist/MonoPods.app",
                "--forbid",
                str(self.repo),
                "--forbid",
                self.environment["HOME"],
                "--exclude-prefix",
                "Contents/Frameworks/Sparkle.framework/",
            ],
        )
        self.assertEqual(
            result.stdout.splitlines()[-1], "___RELEASE_END ok version=0.2.0 build=1___"
        )
        self.assertEqual(result.stdout.count("___RELEASE_END"), 1)

    def test_first_release_runs_without_previous_feed(self):
        self.environment["FIXTURE_PREVIOUS"] = "no"
        result = self.release("--first-release")
        self.assertEqual(result.returncode, 0, result.stderr)
        check = [call for call in self.calls() if call[:2] == ["appcast.py", "check"]]
        self.assertEqual(
            check,
            [
                [
                    "appcast.py",
                    "check",
                    "--appcast",
                    "dist/appcast.xml",
                    "--bundle",
                    "dist/MonoPods.app",
                    "--dmg",
                    "dist/MonoPods.dmg",
                ]
            ],
        )
        self.assertFalse((self.repo / "dist/previous-appcast.xml").exists())

    def test_production_without_previous_feed_needs_first_release(self):
        self.environment["FIXTURE_PREVIOUS"] = "no"
        self.assert_stopped_before(self.release(), "appcast.py")

    def test_first_release_with_a_reachable_feed_stops(self):
        self.assert_stopped_before(self.release("--first-release"), "appcast.py")

    def test_candidate_writes_the_feed_and_image_into_the_staging_folder(self):
        result = self.release(
            "--candidate-version", "3", "--staging-dir", str(self.staging)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        names = [call[0] for call in calls]
        self.assertEqual(
            names,
            [
                *STEPS,
                "ditto",
                "appcast.py",
                "appcast.py",
                "release-receipt.py",
                "artifact-scan.py",
            ],
        )
        self.assertNotIn("curl", names)
        image = str(self.staging / "MonoPods-3.dmg")
        feed = str(self.staging / "appcast-3.xml")
        self.assertEqual(
            calls[3],
            [
                "bundle.sh",
                "--update-channel",
                "Resources/UpdateChannel.json",
                "--candidate-version",
                "3",
            ],
        )
        self.assertEqual(calls[9], ["ditto", "dist/MonoPods.dmg", image])
        build = calls[10]
        self.assertEqual(build[:3], ["appcast.py", "build", "--candidate"])
        self.assertEqual(build[build.index("--dmg") + 1], image)
        self.assertEqual(build[build.index("--download-url") + 1], "file://" + image)
        self.assertEqual(build[build.index("--output") + 1], feed)
        self.assertEqual(
            calls[11],
            [
                "appcast.py",
                "check",
                "--candidate",
                "--appcast",
                feed,
                "--bundle",
                "dist/MonoPods.app",
                "--dmg",
                image,
            ],
        )
        self.assertEqual(
            calls[12],
            [
                "release-receipt.py",
                "dist/MonoPods.app",
                "dist/MonoPods.dmg",
                str(self.receipt),
                "--appcast",
                feed,
            ],
        )
        self.assertEqual((self.staging / "MonoPods-3.dmg").read_text(), "image\n")
        self.assertEqual(
            result.stdout.splitlines()[-1], "___RELEASE_END ok version=0.2.0 build=3___"
        )

    def test_mismatching_public_key_stops_before_checks(self):
        self.environment["FIXTURE_KEY"] = OTHER_KEY
        self.assert_stopped_before(self.release(), "check.sh")
        self.environment["FIXTURE_KEY"] = ""
        self.log.write_text("")
        self.assert_stopped_before(self.release(), "check.sh")

    def test_invalid_channel_file_stops_before_checks(self):
        for text in (
            "",
            "{}",
            json.dumps({"v": 1, "feedURL": FEED, "publicEDKey": "short"}),
        ):
            with self.subTest(text=text):
                self.channel.write_text(text)
                self.log.write_text("")
                self.assert_stopped_before(self.release(), "check.sh")

    def test_candidate_needs_an_absolute_staging_folder(self):
        for arguments in (
            ("--candidate-version", "3"),
            ("--staging-dir", str(self.staging)),
            ("--candidate-version", "3", "--staging-dir", "staging"),
            ("--candidate-version", "3", "--staging-dir", ""),
            (
                "--candidate-version",
                "3",
                "--staging-dir",
                str(self.staging) + "/../staging",
            ),
            ("--candidate-version", "03", "--staging-dir", str(self.staging)),
            ("--candidate-version", "1000000000", "--staging-dir", str(self.staging)),
            (
                "--first-release",
                "--candidate-version",
                "3",
                "--staging-dir",
                str(self.staging),
            ),
        ):
            with self.subTest(arguments=arguments):
                self.assert_stopped_before(self.release(*arguments), None, 64)

    def test_missing_or_linked_staging_folder_stops(self):
        linked = self.root / "linked"
        linked.symlink_to(self.staging)
        for folder in (self.root / "absent", linked, self.channel):
            with self.subTest(folder=folder):
                self.assert_stopped_before(
                    self.release(
                        "--candidate-version", "3", "--staging-dir", str(folder)
                    ),
                    None,
                )

    def test_existing_candidate_outputs_are_refused(self):
        for name in ("MonoPods-3.dmg", "appcast-3.xml"):
            with self.subTest(name=name):
                path = self.staging / name
                path.write_text("earlier\n")
                self.assert_stopped_before(
                    self.release(
                        "--candidate-version", "3", "--staging-dir", str(self.staging)
                    ),
                    None,
                )
                self.assertEqual(path.read_text(), "earlier\n")
                path.unlink()

    def test_existing_receipt_is_refused(self):
        self.receipt.write_text("earlier\n")
        self.assert_stopped_before(self.release(), None)
        self.assertEqual(self.receipt.read_text(), "earlier\n")

    def test_non_empty_or_linked_dist_is_refused(self):
        dist = self.repo / "dist"
        dist.mkdir()
        (dist / "MonoPods.dmg").write_text("earlier\n")
        self.assert_stopped_before(self.release(), None)
        shutil.rmtree(dist)
        dist.symlink_to(self.root)
        self.assert_stopped_before(self.release(), None)
        dist.unlink()
        dist.mkdir()
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_invalid_environment_is_refused(self):
        cases = [
            ("MONOPODS_SPARKLE_ACCOUNT", None),
            ("MONOPODS_SPARKLE_ACCOUNT", ""),
            ("MONOPODS_SPARKLE_ACCOUNT", "mono pods"),
            ("MONOPODS_SPARKLE_ACCOUNT", "a/b"),
            ("MONOPODS_SPARKLE_ACCOUNT", "x" * 65),
            ("MONOPODS_RECEIPT", None),
            ("MONOPODS_RECEIPT", ""),
            ("MONOPODS_RECEIPT", "receipt.json"),
            ("MONOPODS_RECEIPT", str(self.receipts) + "/../receipts/release.json"),
            ("MONOPODS_RECEIPT", str(self.repo / "receipt.json")),
            ("MONOPODS_RECEIPT", str(self.repo / "dist/receipt.json")),
            ("MONOPODS_RECEIPT", str(self.root / "absent/receipt.json")),
        ]
        for name, value in cases:
            with self.subTest(name=name, value=value):
                environment = dict(self.environment)
                if value is None:
                    del self.environment[name]
                else:
                    self.environment[name] = value
                self.assert_stopped_before(self.release(), None, 64)
                self.environment = environment

    def test_unknown_or_repeated_arguments_are_refused(self):
        for arguments in (
            ("--ad-hoc-candidate",),
            ("--sign-identity", "x"),
            ("extra",),
            ("--first-release", "--first-release"),
            ("--candidate-version",),
            (
                "--candidate-version",
                "3",
                "--candidate-version",
                "4",
                "--staging-dir",
                str(self.staging),
            ),
            (
                "--candidate-version",
                "3",
                "--staging-dir",
                str(self.staging),
                "--staging-dir",
                str(self.staging),
            ),
        ):
            with self.subTest(arguments=arguments):
                self.assert_stopped_before(self.release(*arguments), None, 64)

    def test_each_failing_step_stops_the_release_before_the_next(self):
        cases = (
            ("FIXTURE_CHECK_EXIT", "bundle.sh"),
            ("FIXTURE_ADHOC_EXIT", "dmg.sh"),
            ("FIXTURE_MANIFEST_EXIT", "dmg.sh"),
            ("FIXTURE_VERIFY_EXIT", "curl"),
            ("FIXTURE_APPCAST_EXIT", "release-receipt.py"),
            ("FIXTURE_RECEIPT_EXIT", "artifact-scan.py"),
            ("FIXTURE_SCAN_EXIT", None),
        )
        for variable, following in cases:
            with self.subTest(variable=variable):
                shutil.rmtree(self.repo / "dist", ignore_errors=True)
                self.log.write_text("")
                self.environment[variable] = "1"
                result = self.release()
                del self.environment[variable]
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("___RELEASE_END", result.stdout)
                if following is not None:
                    self.assertNotIn(following, self.names())

    def test_empty_signature_stops_before_the_feed(self):
        self.environment["FIXTURE_SIGNATURE"] = ""
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("appcast.py", self.names())

    def test_no_apple_signing_or_notarization_tools_are_used(self):
        for arguments in (
            (),
            ("--candidate-version", "3", "--staging-dir", str(self.staging)),
        ):
            with self.subTest(arguments=arguments):
                shutil.rmtree(self.repo / "dist", ignore_errors=True)
                self.receipt.unlink(missing_ok=True)
                self.log.write_text("")
                self.assertEqual(self.release(*arguments).returncode, 0)
                for call in self.calls():
                    self.assertNotIn(
                        call[0], ("notarytool", "stapler", "spctl", "xcrun")
                    )
                    if call[0] == "codesign" and "--sign" in call:
                        self.assertEqual(call[call.index("--sign") + 1], "-")
        text = (SCRIPTS / "release.sh").read_text()
        for word in (
            "notarytool",
            "stapler",
            "spctl",
            "codesign",
            "IDENTITY",
            "PROFILE",
        ):
            self.assertNotIn(word, text)

    def test_output_never_carries_the_private_key_account_listing(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(
            "-x",
            [
                word
                for call in self.calls()
                if call[0] == "generate_keys"
                for word in call
            ],
        )


class ReleaseDocumentTests(unittest.TestCase):
    def test_check_parses_every_shell_script(self):
        line = next(
            line
            for line in (SCRIPTS / "check.sh").read_text().splitlines()
            if line.startswith("bash -n ")
        )
        checked = set(line.split()[2:])
        self.assertEqual(
            checked, {f"scripts/{path.name}" for path in SCRIPTS.glob("*.sh")}
        )

    def test_releasing_guide_lists_the_steps_and_the_signing_mode(self):
        text = (SCRIPTS.parent / "docs/RELEASING.md").read_text()
        self.assertIn("Release builds are signed ad hoc and are not notarized.", text)
        for step in range(1, 12):
            self.assertRegex(text, rf"(?m)^\d+\. \*\*R{step}\*\*")
        for name in (
            "MONOPODS_SPARKLE_ACCOUNT",
            "MONOPODS_RECEIPT",
            "--first-release",
            "--candidate-version",
            "--staging-dir",
            "CFBundleVersion",
        ):
            self.assertIn(name, text)
        self.assertIsNone(re.search(r"/Users/|~/", text))

    def test_no_apple_signing_identity_in_release_material(self):
        pattern = re.compile(
            r"notarytool|stapler|MONOPODS_SIGN_IDENTITY|MONOPODS_NOTARY_PROFILE|"
            r"Developer ID Application"
        )
        root = SCRIPTS.parent
        for folder in ("scripts", "docs", "Resources"):
            for path in sorted((root / folder).rglob("*")):
                if "tests" in path.relative_to(root).parts or not path.is_file():
                    continue
                with self.subTest(path=path.relative_to(root)):
                    self.assertIsNone(
                        pattern.search(path.read_bytes().decode("utf-8", "replace"))
                    )


if __name__ == "__main__":
    unittest.main()
