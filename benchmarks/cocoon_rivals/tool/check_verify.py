#!/usr/bin/env python3
"""Compares two verify dumps (cocoon's and a rival's) for one size.

usage: check_verify.py <cocoon.json> <rival.json>  — exit 0 when every read
shape's contract output matches: latest-50 ids per account, one account's
monthly totals, the year-report sums, the all-accounts month range, the
status search, the bigspend ids, the amount-range ids, the pending-month
ids, the two counts, and the deep-page ids. Timing and scan counts are
ignored.
"""
import json
import sys

SHAPES = [
    "latest50",
    "monthly",
    "yearreport",
    "range",
    "status",
    "bigspend",
    "amountrange",
    "pendingmonth",
    "deeppage",
    "count",
]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1]) as f:
        cocoon = json.load(f)["runs"][0]
    with open(sys.argv[2]) as f:
        rival = json.load(f)["runs"][0]
    bad = []
    for shape in SHAPES:
        if cocoon.get(shape) != rival.get(shape):
            bad.append(shape)
    if bad:
        print(
            f"mismatch {rival.get('engine')} vs {cocoon.get('engine')}: "
            f"{', '.join(bad)}",
            file=sys.stderr,
        )
        return 1
    print(f"ok: {rival.get('engine')} matches {cocoon.get('engine')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
