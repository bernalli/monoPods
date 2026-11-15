"""Developer ID signature inspection, exercised against a fake codesign with prepared output."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ITEMS = (
    "",
    "Contents/Frameworks/Sparkle.framework",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
)
NAME = "Example Developer"
TEAM = "ABCDE12345"
LEAF = f"Authority=Developer ID Application: {NAME} ({TEAM})"
AUTHORITIES = [
    LEAF,
    "Authority=Developer ID Certification Authority",
    "Authority=Apple Root CA",
]
DIRECTORY = "CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded"
# The format of `codesign --display --verbose=2` on a Developer ID bundle; the last line is
# required, so every truncation at a line boundary removes a required line.
VALID = [
    "Executable=/fixture/MonoPods",
    "Identifier=io.github.bernalli.monopods",
    "Format=app bundle with Mach-O thin (arm64)",
    DIRECTORY,
    "Hash type=sha256 size=32",
    "Signature size=9000",
    *AUTHORITIES,
    "Timestamp=15 Nov 2026 at 12:00:00",
    "Info.plist entries=14",
    "Runtime Version=27.0.0",
    "Sealed Resources version=2 rules=13 files=9",
    f"TeamIdentifier={TEAM}",
]
FAKE_CODESIGN = """#!{python}
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
    sys.exit(fixture['entitlementsRc'])
