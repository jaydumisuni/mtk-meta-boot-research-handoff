#!/usr/bin/env python3
"""Read-only MTK META campaign analyzer entrypoint."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from meta_common import redact_line
from meta_report import analyze, verify_publication


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze and sanitize a D5 MTK META campaign"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    analyze_parser = subparsers.add_parser(
        "analyze", help="analyze a raw local campaign"
    )
    analyze_parser.add_argument("--campaign", type=Path, required=True)
    analyze_parser.add_argument("--output", type=Path, required=True)

    verify_parser = subparsers.add_parser(
        "verify", help="verify a sanitized publication directory"
    )
    verify_parser.add_argument("--output", type=Path, required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "analyze":
            report = analyze(args.campaign.resolve(), args.output.resolve())
            print(
                json.dumps(
                    {
                        "campaign_id": report["campaign_id"],
                        "verdict": report["verdict"],
                    }
                )
            )
            return 0
        problems = verify_publication(args.output.resolve())
        if problems:
            for problem in problems:
                print(f"[BLOCKED] {problem}", file=sys.stderr)
            return 2
        print("Publication redaction verification passed.")
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


__all__ = ["analyze", "main", "redact_line", "verify_publication"]

if __name__ == "__main__":
    raise SystemExit(main())
