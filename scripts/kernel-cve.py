#!/usr/bin/env python3
"""Check a Linux kernel version against the official kernel CVE dataset."""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

KINDS = {"semver", "original_commit_for_fix"}
CVSS_KEYS = ("cvssV4_0", "cvssV3_1", "cvssV3_0")
VERSION_RE = re.compile(r"^v?(\d+(?:\.\d+){0,3})(?:-rc(\d+))?$")
DATASET_URL = "https://git.kernel.org/pub/scm/linux/security/vulns.git"


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        raise SystemExit(1)


def dict_of(value):
    return value if isinstance(value, dict) else {}


def list_of(value):
    return value if isinstance(value, list) else []


def cna(record):
    return dict_of(dict_of(record.get("containers")).get("cna"))


def parse_version(text):
    """Return a 6-tuple: 4 numeric parts, release flag, rc number."""
    if not isinstance(text, str):
        return None
    match = VERSION_RE.match(text.strip())
    if not match:
        return None
    parts = [int(part) for part in match.group(1).split(".")]
    parts += [0] * (4 - len(parts))
    if match.group(2) is not None:
        return (*parts, 0, int(match.group(2)))
    return (*parts, 1, 0)


def linux_versions(record):
    versions = []
    for affected in list_of(cna(record).get("affected")):
        affected = dict_of(affected)
        if affected.get("product") != "Linux":
            continue
        for entry in list_of(affected.get("versions")):
            entry = dict_of(entry)
            if entry.get("versionType") in KINDS:
                versions.append(entry)
    return versions


def in_range(version, entry):
    start = parse_version(entry.get("version"))
    if start is None:
        return None
    if version < start:
        return False
    if "lessThan" in entry:
        bound, inclusive = entry["lessThan"], False
    elif "lessThanOrEqual" in entry:
        bound, inclusive = entry["lessThanOrEqual"], True
    else:
        return True
    if bound == "*":
        return True
    if not isinstance(bound, str):
        return None
    if inclusive and bound.endswith(".*"):
        prefix = bound[:-2]
        if not re.fullmatch(r"\d+(?:\.\d+){0,3}", prefix):
            return None
        width = prefix.count(".") + 1
        return version[:width] == tuple(int(part) for part in prefix.split("."))
    upper = parse_version(bound)
    if upper is None:
        return None
    return version <= upper if inclusive else version < upper


def fixed_versions(ranges, version):
    found = []
    for entry in ranges:
        start = entry.get("version")
        parsed = parse_version(start)
        if entry.get("status") == "unaffected" and parsed and parsed > version and start not in found:
            found.append(start)
    return sorted(found, key=parse_version)[:3]


def evaluate(record, version):
    ranges = linux_versions(record)
    matches = [(entry.get("status"), hit) for entry in ranges if (hit := in_range(version, entry)) is not None]
    if not matches:
        return "unknown", []
    if any(status == "unaffected" and hit for status, hit in matches):
        return "unaffected", []
    if any(status == "affected" and hit for status, hit in matches):
        return "affected", fixed_versions(ranges, version)
    return "clean", []


def cvss_score(record):
    best = 0.0
    for metric in list_of(cna(record).get("metrics")):
        for key in CVSS_KEYS:
            value = dict_of(dict_of(metric).get(key)).get("baseScore")
            try:
                best = max(best, float(value))
            except (TypeError, ValueError):
                pass
    return best


def check(root, version):
    files = list(root.glob("*/*.json"))
    affected = []
    evaluated = unknown = malformed = 0
    for path in files:
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict):
                raise ValueError("record is not a JSON object")
        except (OSError, ValueError):
            malformed += 1
            continue
        status, fixed = evaluate(record, version)
        if status == "unknown":
            unknown += 1
            continue
        evaluated += 1
        if status != "affected":
            continue
        metadata = dict_of(record.get("cveMetadata"))
        affected.append({
            "id": metadata.get("cveId") or path.stem,
            "score": cvss_score(record),
            "title": cna(record).get("title") or "",
            "fixed_in": fixed,
        })
    affected.sort(key=lambda item: (-item["score"], item["id"]))
    return {
        "total_records": len(files),
        "evaluated": evaluated,
        "unknown": unknown,
        "malformed": malformed,
        "affected": affected,
    }


def repo_head(repo):
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def render_markdown(report):
    lines = [
        f"# Linux kernel CVE report for {report['version']}",
        "",
        f"- Dataset: {DATASET_URL}",
        f"- Dataset HEAD: `{report['repo_head'] or 'unknown'}`",
        f"- Records: {report['total_records']} total, {report['evaluated']} evaluated, "
        f"{report['unknown']} unknown, {report['malformed']} malformed",
        f"- Affected CVEs: {len(report['affected'])}",
        f"- Critical CVEs (CVSS >= 9.0): {report['critical_count']}",
        "",
        "| CVE | CVSS | Title | Fixed in |",
        "| --- | ---: | --- | --- |",
    ]
    for item in report["affected"]:
        title = str(item["title"]).replace("|", "\\|").replace("\n", " ")
        fixed = ", ".join(item["fixed_in"]) or "none known"
        lines.append(f"| {item['id']} | {item['score']:.1f} | {title} | {fixed} |")
    lines += [
        "",
        "Records counted as unknown carry only git commit ranges, which cannot be mapped to a version. "
        "A version-only scan also cannot tell whether the vulnerable code is compiled into this kernel.",
        "",
    ]
    return "\n".join(lines)


def build_parser():
    parser = Parser(description=__doc__)
    parser.add_argument("--version", required=True, help="Linux kernel version, e.g. 6.18.60")
    parser.add_argument("--repo", required=True, help="local clone of the vulns dataset")
    parser.add_argument("--output", required=True, help="markdown report path")
    parser.add_argument("--json", required=True, help="JSON report path")
    parser.add_argument(
        "--fail-on-critical", action="store_true",
        help="exit 2 when an affected CVE scores 9.0 or higher",
    )
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    version = parse_version(args.version)
    if version is None:
        print(f"kernel-cve: invalid kernel version: {args.version}", file=sys.stderr)
        return 1
    root = Path(args.repo) / "cve" / "published"
    if not root.is_dir():
        print(f"kernel-cve: dataset not found: {root}", file=sys.stderr)
        return 1
    counts = check(root, version)
    affected = counts["affected"]
    critical = sum(1 for item in affected if item["score"] >= 9.0)
    report = {
        "version": args.version,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "repo_head": repo_head(args.repo),
        "total_records": counts["total_records"],
        "evaluated": counts["evaluated"],
        "unknown": counts["unknown"],
        "malformed": counts["malformed"],
        "affected": affected,
        "critical_count": critical,
    }
    try:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(render_markdown(report), encoding="utf-8")
        Path(args.json).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"kernel-cve: cannot write report: {exc}", file=sys.stderr)
        return 1
    print(
        f"kernel-cve: {args.version} affected={len(affected)} critical={critical} "
        f"unknown={counts['unknown']} malformed={counts['malformed']} "
        f"records={counts['total_records']} head={report['repo_head'] or 'unknown'}"
    )
    return 2 if args.fail_on_critical and critical else 0


if __name__ == "__main__":
    sys.exit(main())
