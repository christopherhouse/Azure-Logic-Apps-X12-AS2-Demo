#!/usr/bin/env python3
"""
validate-json.py — Jayne's JSON-schema QA harness.

Validates the sample payloads against the canonical PO JSON Schema
(samples/purchase-order.schema.json, draft 2020-12), asserting:
  * purchase-order.sample.json   -> VALID   (happy path)
  * purchase-order.invalid.json  -> INVALID (dead-letter negative path)

This mirrors the workflow's Parse_Purchase_Order (ParseJson) gate: a payload
that fails the schema fails that action, the Process_Purchase_Order scope
fails, and the run dead-letters the Service Bus message.

Requires: pip install jsonschema
Usage:    python samples/validate-json.py
Exit:     0 = both assertions hold, non-zero otherwise.
"""
import json
import os
import sys

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    print("ERROR: pip install jsonschema", file=sys.stderr)
    sys.exit(2)

BASE = os.path.dirname(os.path.abspath(__file__))


def check(validator, filename, expect_valid):
    with open(os.path.join(BASE, filename), encoding="utf-8") as fh:
        data = json.load(fh)
    errors = sorted(validator.iter_errors(data), key=lambda e: e.json_path)
    is_valid = len(errors) == 0
    ok = is_valid == expect_valid
    print(f"[{'PASS' if ok else 'FAIL'}] {filename}: "
          f"valid={is_valid} (expected valid={expect_valid}); {len(errors)} error(s)")
    for err in errors:
        print(f"    - {err.json_path}: {err.message}")
    return ok


def main():
    with open(os.path.join(BASE, "purchase-order.schema.json"), encoding="utf-8") as fh:
        schema = json.load(fh)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    results = [
        check(validator, "purchase-order.sample.json",    expect_valid=True),
        check(validator, "purchase-order-e2e-test.json",  expect_valid=True),   # 2-line smoke fixture
        check(validator, "purchase-order-1line.json",     expect_valid=True),   # single-line supplier fixture
        check(validator, "purchase-order-3line.json",     expect_valid=True),   # three-line supplier fixture
        check(validator, "purchase-order.invalid.json",   expect_valid=False),
    ]
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
