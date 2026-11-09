"""The update feed: exact output and a closed reader, on temporary bundles and images."""

import base64
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "appcast.py"
SPEC = importlib.util.spec_from_file_location("appcast", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)

SIGNATURE = base64.b64encode(bytes(range(64))).decode()
DATE = "Mon, 09 Nov 2026 10:11:12 +0000"
PRODUCTION_URL = (
    "https://github.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.dmg"
)
IMAGE = b"disk image fixture\n"


def expected(
    url,
    length,
    build="42",
    short="1.2.3",
    minimum="14.2",
    date=DATE,
    signature=SIGNATURE,
):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>MonoPods</title>\n"
        "    <item>\n"
        f"      <title>Version {short}</title>\n"
        f"      <pubDate>{date}</pubDate>\n"
        f"      <sparkle:version>{build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>\n"
        f'      <enclosure url="{url}" length="{length}" type="application/octet-stream" '
        f'sparkle:edSignature="{signature}"/>\n'
        "    </item>\n"
        "  </channel>\n"
        "</rss>\n"
    )


class AppcastFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.dist = self.root / "dist"
        self.bundle = self.dist / "MonoPods.app"
        (self.bundle / "Contents").mkdir(parents=True)
        self.write_info()
        self.dmg = self.dist / "MonoPods.dmg"
        self.dmg.write_bytes(IMAGE)
        self.staging = self.root / "staging"
        self.staging.mkdir()
        self.candidate_dmg = self.staging / "MonoPods-42.dmg"
        self.candidate_dmg.write_bytes(IMAGE)
        self.output = self.root / "appcast.xml"

    def write_info(self, **changes):
        info = {
            "CFBundleVersion": "42",
            "CFBundleShortVersionString": "1.2.3",
            "LSMinimumSystemVersion": "14.2",
            "CFBundleName": "MonoPods",
        }
        info.update(changes)
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def run_script(self, *arguments):
        return subprocess.run(
            ["python3", str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            timeout=20,
        )

    def build(
        self,
        *extra,
        url=PRODUCTION_URL,
        dmg=None,
        signature=SIGNATURE,
        date=DATE,
        output=None,
    ):
        return self.run_script(
            "build",
            "--bundle",
            str(self.bundle),
            "--dmg",
            str(dmg or self.dmg),
            "--signature",
            signature,
            "--download-url",
            url,
            "--pub-date",
            date,
            "--output",
            str(output or self.output),
            *extra,
        )

    def check(self, *extra, appcast_path=None):
        return self.run_script(
            "check", "--appcast", str(appcast_path or self.output), *extra
        )

    def with_artifacts(self, dmg=None):
        return ("--bundle", str(self.bundle), "--dmg", str(dmg or self.dmg))

    def production_text(self, **values):
        return expected(PRODUCTION_URL, len(IMAGE), **values)

    def candidate_url(self):
        return "file://" + str(self.candidate_dmg)

    def candidate_text(self, **values):
        return expected(self.candidate_url(), len(IMAGE), **values)


class BuildTests(AppcastFixture):
    def test_production_build_writes_exactly_the_normative_text(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), self.production_text().encode())

    def test_candidate_build_points_at_the_staged_image(self):
        result = self.build(
            "--candidate", url=self.candidate_url(), dmg=self.candidate_dmg
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), self.candidate_text())

    def test_build_refuses_an_existing_or_linked_output(self):
        self.output.write_text("earlier\n")
        self.assertEqual(self.build().returncode, 1)
        self.assertEqual(self.output.read_text(), "earlier\n")
        self.output.unlink()
        self.output.symlink_to(self.root / "target.xml")
        self.assertEqual(self.build().returncode, 1)
        self.assertFalse((self.root / "target.xml").exists())

    def test_build_refuses_values_that_break_the_rules_without_output(self):
        cases = [
            dict(signature=SIGNATURE[:-4]),
            dict(signature="x" * 88),
            dict(date="Mon, 9 Nov 2026 10:11:12 +0000"),
            dict(date="Tue, 09 Nov 2026 10:11:12 +0000"),
            dict(date="Mon, 09 Nov 2026 10:11:12 +0100"),
            dict(url=PRODUCTION_URL.replace("v1.2.3", "v1.2.4")),
            dict(
                url="http://github.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.dmg"
            ),
            dict(url=self.candidate_url(), dmg=self.candidate_dmg),
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertEqual(self.build(**case).returncode, 1)
                self.assertFalse(self.output.exists())

    def test_build_refuses_bundles_that_break_the_rules(self):
        for changes in (
            {"CFBundleVersion": "042"},
            {"CFBundleVersion": 42},
            {"CFBundleShortVersionString": "1.2"},
            {"LSMinimumSystemVersion": "14"},
            {"LSMinimumSystemVersion": None},
        ):
            with self.subTest(changes=changes):
                self.write_info(
                    **{
                        key: value
                        for key, value in changes.items()
                        if value is not None
                    }
                )
                if None in changes.values():
                    info = plistlib.loads(
                        (self.bundle / "Contents/Info.plist").read_bytes()
                    )
                    del info["LSMinimumSystemVersion"]
                    (self.bundle / "Contents/Info.plist").write_bytes(
                        plistlib.dumps(info)
                    )
                self.assertEqual(self.build().returncode, 1)
                self.assertFalse(self.output.exists())

    def test_build_refuses_linked_or_missing_artifacts(self):
        link = self.root / "linked.app"
        link.symlink_to(self.bundle)
        self.assertEqual(
            self.run_script(
                "build",
                "--bundle",
                str(link),
                "--dmg",
                str(self.dmg),
                "--signature",
                SIGNATURE,
                "--download-url",
                PRODUCTION_URL,
                "--pub-date",
                DATE,
                "--output",
                str(self.output),
            ).returncode,
            1,
        )
        image_link = self.root / "linked.dmg"
        image_link.symlink_to(self.dmg)
        self.assertEqual(self.build(dmg=image_link).returncode, 1)
        self.assertEqual(self.build(dmg=self.root / "absent.dmg").returncode, 1)
        self.assertFalse(self.output.exists())

    def test_usage_errors(self):
        for arguments in (
            (),
            ("build",),
            ("verify", "--appcast", "x"),
            ("check", "--appcast"),
            ("check", "--appcast", "a", "--appcast", "b"),
            ("check", "--appcast", "a", "--bundle", "b"),
            ("check", "--appcast", "a", "--dmg", "b"),
            ("check", "--appcast", "a", "--unknown", "b"),
            (
                "build",
                "--bundle",
                "a",
                "--dmg",
                "b",
                "--signature",
                "c",
                "--download-url",
                "d",
                "--pub-date",
                "e",
            ),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_script(*arguments).returncode, 64)


class CheckTests(AppcastFixture):
    def setUp(self):
        super().setUp()
        self.valid = self.production_text()

    def save(self, text, path=None):
        path = path or self.output
        if isinstance(text, str):
            text = text.encode("utf-8")
        path.write_bytes(text)
        return path

    def assert_refused(self, text, *extra, candidate=False):
        self.save(text)
        arguments = ("--candidate",) if candidate else ()
        result = self.check(*arguments, *extra)
        self.assertEqual(result.returncode, 1, (text, result.stdout, result.stderr))
        self.assertNotIn(str(self.root), result.stderr)
        with self.assertRaises(ValueError):
            appcast.parse(
                text if isinstance(text, bytes) else text.encode(), candidate=candidate
            )

    def test_check_accepts_the_build_output_with_and_without_artifacts(self):
        self.assertEqual(self.build().returncode, 0)
        self.assertEqual(self.check().returncode, 0)
        result = self.check(*self.with_artifacts())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_accepts_a_candidate_build_with_and_without_artifacts(self):
        self.assertEqual(
            self.build(
                "--candidate", url=self.candidate_url(), dmg=self.candidate_dmg
            ).returncode,
            0,
        )
        self.assertEqual(self.check("--candidate").returncode, 0)
        result = self.check("--candidate", *self.with_artifacts(self.candidate_dmg))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicated_missing_and_extra_elements_are_refused(self):
        lines = self.valid.splitlines(keepends=True)
        for index in range(2, len(lines) - 1):
            with self.subTest(index=index, change="duplicate"):
                self.assert_refused(
                    "".join(lines[: index + 1] + [lines[index]] + lines[index + 1 :])
                )
            with self.subTest(index=index, change="missing"):
                self.assert_refused("".join(lines[:index] + lines[index + 1 :]))
        for parent in ("<rss version", "  <channel>", "    <item>"):
            with self.subTest(parent=parent):
                position = self.valid.index("\n", self.valid.index(parent)) + 1
                self.assert_refused(
                    self.valid[:position] + "<link>x</link>\n" + self.valid[position:]
                )

    def test_enclosure_attributes_are_exactly_the_four(self):
        enclosure = next(
            line for line in self.valid.splitlines() if "enclosure" in line
        )
        for attribute in ("url", "length", "type", "sparkle:edSignature"):
            with self.subTest(missing=attribute):
                start = enclosure.index(" " + attribute + "=")
                end = enclosure.index('"', enclosure.index('"', start) + 1) + 1
                self.assert_refused(
                    self.valid.replace(enclosure, enclosure[:start] + enclosure[end:])
                )
        self.assert_refused(
            self.valid.replace(
                'type="application/octet-stream"',
                'type="application/octet-stream" sparkle:os="macos"',
            )
        )
        self.assert_refused(self.valid.replace(" length=", ' length="1" length='))

    def test_item_children_in_another_order_are_refused(self):
        lines = self.valid.splitlines(keepends=True)
        start = lines.index("    <item>\n") + 1
        for first in range(start, start + 5):
            with self.subTest(first=first):
                swapped = list(lines)
                swapped[first], swapped[first + 1] = swapped[first + 1], swapped[first]
                self.assert_refused("".join(swapped))

    def test_two_items_are_refused(self):
        start = self.valid.index("    <item>")
        end = self.valid.index("    </item>\n") + len("    </item>\n")
        self.assert_refused(self.valid[:end] + self.valid[start:end] + self.valid[end:])

    def test_markup_outside_the_closed_schema_is_refused(self):
        cases = [
            self.valid.replace(
                "http://www.andymatuschak.org/xml-namespaces/sparkle",
                "http://example.com/sparkle",
            ),
            self.valid.replace("xmlns:sparkle", "xmlns:sp"),
            self.valid.replace("<rss", "<!DOCTYPE rss>\n<rss"),
            self.valid.replace("<rss", '<!DOCTYPE rss [<!ENTITY e "x">]>\n<rss'),
            self.valid.replace("<title>MonoPods", "<!-- note --><title>MonoPods"),
            self.valid.replace("<rss", '<?xml-stylesheet href="x"?>\n<rss'),
            self.valid.replace("<channel>", "<channel>text"),
            self.valid.replace("</item>", "text</item>"),
            self.valid.replace("MonoPods</title>", "MonoPods&amp;</title>"),
            self.valid.replace("  <channel>", "\t<channel>"),
            self.valid + "\n",
            self.valid.rstrip("\n"),
            self.valid.replace('encoding="utf-8"', 'encoding="UTF-8"'),
            "﻿" + self.valid,
        ]
        for text in cases:
            with self.subTest(text=text[:60]):
                self.assert_refused(text)

    def test_oversized_and_non_utf8_files_are_refused(self):
        self.assert_refused(self.valid.replace("<channel>", "<channel>" + " " * 70000))
        self.assert_refused(
            self.valid.encode().replace(b"MonoPods</title>", b"Mono\xffPods</title>")
        )
        large = self.save(b" " * (64 * 1024 + 1))
        self.assertEqual(self.check(appcast_path=large).returncode, 1)

    def test_truncation_at_every_length_raises_only_value_errors(self):
        data = self.valid.encode()
        for length in range(len(data)):
            with self.subTest(length=length):
                with self.assertRaises(ValueError):
                    appcast.parse(data[:length], candidate=False)
        for length in (0, 1, len(data) // 2, len(data) - 1):
            with self.subTest(command_length=length):
                self.save(data[:length])
                self.assertEqual(self.check().returncode, 1)

    def test_version_values_are_closed(self):
        for build in ("042", "0", "-3", "3.0", "1000000000", " 42", "٤٢"):
            with self.subTest(build=build):
                self.assert_refused(self.production_text(build=build))
        for short in ("1.2", "1.2.3.4", "v1.2.3", "1.2.x", "1.2.3-beta"):
            with self.subTest(short=short):
                text = expected(
                    PRODUCTION_URL.replace("1.2.3", short), len(IMAGE), short=short
                )
                self.assert_refused(text)
        self.assert_refused(
            self.valid.replace("<title>Version 1.2.3", "<title>Version 1.2.4")
        )
        self.assert_refused(
            self.valid.replace("<title>Version 1.2.3", "<title>MonoPods 1.2.3")
        )
        for minimum in ("14", "14.2.1.0", "x", ""):
            with self.subTest(minimum=minimum):
                self.assert_refused(self.production_text(minimum=minimum))

    def test_dates_are_rfc_2822_in_utc(self):
        for date in (
            "Mon, 9 Nov 2026 10:11:12 +0000",
            "Tue, 09 Nov 2026 10:11:12 +0000",
            "Mon, 09 Nov 2026 10:11:12 +0100",
            "Mon, 09 Nov 2026 10:11:12 GMT",
            "Mon, 09 Nov 2026 10:11 +0000",
            "2026-11-09T10:11:12Z",
            "Mon, 09 nov 2026 10:11:12 +0000",
            "Mon, 31 Nov 2026 10:11:12 +0000",
            "Mon, 09 Nov 2026 25:11:12 +0000",
        ):
            with self.subTest(date=date):
                self.assert_refused(self.production_text(date=date))

    def test_length_must_be_the_decimal_image_size(self):
        for length in ("+19", "0x13", "19.0", "", "019", "-19"):
            with self.subTest(length=length):
                self.assert_refused(expected(PRODUCTION_URL, length))
        self.save(expected(PRODUCTION_URL, len(IMAGE) + 1))
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(self.check(*self.with_artifacts()).returncode, 1)

    def test_type_is_fixed(self):
        self.assert_refused(
            self.valid.replace(
                "application/octet-stream", "application/x-apple-diskimage"
            )
        )

    def test_signatures_are_64_bytes_of_standard_base64(self):
        for signature in (
            base64.b64encode(bytes(63)).decode(),
            base64.b64encode(bytes(65)).decode(),
            SIGNATURE.replace("+", "-"),
            SIGNATURE[:10] + " " + SIGNATURE[11:],
            SIGNATURE.rstrip("="),
            SIGNATURE[:-3] + "x==",
            "*" * 88,
            "",
        ):
            with self.subTest(signature=signature):
                self.assert_refused(self.production_text(signature=signature))

    def test_production_url_is_the_release_asset(self):
        for url in (
            "http://github.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.dmg",
            "https://example.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.dmg",
            "https://github.com/other/monoPods/releases/download/v1.2.3/MonoPods.dmg",
            "https://github.com/bernalli/monopods/releases/download/v1.2.3/MonoPods.dmg",
            "https://github.com/bernalli/other/releases/download/v1.2.3/MonoPods.dmg",
            "https://github.com/bernalli/monoPods/releases/download/v1.2.4/MonoPods.dmg",
            "https://github.com/bernalli/monoPods/releases/download/1.2.3/MonoPods.dmg",
            "https://github.com/bernalli/monoPods/releases/download/v1.2.3/monopods.dmg",
            "https://github.com/bernalli/monoPods/releases/download/v1.2.3/MonoPods.zip",
            PRODUCTION_URL + "?x=1",
            PRODUCTION_URL + "#x",
            PRODUCTION_URL.replace("MonoPods.dmg", "Mono%50ods.dmg"),
            PRODUCTION_URL.replace("https://", "https://user@"),
            "file:///tmp/MonoPods-42.dmg",
        ):
            with self.subTest(url=url):
                self.assert_refused(expected(url, len(IMAGE)))

    def test_candidate_url_is_a_file_url_of_the_staged_image(self):
        self.assert_refused(self.valid, candidate=True)
        self.assert_refused(self.candidate_text(), candidate=False)
        image = str(self.candidate_dmg)
        for url in (
            "file://" + image.replace("MonoPods-42", "MonoPods-43"),
            "file://" + image.replace("MonoPods-42", "MonoPods"),
            "file://" + image.replace(".dmg", ".zip"),
            "file://" + image + "?x",
            "file://" + image + "#x",
            "file://" + image.replace("staging", "stag%69ng"),
            "file://" + image.replace("staging", "stag ing"),
            "file://" + image.replace("/staging/", "/staging/../staging/"),
            "file://" + image.replace("/staging/", "/staging//"),
            "file://localhost" + image,
            "file:" + image,
            "file://relative/MonoPods-42.dmg",
        ):
            with self.subTest(url=url):
                self.assert_refused(expected(url, len(IMAGE)), candidate=True)

    def test_candidate_url_must_name_the_image_passed(self):
        other = self.root / "other"
        other.mkdir()
        moved = other / "MonoPods-42.dmg"
        moved.write_bytes(IMAGE)
        self.save(self.candidate_text())
        result = self.check("--candidate", *self.with_artifacts(moved))
        self.assertEqual(result.returncode, 1)
        result = self.build("--candidate", url=self.candidate_url(), dmg=moved)
        self.assertEqual(result.returncode, 1)

    def test_values_must_match_the_bundle(self):
        self.save(self.valid)
        for changes in (
            {"LSMinimumSystemVersion": "15.0"},
            {"CFBundleVersion": "43"},
            {"CFBundleShortVersionString": "1.2.4"},
        ):
            with self.subTest(changes=changes):
                self.write_info(**changes)
                self.assertEqual(self.check(*self.with_artifacts()).returncode, 1)
        self.write_info()
        self.assertEqual(self.check(*self.with_artifacts()).returncode, 0)

    def test_previous_feed_must_carry_a_lower_build(self):
        self.save(self.valid)
        previous = self.root / "previous.xml"
        for build, code in (("41", 0), ("42", 1), ("43", 1), ("1", 0)):
            with self.subTest(build=build):
                self.save(self.production_text(build=build), previous)
                self.assertEqual(
                    self.check("--previous", str(previous)).returncode, code
                )
        self.save(self.valid.replace("<channel>", "<channel>x"), previous)
        self.assertEqual(self.check("--previous", str(previous)).returncode, 1)

    def test_linked_feed_is_refused(self):
        self.save(self.valid)
        link = self.root / "link.xml"
        link.symlink_to(self.output)
        self.assertEqual(self.check(appcast_path=link).returncode, 1)


if __name__ == "__main__":
    unittest.main()