sys.exit(89)
"""


def replace(old, new):
    return lambda lines: [new if line == old else line for line in lines]


def drop(prefix):
    return lambda lines: [line for line in lines if not line.startswith(prefix)]


def add(*extra):
    return lambda lines: lines + list(extra)


class DeveloperIDCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "MonoPods.app"
        for relative in ITEMS[1:]:
            (self.app / relative).mkdir(parents=True)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        fake = self.tools / "codesign"
        fake.write_text(FAKE_CODESIGN.format(python=sys.executable))
        fake.chmod(0o700)
        self.fixture = self.root / "fixture.json"
        self.log = self.root / "codesign.log"
        self.outputs = [list(VALID) for _ in ITEMS]
        self.codes = [0 for _ in ITEMS]
        self.entitlements = b""
        self.entitlements_code = 0

    def path(self, index):
        return str(self.app / ITEMS[index]) if ITEMS[index] else str(self.app)

    def run_check(self, app=None, raw=None):
        items = {}
        for index in range(len(ITEMS)):
            data = (
                raw[index]
                if raw and index in raw
                else "\n".join(self.outputs[index]).encode()
            )
            items[self.path(index)] = {"stderr": data.hex(), "rc": self.codes[index]}
        self.fixture.write_text(
            json.dumps(
                {
                    "items": items,
                    "entitlements": self.entitlements.hex(),
                    "entitlementsRc": self.entitlements_code,
                }
            )
        )
        environment = dict(
            os.environ,
            PATH=str(self.tools) + os.pathsep + "/usr/bin:/bin",
            FIXTURE=str(self.fixture),
            FIXTURE_LOG=str(self.log),
            PYTHONDONTWRITEBYTECODE="1",
        )
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "developer-id-check.py"),
                str(app or self.app),
            ],
            capture_output=True,
            text=True,
            timeout=20,
            env=environment,
        )

    def assert_failed(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("passed", result.stdout + result.stderr)
        self.assertNotIn(NAME, result.stdout + result.stderr)

    def assert_mutation_fails(self, mutate):
        for index in range(len(ITEMS)):
            with self.subTest(item=index):
                self.outputs = [list(VALID) for _ in ITEMS]
                self.outputs[index] = mutate(list(VALID))
                self.assert_failed(self.run_check())

    def test_valid_output_for_four_items_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout, "Developer ID signature check passed: 4 items\n"
        )
        self.assertEqual(result.stderr, "")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(
            calls[:4], [["--display", "--verbose=2", self.path(i)] for i in range(4)]
        )
        self.assertEqual(
            calls[4], ["--display", "--entitlements", "-", "--xml", str(self.app)]
        )
        self.assertEqual(len(calls), 5)

    def test_order_of_unrelated_lines_and_symbolic_flag_names_do_not_matter(self):
        lines = [line for line in VALID if not line.startswith("Authority=")]
        self.outputs = [
            AUTHORITIES + list(reversed(lines)) + ["Identifier=extra"] for _ in ITEMS
        ]
        self.assertEqual(self.run_check().returncode, 0)
        self.outputs = [
            replace(DIRECTORY, DIRECTORY.replace("0x10000(runtime)", "0x10000"))(VALID)
            for _ in ITEMS
        ]
        self.assertEqual(self.run_check().returncode, 0)

    def test_missing_code_directory_fails(self):
        self.assert_mutation_fails(drop("CodeDirectory "))

    def test_duplicate_code_directory_fails(self):
        self.assert_mutation_fails(add(DIRECTORY))

    def test_missing_team_identifier_fails(self):
        self.assert_mutation_fails(drop("TeamIdentifier="))

    def test_empty_team_identifier_fails(self):
        self.assert_mutation_fails(replace(f"TeamIdentifier={TEAM}", "TeamIdentifier="))

    def test_duplicate_team_identifier_with_equal_value_fails(self):
        self.assert_mutation_fails(add(f"TeamIdentifier={TEAM}"))

    def test_team_identifier_not_set_fails(self):
        self.assert_mutation_fails(
            replace(f"TeamIdentifier={TEAM}", "TeamIdentifier=not set")
        )

    def test_missing_timestamp_fails(self):
        self.assert_mutation_fails(drop("Timestamp="))

    def test_empty_timestamp_fails(self):
        self.assert_mutation_fails(
            replace("Timestamp=15 Nov 2026 at 12:00:00", "Timestamp=   ")
        )

    def test_duplicate_timestamp_with_equal_value_fails(self):
        self.assert_mutation_fails(add("Timestamp=15 Nov 2026 at 12:00:00"))

    def test_signed_time_fails(self):
        self.assert_mutation_fails(add("Signed Time=15 Nov 2026 at 12:00:00"))

    def test_adhoc_signature_line_fails(self):
        self.assert_mutation_fails(add("Signature=adhoc"))

    def test_contradictory_team_in_leaf_authority_fails(self):
        self.assert_mutation_fails(replace(LEAF, LEAF.replace(TEAM, "ZYXWV98765")))

    def test_contradictory_team_between_items_fails(self):
        other = "ZYXWV98765"
        self.assert_mutation_fails(
            lambda lines: [
                line.replace(TEAM, other)
                if line.startswith(
                    ("Authority=Developer ID Application:", "TeamIdentifier=")
                )
                else line
                for line in lines
            ]
        )

    def test_malformed_team_fails(self):
        for team in ("ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE-1234"):
            with self.subTest(team=team):
                self.assert_mutation_fails(
                    lambda lines, team=team: [
                        line.replace(TEAM, team) for line in lines
                    ]
                )

    def test_empty_developer_name_fails(self):
        self.assert_mutation_fails(
            replace(LEAF, f"Authority=Developer ID Application:  ({TEAM})")
        )

    def test_extra_authority_fails(self):
        self.assert_mutation_fails(
            lambda lines: [
                *lines[: lines.index(AUTHORITIES[2]) + 1],
                "Authority=Apple Root CA - G2",
                *lines[lines.index(AUTHORITIES[2]) + 1 :],
            ]
        )

    def test_duplicate_authority_with_equal_value_fails(self):
        self.assert_mutation_fails(add(AUTHORITIES[2]))

    def test_incomplete_authorities_fail(self):
        for missing in AUTHORITIES:
            with self.subTest(missing=missing[:30]):
                self.assert_mutation_fails(
                    lambda lines, missing=missing: [
                        line for line in lines if line != missing
                    ]
                )

    def test_reordered_authorities_fail(self):
        def swap(lines):
            first, second = lines.index(AUTHORITIES[0]), lines.index(AUTHORITIES[1])
            lines[first], lines[second] = lines[second], lines[first]
            return lines

        self.assert_mutation_fails(swap)

    def test_other_leaf_certificate_fails(self):
        self.assert_mutation_fails(
            replace(LEAF, f"Authority=Apple Development: {NAME} ({TEAM})")
        )

    def test_flags_only_in_executable_line_fails(self):
        self.assert_mutation_fails(
            lambda lines: [
                DIRECTORY.replace(" flags=0x10000(runtime)", "")
                if line == DIRECTORY
                else "Executable=/fixture/MonoPods flags=0x10000(runtime)"
                if line.startswith("Executable=")
                else line
                for line in lines
            ]
        )

    def test_flags_only_in_a_foreign_field_fails(self):
        self.assert_mutation_fails(
            lambda lines: (
                [
                    DIRECTORY.replace(" flags=0x10000(runtime)", "")
                    if line == DIRECTORY
                    else line
                    for line in lines
                ]
                + ["Format=flags=0x10000(runtime)"]
            )
        )

    def test_duplicate_flags_in_code_directory_fails(self):
        self.assert_mutation_fails(
            replace(DIRECTORY, DIRECTORY + " flags=0x10000(runtime)")
        )

    def test_runtime_name_without_runtime_bit_fails(self):
        self.assert_mutation_fails(
            replace(DIRECTORY, DIRECTORY.replace("0x10000(runtime)", "0x0(runtime)"))
        )

    def test_adhoc_bit_fails(self):
        self.assert_mutation_fails(
            replace(
                DIRECTORY,
                DIRECTORY.replace("0x10000(runtime)", "0x10002(adhoc,runtime)"),
            )
        )

    def test_non_hexadecimal_flags_fail(self):
        for value in (
            "0x(runtime)",
            "0xz10000(runtime)",
            "65536(runtime)",
            "0x10000runtime",
        ):
            with self.subTest(value=value):
                self.assert_mutation_fails(
                    replace(DIRECTORY, DIRECTORY.replace("0x10000(runtime)", value))
                )

    def test_truncated_output_fails(self):
        for index in range(len(ITEMS)):
            for end in range(len(VALID)):
                with self.subTest(item=index, end=end):
                    self.assert_failed(
                        self.run_check(raw={index: "\n".join(VALID[:end]).encode()})
                    )
            with self.subTest(item=index, case="mid-line"):
                text = "\n".join(VALID)
                self.assert_failed(
                    self.run_check(
                        raw={index: text[: text.index(f"({TEAM})") + 4].encode()}
                    )
                )

    def test_invalid_utf8_fails(self):
        for index in range(len(ITEMS)):
            with self.subTest(item=index):
                self.assert_failed(
                    self.run_check(raw={index: "\n".join(VALID).encode() + b"\xff"})
                )

    def test_non_zero_codesign_exit_fails(self):
        for index in range(len(ITEMS)):
            with self.subTest(item=index):
                self.codes = [0 for _ in ITEMS]
                self.codes[index] = 1
                self.assert_failed(self.run_check())

    def test_entitlements_must_be_empty(self):
        for data, code in (
            (plistlib.dumps({}), 0),
            (b"", 0),
            (plistlib.dumps({"com.apple.security.get-task-allow": True}), 1),
            (plistlib.dumps({"com.apple.security.device.bluetooth": True}), 1),
            (b'<?xml version="1.0"?><plist><dict><key>x', 1),
            (b"not a plist", 1),
            (plistlib.dumps(["x"]), 1),
        ):
            with self.subTest(data=data[:40]):
                self.entitlements = data
                self.assertEqual(self.run_check().returncode, code)

    def test_entitlements_display_failure_fails(self):
        self.entitlements_code = 1
        self.assert_failed(self.run_check())

    def test_unsafe_bundle_paths_fail_before_codesign(self):
        link = self.root / "Linked.app"
        link.symlink_to(self.app)
        plain = self.root / "Plain.app"
        plain.write_text("file")
        other = self.root / "MonoPods"
        other.mkdir()
        for app in (link, plain, other, self.root / "Missing.app"):
            with self.subTest(app=app.name):
                self.assert_failed(self.run_check(app=app))
                self.assertFalse(self.log.exists())

    def test_missing_or_linked_item_fails_before_codesign(self):
        for index in range(1, len(ITEMS)):
            item = self.app / ITEMS[index]
            target = self.root / f"target-{index}"
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
        self.outputs[2] = [
            line.replace(TEAM, "ZYXWV98765")
            if line.startswith("TeamIdentifier=")
            else line
            for line in VALID
        ] + ["Identifier=secret-marker"]
        result = self.run_check()
        self.assert_failed(result)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Developer ID signature check failed: item 2\n")

    def test_foreign_diagnostic_fields_cannot_satisfy_required_fields(self):
        self.assert_mutation_fails(
            lambda lines: (
                [
                    line
                    for line in lines
                    if not line.startswith(("TeamIdentifier=", "Timestamp="))
                ]
                + [
                    f"Identifier=x TeamIdentifier={TEAM}",
                    " Timestamp=15 Nov 2026 at 12:00:00",
                ]
            )
        )


if __name__ == "__main__":
    unittest.main()
