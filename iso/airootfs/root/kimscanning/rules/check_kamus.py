#!/usr/bin/env python3
"""Checker for the KimScanning rule dictionary.

Checks rules/en.yaml for:
  - entry count,
  - repeated tool+rule pairs,
  - empty what/why/fix fields,
  - tool+rule pairs seen in stored sessions but missing from the
    dictionary.

Standard Python 3 libraries only. PyYAML is used when available; otherwise
a small built-in parser is used and that fact is reported.

Exits 0 when clean, 1 when there are duplicates or empty fields.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DICT = os.path.join(SCRIPT_DIR, "en.yaml")
REQUIRED_FIELDS = ("what", "why", "fix")


def decode_scalar(value: str) -> str:
    """Convert a simple YAML value (quoted or not) to text."""
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return str(json.loads(value))
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def parse_yaml_fallback(path: str) -> list:
    """Parser for the flat list shape used by en.yaml."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    entries, current = [], None
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            if current is not None:
                entries.append(current)
            current = {}
            stripped = stripped[2:].strip()
        if current is None or ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        current[key.strip()] = decode_scalar(value)
    if current is not None:
        entries.append(current)
    return entries


def load_dictionary(path: str):
    """Return (entries, loader_name). Raise on read failure."""
    try:
        import yaml  # type: ignore
    except ImportError:
        return parse_yaml_fallback(path), "fallback parser (no PyYAML)"

    try:
        with open(path, encoding="utf-8") as fh:
            entries = yaml.safe_load(fh)
    except Exception as exc:
        raise RuntimeError(f"cannot read dictionary: {exc}") from exc

    if entries is None:
        entries = []
    if not isinstance(entries, list):
        raise RuntimeError("dictionary must be a YAML list (- tool: ...)")
    return entries, "PyYAML"


def default_sessions_dir() -> str:
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser(
        "~/.local/share"
    )
    return os.path.join(data_home, "kimscanning", "sessions")


def scan_sessions(sessions_dir: str) -> tuple:
    """Return (seen, session_count, warnings).

    seen is {(tool, rule): {"count": n, "sessions": set(...)}}.
    """
    seen = {}
    warnings = []
    session_files = sorted(glob.glob(os.path.join(sessions_dir, "*/session.json")))
    for session_file in session_files:
        session_id = os.path.basename(os.path.dirname(session_file))
        try:
            with open(session_file, encoding="utf-8") as fh:
                session = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            warnings.append(f"{session_file}: {exc}")
            continue
        findings = session.get("findings") if isinstance(session, dict) else None
        if not isinstance(findings, list):
            continue
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            tool = str(finding.get("tool") or "").strip()
            rule = str(finding.get("rule") or "").strip()
            if not tool or not rule:
                continue
            rec = seen.setdefault((tool, rule), {"count": 0, "sessions": set()})
            rec["count"] += 1
            rec["sessions"].add(session_id)
    return seen, len(session_files), warnings


def check_entries(entries: list) -> tuple:
    """Return (total, duplicates, empty, malformed).

    duplicates is a list of (tool, rule, occurrence_count).
    empty is a list of (tool, rule, field).
    malformed is a list of entry indexes missing tool or rule.
    """
    key_counts = {}
    order = []
    empty = []
    malformed = []

    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            malformed.append((index, "not a YAML object"))
            continue
        tool = str(entry.get("tool") or "").strip()
        rule = str(entry.get("rule") or "").strip()
        if not tool or not rule:
            malformed.append((index, "tool or rule is empty"))
            continue
        key = (tool, rule)
        if key not in key_counts:
            key_counts[key] = 0
            order.append(key)
        key_counts[key] += 1
        for field in REQUIRED_FIELDS:
            if not str(entry.get(field) or "").strip():
                empty.append((tool, rule, field))

    duplicates = [
        (tool, rule, key_counts[(tool, rule)])
        for (tool, rule) in order
        if key_counts[(tool, rule)] > 1
    ]
    return len(entries), duplicates, empty, malformed


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Check the KimScanning rule dictionary and missing rules."
    )
    parser.add_argument(
        "--dict",
        default=DEFAULT_DICT,
        help=f"dictionary path (default: {DEFAULT_DICT})",
    )
    parser.add_argument(
        "--sessions",
        default=default_sessions_dir(),
        help="KimScanning sessions directory (default: $XDG_DATA_HOME/kimscanning/sessions)",
    )
    args = parser.parse_args(argv)

    try:
        entries, loader = load_dictionary(args.dict)
    except (OSError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    total, duplicates, empty, malformed = check_entries(entries)

    print(f"Dictionary  : {args.dict}")
    print(f"Loader      : {loader}")
    print(f"Entries     : {total}")
    print(f"Duplicates  : {len(duplicates)}")
    for tool, rule, count in duplicates:
        print(f"  DUPLICATE {tool}/{rule} ({count} occurrences)")
    print(f"Empty fields: {len(empty)}")
    for tool, rule, field in empty:
        print(f"  EMPTY {tool}/{rule}: {field}")
    print(f"Bad entries : {len(malformed)}")
    for index, reason in malformed:
        print(f"  BAD entry #{index}: {reason}")

    if os.path.isdir(args.sessions):
        seen, session_count, warnings = scan_sessions(args.sessions)
        print(f"Sessions    : {args.sessions} ({session_count} session.json)")
        for warning in warnings:
            print(f"  warning: {warning}", file=sys.stderr)
        known = {
            (str(e.get("tool") or "").strip(), str(e.get("rule") or "").strip())
            for e in entries
            if isinstance(e, dict)
        }
        missing = sorted(
            (tool, rule, rec)
            for (tool, rule), rec in seen.items()
            if (tool, rule) not in known
        )
        print(f"Missing rule: {len(missing)}")
        for tool, rule, rec in missing:
            print(
                f"  {tool}/{rule}  ({rec['count']} findings, "
                f"{len(rec['sessions'])} sessions)"
            )
    else:
        print(f"Sessions    : {args.sessions} (none)")
        print("  sessions directory not found; missing-rule check skipped.")

    if duplicates or empty or malformed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
