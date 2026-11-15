"""Release flow scripts, exercised only with stand-in tools in temporary folders."""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
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


# The scripts under test keep a minimal environment, so the stand-ins read their settings from
# fixture.env, found in a parent folder, and record the names of the variables they received.
FIXTURE_PREAMBLE = (
    "#!/bin/bash\nset -eu\n"
    "received=$(compgen -e); received=${received//$'\\n'/ }\n"
    'folder=$(cd "${0%/*}" && pwd)\n'
    'while [ ! -f "$folder/fixture.env" ] && [ -n "$folder" ]; do folder=${folder%/*}; done\n'
    'set -a; . "$folder/fixture.env"; set +a\n'
    'printf "%s: %s\\n" "${0##*/}" "$received" >> "$FIXTURE_ENV_LOG"\n'
)
# Variables every child may receive: the minimal list, and those the shell or the system add
# by themselves (bash exports PWD, SHLVL, _ and, after cd, OLDPWD; macOS adds the text encoding
# and, through the xcrun shim of /usr/bin/python3, the developer paths).
MINIMAL = {"HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "DEVELOPER_DIR"}
GENERATED = {"PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING", "CPATH", "LIBRARY_PATH", "MANPATH",
             "SDKROOT"}
SECRETS = {
    "MONOPODS_FIXTURE_TOKEN": "fake-secret-value-1",
    "ZZ_ARBITRARY_FIXTURE_NAME": "fake-secret-value-2",
    "GH_TOKEN": "fake-secret-value-3",
    "A-B": "fake-secret-value-4",
}


def write_tool(path, body):
    """A stand-in command that records its own name, its arguments and its variable names."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        FIXTURE_PREAMBLE +
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
        self.environment_log = self.root / "environment.log"
        self.environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "MONOPODS_", "FIXTURE_"))
        }
        self.environment.update(
            PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            PYTHONDONTWRITEBYTECODE="1",
            FIXTURE_LOG=str(self.log),
            FIXTURE_ENV_LOG=str(self.environment_log),
        )

    def calls(self):
        return [line.split(" ") for line in self.log.read_text().splitlines()]

    def names(self):
        return [call[0] for call in self.calls()]

    def write_fixture(self):
        """The FIXTURE_ settings of this run, for stand-ins that do not inherit them."""
        settings = {
            key: value for key, value in self.environment.items() if key.startswith("FIXTURE_")
        }
        (self.root / "fixture.env").write_text(
            "".join(f"{key}={shlex.quote(value)}\n" for key, value in sorted(settings.items()))
        )
        (self.root / "fixture.json").write_text(json.dumps(settings))

    def received(self):
        """The variable names each stand-in received, in call order."""
        if not self.environment_log.exists():
            return []
        return [
            (line.split(": ", 1)[0], set(line.split(": ", 1)[1].split()))
            for line in self.environment_log.read_text().splitlines()
        ]

    def run_script(self, name, *arguments):
        self.write_fixture()
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
    "security",
    "notarytool",
    "sparkle-tools.sh",
    "generate_keys",
    "check.sh",
    "bundle.sh",
    "developer-id-check.py",
    "manifest.py",
    "dmg.sh",
    "codesign",
    "codesign",
    "notarytool",
    "stapler",
    "stapler",
    "spctl",
    "spctl",
    "sign_update",
    "sign_update",
)
SHA1 = "0123456789ABCDEF0123456789ABCDEF01234567"
SUBMISSION = "2f8c3a1e-5b6d-4e7f-8a9b-0c1d2e3f4a5b"
FAKE_NAME = "Example Developer"
LISTING_LINE = f'  1) {SHA1} "Developer ID Application: {FAKE_NAME} (ABCDE12345)"'
LISTING = (
    f'  1) {"F" * 40} "Apple Development: {FAKE_NAME} (ZYXWV98765)"\n'
    f"{LISTING_LINE.replace('  1)', '  2)')}\n"
    "     2 valid identities found\n"
)
ACCEPTED = json.dumps(
    {"id": SUBMISSION, "status": "Accepted", "message": "Successfully received submission info"}
)
SPCTL_DMG = (
    "dist/MonoPods.dmg: accepted\nsource=Notarized Developer ID\n"
    f"origin=Developer ID Application: {FAKE_NAME} (ABCDE12345)\n"
)
SPCTL_APP = SPCTL_DMG.replace("MonoPods.dmg", "MonoPods.app")


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
            'printf "%s\\n" "${MONOPODS_SIGNING_IDENTITY:-}" > "$FIXTURE_IDENTITY_SEEN"\n'
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
            ("developer-id-check.py", "FIXTURE_DEVELOPER_ID_EXIT"),
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
        self.signing_tools()
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
            FIXTURE_IDENTITY_SEEN=str(self.root / "identity-seen"),
            FIXTURE_IDENTITIES=LISTING,
            FIXTURE_SUBMIT_STDOUT=ACCEPTED,
            FIXTURE_SPCTL_DMG=SPCTL_DMG,
            FIXTURE_SPCTL_APP=SPCTL_APP,
            FIXTURE_SPCTL_COUNT=str(self.root / "spctl-count"),
        )

    def signing_tools(self):
        """Stand-ins for the keychain, notary, stapler and Gatekeeper tools."""
        write_tool(
            self.tools / "security",
            '[ "$*" = "find-identity -v -p codesigning" ] || exit 89\n'
            'printf "%s" "$FIXTURE_IDENTITIES"\n'
            'exit "${FIXTURE_SECURITY_EXIT:-0}"',
        )
        # xcrun forwards to the stand-in without logging itself, so the log names the tool.
        xcrun = self.tools / "xcrun"
        xcrun.write_text(
            '#!/bin/bash\ncase "$1" in notarytool|stapler) ;; *) exit 89;; esac\n'
            'exec "$(dirname "$0")/$1" "${@:2}"\n'
        )
        xcrun.chmod(0o700)
        write_tool(
            self.tools / "notarytool",
            'if [ "$*" = "history --keychain-profile notary" ]; then\n'
            '  printf "history-marker\\n"; printf "history-marker\\n" >&2\n'
            '  exit "${FIXTURE_HISTORY_EXIT:-0}"\nfi\n'
            '[ "$*" = "submit dist/MonoPods.dmg --keychain-profile notary --wait --timeout 30m '
            '--output-format json" ] || exit 89\n'
            '[ "${FIXTURE_SUBMIT_INTERRUPT:-no}" = yes ] && kill -INT $$\n'
            'if [ -n "${FIXTURE_SUBMIT_HEX:-}" ]; then printf "%s" "$FIXTURE_SUBMIT_HEX" | xxd -r -p\n'
            'else printf "%s" "$FIXTURE_SUBMIT_STDOUT"; fi\n'
            'printf "stderr-marker\\n" >&2\n'
            'exit "${FIXTURE_SUBMIT_EXIT:-0}"',
        )
        write_tool(
            self.tools / "stapler",
            'case "$*" in\n'
            '  "staple dist/MonoPods.dmg") exit "${FIXTURE_STAPLE_EXIT:-0}";;\n'
            '  "validate dist/MonoPods.dmg") exit "${FIXTURE_VALIDATE_EXIT:-0}";;\n'
            "  *) exit 89;;\nesac",
        )
        write_tool(
            self.tools / "spctl",
            'if [ "$*" = "-a -vv -t open --context context:primary-signature dist/MonoPods.dmg" ]; then\n'
            '  printf "%s" "$FIXTURE_SPCTL_DMG" >&2; exit "${FIXTURE_SPCTL_DMG_EXIT:-0}"\nfi\n'
            '[ "$*" = "-a -vv dist/MonoPods.app" ] || exit 89\n'
            'count=$(cat "$FIXTURE_SPCTL_COUNT" 2>/dev/null || echo 0); count=$((count + 1))\n'
            'printf "%s\\n" "$count" > "$FIXTURE_SPCTL_COUNT"\n'
            'if [ "$count" -le "${FIXTURE_SPCTL_APP_FAILS:-0}" ]; then\n'
            '  printf "dist/MonoPods.app: rejected\\nsource=Unnotarized Developer ID\\n" >&2; exit 3\nfi\n'
            'printf "%s" "$FIXTURE_SPCTL_APP" >&2; exit "${FIXTURE_SPCTL_APP_EXIT:-0}"',
        )
        write_tool(
            self.tools / "codesign",
            'case "$*" in\n'
            f'  "--force --timestamp --sign {SHA1} dist/MonoPods.dmg")'
            ' exit "${FIXTURE_DMG_SIGN_EXIT:-0}";;\n'
            '  "--verify --strict dist/MonoPods.dmg") exit "${FIXTURE_DMG_VERIFY_EXIT:-0}";;\n'
            "  *) exit 89;;\nesac",
        )
        write_tool(self.tools / "sleep", '[ "$*" = 15 ] || exit 89')

    def python_tool(self, name, variable):
        path = self.repo / "scripts" / name
        path.write_text(
            "import json, os, sys\n"
            f"fixture = json.load(open({str(self.root / 'fixture.json')!r}))\n"
            'with open(fixture["FIXTURE_ENV_LOG"], "a") as log:\n'
            f'    log.write("{name}: " + " ".join(sorted(os.environ)) + "\\n")\n'
            'with open(fixture["FIXTURE_LOG"], "a") as log:\n'
            f'    log.write(" ".join(["{name}", *sys.argv[1:]]) + "\\n")\n'
            "arguments = sys.argv[1:]\n"
            'if "--output" in arguments:\n'
            '    open(arguments[arguments.index("--output") + 1], "x").write("feed\\n")\n'
            f'sys.exit(int(fixture.get("{variable}", "0")))\n'
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
        self.assertEqual(calls[0], ["security", "find-identity", "-v", "-p", "codesigning"])
        self.assertEqual(calls[1], ["notarytool", "history", "--keychain-profile", "notary"])
        self.assertEqual(calls[3], ["generate_keys", "--account", ACCOUNT, "-p"])
        self.assertEqual(
            calls[5], ["bundle.sh", "--update-channel", "Resources/UpdateChannel.json"]
        )
        self.assertEqual(calls[6], ["developer-id-check.py", "dist/MonoPods.app"])
        self.assertEqual(calls[7], ["manifest.py", "verify", "dist/MonoPods.app"])
        self.assertEqual(
            calls[9],
            ["codesign", "--force", "--timestamp", "--sign", SHA1, "dist/MonoPods.dmg"],
        )
        self.assertEqual(calls[10], ["codesign", "--verify", "--strict", "dist/MonoPods.dmg"])
        self.assertEqual(
            calls[11],
            [
                "notarytool",
                "submit",
                "dist/MonoPods.dmg",
                "--keychain-profile",
                "notary",
                "--wait",
                "--timeout",
                "30m",
                "--output-format",
                "json",
            ],
        )
        self.assertEqual(calls[12], ["stapler", "staple", "dist/MonoPods.dmg"])
        self.assertEqual(calls[13], ["stapler", "validate", "dist/MonoPods.dmg"])
        self.assertEqual(
            calls[14],
            [
                "spctl",
                "-a",
                "-vv",
                "-t",
                "open",
                "--context",
                "context:primary-signature",
                "dist/MonoPods.dmg",
            ],
        )
        self.assertEqual(calls[15], ["spctl", "-a", "-vv", "dist/MonoPods.app"])
        self.assertEqual(
            calls[16], ["sign_update", "--account", ACCOUNT, "-p", "dist/MonoPods.dmg"]
        )
        self.assertEqual(
            calls[17],
            [
                "sign_update",
                "--account",
                ACCOUNT,
                "--verify",
                "dist/MonoPods.dmg",
                SIGNATURE,
            ],
        )
        self.assertIn(FEED, calls[18])
        self.assertEqual(
            calls[18][calls[18].index("-o") + 1], "dist/previous-appcast.xml"
        )
        build = calls[19]
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
            calls[20],
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
            calls[21],
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
            calls[22],
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
        self.assertIn("Developer ID identity 01234567\u2026\n", result.stdout)
        self.assertEqual((self.root / "identity-seen").read_text(), SHA1 + "\n")
        for marker in (FAKE_NAME, SHA1, "history-marker", "stderr-marker", "origin="):
            self.assertNotIn(marker, result.stdout + result.stderr)

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
            calls[5],
            [
                "bundle.sh",
                "--update-channel",
                "Resources/UpdateChannel.json",
                "--candidate-version",
                "3",
            ],
        )
        self.assertEqual(calls[18], ["ditto", "dist/MonoPods.dmg", image])
        build = calls[19]
        self.assertEqual(build[:3], ["appcast.py", "build", "--candidate"])
        self.assertEqual(build[build.index("--dmg") + 1], image)
        self.assertEqual(build[build.index("--download-url") + 1], "file://" + image)
        self.assertEqual(build[build.index("--output") + 1], feed)
        self.assertEqual(
            calls[20],
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
            calls[21],
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
            ("FIXTURE_DEVELOPER_ID_EXIT", "dmg.sh"),
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

    def assert_stopped_without_release(self, result, message=None):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("___RELEASE_END", result.stdout)
        self.assertNotIn("sign_update", self.names())
        if message is not None:
            self.assertIn("STOP: " + message + "\n", result.stderr)
        for marker in (FAKE_NAME, "history-marker", "stderr-marker", "origin="):
            self.assertNotIn(marker, result.stdout + result.stderr)

    def assert_stopped_before_build(self, result, message):
        self.assert_stopped_without_release(result, message)
        self.assertNotIn("sparkle-tools.sh", self.names())
        self.assertNotIn("bundle.sh", self.names())

    def test_no_identity_stops_before_any_build(self):
        self.environment["FIXTURE_IDENTITIES"] = LISTING.splitlines()[0] + "\n     1 valid identities found\n"
        self.assert_stopped_before_build(
            self.release(),
            "no Developer ID Application certificate in the keychain: "
            "create it in Xcode, Settings, Accounts, Manage Certificates",
        )

    def test_two_identities_stop_before_any_build(self):
        other = LISTING_LINE.replace("  1)", "  3)").replace(SHA1, "A" * 40)
        self.environment["FIXTURE_IDENTITIES"] = LISTING + other + "\n"
        self.assert_stopped_before_build(
            self.release(),
            "more than one Developer ID Application certificate: keep one in the keychain",
        )

    def test_unreadable_listing_stops_before_any_build(self):
        for listing, code in (
            (LISTING.replace(SHA1, SHA1[:39]), "0"),
            (LISTING.replace(SHA1, SHA1.lower()), "0"),
            (LISTING.replace('(ABCDE12345)"', '(ABCDE12345)'), "0"),
            (LISTING.replace("Application: " + FAKE_NAME, "Application: "), "0"),
            (LISTING, "1"),
        ):
            with self.subTest(listing=listing[-60:], code=code):
                self.log.write_text("")
                self.environment.update(FIXTURE_IDENTITIES=listing, FIXTURE_SECURITY_EXIT=code)
                self.assert_stopped_before_build(self.release(), "unreadable certificate list")

    def test_failed_notary_preflight_stops_before_any_build(self):
        self.environment["FIXTURE_HISTORY_EXIT"] = "1"
        self.assert_stopped_before_build(self.release(), "notary preflight failed")

    def submit(self, stdout=None, code="0", raw=None):
        """Run a release whose submission answers with stdout (or raw bytes) and code."""
        shutil.rmtree(self.repo / "dist", ignore_errors=True)
        self.log.write_text("")
        if raw is not None:
            self.environment["FIXTURE_SUBMIT_HEX"] = raw.hex()
        else:
            self.environment.pop("FIXTURE_SUBMIT_HEX", None)
            self.environment["FIXTURE_SUBMIT_STDOUT"] = stdout
        self.environment["FIXTURE_SUBMIT_EXIT"] = code
        return self.release()

    def assert_submission_refused(self, result):
        self.assert_stopped_without_release(result, "notarization did not succeed")
        self.assertNotIn("stapler", self.names())
        self.assertEqual(self.names()[-1], "notarytool")
        # The image and its digest stay for the reconciliation of the submission.
        image = self.repo / "dist/MonoPods.dmg"
        self.assertTrue(image.is_file())
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        self.assertIn(f"dist/MonoPods.dmg sha256 {digest}", result.stderr)

    def assert_refused_with_id(self, result):
        self.assert_submission_refused(result)
        self.assertIn(
            f"xcrun notarytool log {SUBMISSION} --keychain-profile notary", result.stderr
        )

    def assert_refused_without_id(self, result):
        self.assert_submission_refused(result)
        self.assertIn("notarization returned no valid submission id", result.stderr)
        self.assertNotIn("notarytool log", result.stderr)

    def document(self, **fields):
        value = {"id": SUBMISSION, "status": "Accepted"}
        value.update(fields)
        return json.dumps({key: item for key, item in value.items() if item is not ...})

    def test_invalid_rejected_and_in_progress_statuses_stop_before_stapler(self):
        for status in ("Invalid", "Rejected", "In Progress"):
            with self.subTest(status=status):
                self.assert_refused_with_id(self.submit(self.document(status=status)))

    def test_unknown_statuses_stop_before_stapler(self):
        for status in ("accepted", "Accepted ", "Success", ""):
            with self.subTest(status=status):
                self.assert_refused_with_id(self.submit(self.document(status=status)))

    def test_status_of_the_wrong_type_stops_before_stapler(self):
        for status in (..., None, True, 1, ["Accepted"], {"status": "Accepted"}):
            with self.subTest(status=status):
                self.assert_refused_with_id(self.submit(self.document(status=status)))

    def test_missing_or_malformed_id_stops_without_a_diagnostic_command(self):
        for submission in (
            ...,
            "",
            None,
            True,
            7,
            [SUBMISSION],
            {"id": SUBMISSION},
            SUBMISSION[:-1],
            SUBMISSION.replace("-", ""),
            SUBMISSION + "0",
            SUBMISSION.replace("2f8c", "2g8c"),
            "x" + SUBMISSION[1:],
            "{" + SUBMISSION + "}",
        ):
            with self.subTest(submission=submission):
                self.assert_refused_without_id(self.submit(self.document(id=submission)))

    def test_duplicate_keys_stop_before_stapler(self):
        accepted = f'"id": "{SUBMISSION}", "status": "Accepted"'
        for text in (
            "{" + accepted + ', "id": "' + SUBMISSION + '"}',
            "{" + accepted + ', "id": "' + SUBMISSION.replace("2f8c", "3f8c") + '"}',
            '{"id": "' + SUBMISSION.replace("2f8c", "3f8c") + '", ' + accepted + "}",
            "{" + accepted + ', "status": "Accepted"}',
            "{" + accepted + ', "status": "Invalid"}',
            '{"status": "Invalid", ' + accepted + "}",
            "{" + accepted + ', "detail": {"a": 1, "a": 1}}',
        ):
            with self.subTest(text=text):
                self.assert_refused_without_id(self.submit(text))

    def test_malformed_documents_stop_without_repeating_the_answer(self):
        accepted = self.document(message="answer-marker")
        for text in (
            "",
            "answer-marker",
            accepted[:-1],
            accepted + accepted,
            accepted + "\nanswer-marker",
            "[" + accepted + "]",
            json.dumps({"response": json.loads(self.document())}) [:-1] + ', "answer": "answer-marker"}',
            accepted[:-1] + ', "size": NaN}',
            accepted[:-1] + ', "size": Infinity}',
            accepted[:-1] + ', "size": -Infinity}',
        ):
            with self.subTest(text=text[:50]):
                result = self.submit(text)
                self.assert_refused_without_id(result)
                self.assertNotIn("answer-marker", result.stdout + result.stderr)

    def test_non_utf8_answer_stops_before_stapler(self):
        self.assert_refused_without_id(self.submit(raw=self.document().encode() + b"\xff"))

    def test_foreign_fields_saying_accepted_do_not_count(self):
        for text in (
            self.document(status="Invalid", message="Accepted"),
            self.document(status="Invalid", Accepted=True),
            self.document(status="Invalid", detail={"status": "Accepted"}),
        ):
            with self.subTest(text=text):
                result = self.submit(text)
                self.assert_refused_with_id(result)
                self.assertNotIn("Accepted", result.stdout + result.stderr)

    def test_non_zero_exit_with_an_accepted_answer_stops(self):
        self.assert_refused_with_id(self.submit(self.document(), code="1"))

    def test_timeout_is_kept_for_reconciliation(self):
        # notarytool ends --wait --timeout with a failure and the submission still in progress.
        self.assert_refused_with_id(self.submit(self.document(status="In Progress"), code="1"))

    def test_missing_network_is_kept_for_reconciliation(self):
        self.assert_refused_without_id(self.submit("", code="1"))

    def test_interrupted_submission_is_kept_for_reconciliation(self):
        self.environment["FIXTURE_SUBMIT_INTERRUPT"] = "yes"
        result = self.submit(self.document())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("___RELEASE_END", result.stdout)
        self.assertNotIn("stapler", self.names())
        self.assertNotIn("sign_update", self.names())
        self.assertTrue((self.repo / "dist/MonoPods.dmg").is_file())

    def test_failed_disk_image_signature_stops_before_submission(self):
        for variable in ("FIXTURE_DMG_SIGN_EXIT", "FIXTURE_DMG_VERIFY_EXIT"):
            with self.subTest(variable=variable):
                shutil.rmtree(self.repo / "dist", ignore_errors=True)
                self.log.write_text("")
                self.environment[variable] = "1"
                result = self.release()
                del self.environment[variable]
                self.assert_stopped_without_release(result)
                self.assertNotIn("notarytool", self.names()[2:])

    def test_failed_stapler_stops_before_gatekeeper(self):
        # A ticket not yet available makes staple fail; the run stops, it does not wait.
        for variable in ("FIXTURE_STAPLE_EXIT", "FIXTURE_VALIDATE_EXIT"):
            with self.subTest(variable=variable):
                shutil.rmtree(self.repo / "dist", ignore_errors=True)
                self.log.write_text("")
                self.environment[variable] = "65"
                result = self.release()
                del self.environment[variable]
                self.assert_stopped_without_release(result, "stapling failed")
                self.assertNotIn("spctl", self.names())

    def gatekeeper(self, variable, text, code="0"):
        shutil.rmtree(self.repo / "dist", ignore_errors=True)
        self.log.write_text("")
        (self.root / "spctl-count").unlink(missing_ok=True)
        environment = dict(self.environment)
        self.environment[variable] = text
        self.environment[variable + "_EXIT"] = code
        result = self.release()
        self.environment = environment
        return result

    def bad_assessments(self, path):
        accepted = f"{path}: accepted\n"
        source = "source=Notarized Developer ID\n"
        return (
            f"{path}: rejected\nsource=Unnotarized Developer ID\n",
            f"{path}: rejected\n" + source,
            accepted,
            accepted + "source=Developer ID\n",
            accepted + "source=Notarized Developer ID (fixture)\n",
            accepted + source + source,
            accepted + accepted + source,
            accepted + f"{path}: rejected\n" + source,
            "other.dmg: accepted\n" + source,
            f"{path}: accepted, but rejected\n" + source,
            f"note={path}: accepted source=Notarized Developer ID\n",
            f"{path}: accepted source=Notarized Developer ID\n",
            "",
        )

    def test_disk_image_assessment_must_be_exactly_accepted_and_notarized(self):
        for text in self.bad_assessments("dist/MonoPods.dmg"):
            with self.subTest(text=text):
                result = self.gatekeeper("FIXTURE_SPCTL_DMG", text)
                self.assert_stopped_without_release(result, "Gatekeeper refused the disk image")
                self.assertNotIn(["spctl", "-a", "-vv", "dist/MonoPods.app"], self.calls())

    def test_non_zero_gatekeeper_exit_with_positive_text_stops(self):
        result = self.gatekeeper("FIXTURE_SPCTL_DMG", SPCTL_DMG, code="3")
        self.assert_stopped_without_release(result, "Gatekeeper refused the disk image")
        result = self.gatekeeper("FIXTURE_SPCTL_APP", SPCTL_APP, code="3")
        self.assert_stopped_without_release(result, "Gatekeeper refused the app")
        self.assertEqual(self.names().count("spctl"), 6)

    def test_app_assessment_must_be_exactly_accepted_and_notarized(self):
        for text in self.bad_assessments("dist/MonoPods.app"):
            with self.subTest(text=text):
                result = self.gatekeeper("FIXTURE_SPCTL_APP", text)
                self.assert_stopped_without_release(result, "Gatekeeper refused the app")

    def test_app_still_refused_after_five_attempts_stops(self):
        self.environment["FIXTURE_SPCTL_APP_FAILS"] = "5"
        result = self.release()
        self.assert_stopped_without_release(result, "Gatekeeper refused the app")
        self.assertEqual(self.names().count("spctl"), 6)
        self.assertEqual(self.names().count("sleep"), 4)

    def test_app_accepted_on_the_fifth_attempt_continues(self):
        self.environment["FIXTURE_SPCTL_APP_FAILS"] = "4"
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        names = self.names()
        self.assertEqual(names.count("spctl"), 6)
        self.assertEqual(names.count("sleep"), 4)
        self.assertLess(names.index("sleep"), names.index("sign_update"))

    def test_signing_and_notarization_come_before_the_eddsa_signature(self):
        self.assertEqual(self.release().returncode, 0)
        names = self.names()
        submit = names.index("notarytool", 2)
        self.assertLess(names.index("dmg.sh"), names.index("codesign"))
        self.assertLess(names.index("codesign"), submit)
        self.assertLess(submit, names.index("stapler"))
        self.assertLess(names.index("stapler"), names.index("spctl"))
        self.assertLess(names.index("spctl"), names.index("sign_update"))
        text = (SCRIPTS / "release.sh").read_text()
        self.assertNotIn("adhoc-check.py", text)
        self.assertNotIn("--deep", text)
        self.assertNotIn("--options", text)

    def test_every_child_receives_only_the_minimal_environment(self):
        dirname = self.tools / "dirname"
        dirname.write_text(
            FIXTURE_PREAMBLE.replace("set -eu", "set -u") + 'exec /usr/bin/dirname "$@"\n'
        )
        dirname.chmod(0o700)
        self.environment.update(SECRETS)
        self.environment["LANG"] = "en_US.UTF-8"
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        received = self.received()
        self.assertEqual(received[0][0], "dirname")
        self.assertIn("bundle.sh", [tool for tool, _ in received])
        self.assertGreater(len(received), len(STEPS))
        for tool, variables in received:
            with self.subTest(tool=tool):
                self.assertIn("LANG", variables)
                own = {"MONOPODS_SIGNING_IDENTITY"} if tool == "bundle.sh" else set()
                self.assertEqual(variables - MINIMAL - GENERATED, own)
        evidence = result.stdout + result.stderr + self.log.read_text()
        evidence += self.environment_log.read_text()
        for value in SECRETS.values():
            self.assertNotIn(value, evidence)

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
        block = 'for script in scripts/*.sh; do\n  bash -n "$script"\ndone'
        text = (SCRIPTS / "check.sh").read_text()
        self.assertIn(block, text)
        names = sorted(path.name for path in SCRIPTS.glob("*.sh"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in names:
                (scripts / name).write_text("#!/bin/bash\ntrue\n")
            for name in names:
                path = scripts / name
                path.write_text("#!/bin/bash\nif\n")
                result = subprocess.run(
                    ["/bin/bash", "-c", "set -e\n" + block],
                    cwd=root, capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0, name)
                path.write_text("#!/bin/bash\ntrue\n")

    def test_releasing_guide_lists_the_steps_and_the_signing_mode(self):
        text = (SCRIPTS.parent / "docs/RELEASING.md").read_text()
        self.assertIn(
            "Release builds are signed with a Developer ID and the hardened runtime, and the "
            "disk image is notarized and stapled.",
            text,
        )
        self.assertNotIn("signed ad hoc", text)
        for step in range(0, 12):
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
        # D17: the tools and the certificate kind may be named; a concrete identity,
        # a team identifier or a certificate digest may not.
        pattern = re.compile(
            r"MONOPODS_SIGN_IDENTITY|MONOPODS_NOTARY_PROFILE|"
            r"Developer ID Application: [^\n]*\([A-Z0-9]{10}\)|"
            r"TeamIdentifier=[A-Z0-9]{10}|(?<![0-9A-Fa-f])[0-9A-F]{40}(?![0-9A-Fa-f])"
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
