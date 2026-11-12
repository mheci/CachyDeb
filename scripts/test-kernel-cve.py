import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("kernel-cve.py")
SPEC = importlib.util.spec_from_file_location("kernel_cve", MODULE_PATH)
kc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kc)


def semver(start, status, **bound):
    return {"version": start, "status": status, "versionType": "semver", **bound}


def record(*versions, metrics=None):
    return {
        "cveMetadata": {"cveId": "CVE-TEST-0001"},
        "containers": {
            "cna": {
                "title": "test title",
                "affected": [{"product": "Linux", "versions": list(versions)}],
                "metrics": metrics or [],
            }
        },
    }


def run_cli(dataset, *extra):
    md = Path(dataset).parent / "report.md"
    js = Path(dataset).parent / "report.json"
    result = subprocess.run(
        [
            sys.executable, str(MODULE_PATH),
            "--version", "5.4.0",
            "--repo", str(dataset),
            "--output", str(md),
            "--json", str(js),
            *extra,
        ],
        capture_output=True, text=True,
    )
    return result, md, js


class KernelCveTest(unittest.TestCase):
    def test_affected_inside_range(self):
        rec = record(semver("0", "affected", lessThan="6.0"))
        self.assertEqual(kc.evaluate(rec, kc.parse_version("5.4.0"))[0], "affected")
        self.assertEqual(kc.evaluate(rec, kc.parse_version("6.1.0"))[0], "clean")

    def test_unaffected_branch_range_wins(self):
        rec = record(
            semver("0", "affected", lessThan="6.12.20"),
            semver("6.12.20", "unaffected", lessThanOrEqual="6.12.*"),
        )
        self.assertEqual(kc.evaluate(rec, kc.parse_version("6.12.25"))[0], "unaffected")
        status, fixed = kc.evaluate(rec, kc.parse_version("6.12.10"))
        self.assertEqual(status, "affected")
        self.assertEqual(fixed, ["6.12.20"])

    def test_wildcard_upper_bound(self):
        entry = semver("7.2.3", "affected", lessThanOrEqual="7.2.*")
        self.assertTrue(kc.in_range(kc.parse_version("7.2.99"), entry))
        self.assertFalse(kc.in_range(kc.parse_version("7.3.0"), entry))
        unbounded = semver("5.13", "unaffected", lessThanOrEqual="*")
        self.assertTrue(kc.in_range(kc.parse_version("7.3.4"), unbounded))

    def test_less_than_is_exclusive(self):
        entry = semver("0", "affected", lessThan="6.0")
        self.assertTrue(kc.in_range(kc.parse_version("5.99.99"), entry))
        self.assertFalse(kc.in_range(kc.parse_version("6.0"), entry))

    def test_git_only_record_is_unknown(self):
        rec = record({
            "version": "abc123",
            "lessThan": "def456",
            "status": "affected",
            "versionType": "git",
        })
        self.assertEqual(kc.evaluate(rec, kc.parse_version("6.18.60"))[0], "unknown")

    def test_cvss_uses_highest_base_score(self):
        rec = record(metrics=[
            {"cvssV3_1": {"baseScore": 7.5}},
            {"cvssV4_0": {"baseScore": 9.8}},
            {"cvssV3_0": {"baseScore": 5.0}},
        ])
        self.assertEqual(kc.cvss_score(rec), 9.8)
        self.assertEqual(kc.cvss_score(record()), 0.0)

    def test_rc_versions_sort_before_release(self):
        self.assertLess(kc.parse_version("7.4-rc1"), kc.parse_version("7.4"))
        self.assertLess(kc.parse_version("7.4-rc2"), kc.parse_version("7.4-rc10"))
        entry = semver("7.4-rc1", "affected", lessThan="7.4")
        self.assertTrue(kc.in_range(kc.parse_version("7.4-rc5"), entry))
        self.assertFalse(kc.in_range(kc.parse_version("7.4"), entry))

    def test_fail_on_critical_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            dataset = Path(tmp) / "vulns"
            published = dataset / "cve" / "published" / "2026"
            published.mkdir(parents=True)
            (published / "CVE-2026-0001.json").write_text(json.dumps(record(
                semver("0", "affected", lessThan="6.0"),
                metrics=[{"cvssV3_1": {"baseScore": 9.8}}],
            )))
            result, md, js = run_cli(dataset)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(js.read_text(encoding="utf-8"))
            self.assertEqual(report["affected"][0]["id"], "CVE-TEST-0001")
            self.assertEqual(report["critical_count"], 1)
            self.assertEqual(report["malformed"], 0)
            self.assertTrue(report["generated_at"].endswith("Z"))
            self.assertIn("CVE-TEST-0001", md.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            dataset = Path(tmp) / "vulns"
            published = dataset / "cve" / "published" / "2026"
            published.mkdir(parents=True)
            (published / "CVE-2026-0001.json").write_text(json.dumps(record(
                semver("0", "affected", lessThan="6.0"),
                metrics=[{"cvssV4_0": {"baseScore": 9.8}}],
            )))
            result, _, _ = run_cli(dataset, "--fail-on-critical")
            self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
