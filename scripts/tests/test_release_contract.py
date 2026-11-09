"""Closed receipts and recomputed identities of temporary release artifacts."""

import copy
import json
import runpy
import unittest
from pathlib import Path

import test_release

API = runpy.run_path(str(Path(__file__).resolve().parents[1] / "release_contract.py"))


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_release.ReleaseTests("runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.release_info()
        self.feed = self.fixture.release_feed()
        result = self.fixture.receipt_command(appcast=self.feed)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.receipt = API["loads"](API["read"](self.fixture.output))

    def verify(self):
        API["verify_artifacts"](
            self.receipt, self.fixture.bundle, self.fixture.dmg, self.feed
        )

    def test_valid_receipt_recomputes_all_artifacts(self):
        self.verify()

    def test_each_substituted_artifact_is_refused(self):
        for path in (
            self.fixture.dmg,
            self.feed,
            self.fixture.bundle / "Contents/Info.plist",
            self.fixture.manifest,
            self.fixture.bundle / "Contents/MacOS/MonoPods",
        ):
            original = path.read_bytes()
            with self.subTest(path=path.name):
                path.write_bytes(original + b"substitution")
                with self.assertRaises(ValueError):
                    self.verify()
                path.write_bytes(original)

    def test_added_resource_changes_bundle_identity(self):
        (self.fixture.bundle / "Contents/Resources/extra").write_bytes(b"new")
        with self.assertRaises(ValueError):
            self.verify()

    def test_linked_receipt_and_artifacts_are_refused(self):
        link = self.fixture.root / "linked"
        link.symlink_to(self.fixture.output)
        with self.assertRaises(ValueError):
            API["read"](link)
        self.fixture.dmg.unlink()
        self.fixture.dmg.symlink_to(self.feed)
        with self.assertRaises(ValueError):
            self.verify()

    def test_receipt_schema_rejects_missing_extra_and_wrong_types(self):
        cases = [
            dict(self.receipt, v=True),
            dict(self.receipt, v=1.0),
            dict(self.receipt, extra="field"),
            dict(self.receipt, createdUTC="not a date"),
        ]
        for name in self.receipt:
            value = copy.deepcopy(self.receipt)
            del value[name]
            cases.append(value)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                API["validate"](value)

    def test_reader_rejects_duplicates_encoding_size_and_every_truncation(self):
        data = json.dumps(self.receipt).encode()
        bad = [
            data[:-1] + b',"v":1}',
            data.replace(b'"swift":', b'"swift":"x","swift":'),
            b" " * 65536 + data,
            b"\xff",
            b'{"x":NaN}',
            b"[" * 2000 + b"]" * 2000,
        ]
        bad += [data[:length] for length in range(len(data))]
        for value in bad:
            with self.subTest(length=len(value)), self.assertRaises(ValueError):
                API["validate"](API["loads"](value))

    def test_producer_refuses_unbounded_toolchain_without_output(self):
        self.fixture.output.unlink()
        self.fixture.command("swift", "python3 -c \"print('x' * 4097)\"")
        result = self.fixture.receipt_command(appcast=self.feed)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.fixture.output.exists())
