#!/usr/bin/env python3
"""Validate a report using the JSON Schema subset used by schema version 1."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


class ValidationFailure(Exception):
    pass


def fail(path: str, message: str) -> None:
    raise ValidationFailure(f"{path}: {message}")


def resolve_reference(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise ValidationFailure(f"unsupported schema reference: {reference}")
    value: Any = root
    for component in reference[2:].split("/"):
        component = component.replace("~1", "/").replace("~0", "~")
        value = value[component]
    if not isinstance(value, dict):
        raise ValidationFailure(f"schema reference is not an object: {reference}")
    return value


def validate(instance: Any, schema: dict[str, Any], root: dict[str, Any], path: str) -> None:
    if "$ref" in schema:
        validate(instance, resolve_reference(root, schema["$ref"]), root, path)

    expected_type = schema.get("type")
    type_matches = {
        "object": isinstance(instance, dict),
        "array": isinstance(instance, list),
        "string": isinstance(instance, str),
    }
    if expected_type in type_matches and not type_matches[expected_type]:
        fail(path, f"expected {expected_type}")

    if "const" in schema and instance != schema["const"]:
        fail(path, f"expected constant {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        fail(path, f"value {instance!r} is outside the allowed enum")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            fail(path, "string is shorter than minLength")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            fail(path, f"string does not match {schema['pattern']!r}")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                fail(path, f"missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extras = sorted(set(instance) - set(properties))
            if extras:
                fail(path, f"unexpected properties: {', '.join(extras)}")
        for key, child_schema in properties.items():
            if key in instance:
                validate(instance[key], child_schema, root, f"{path}.{key}")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            fail(path, "array is shorter than minItems")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            fail(path, "array is longer than maxItems")
        prefix_items = schema.get("prefixItems", [])
        for index, child_schema in enumerate(prefix_items):
            if index < len(instance):
                validate(instance[index], child_schema, root, f"{path}[{index}]")
        item_schema = schema.get("items")
        if item_schema is False and len(instance) > len(prefix_items):
            fail(path, "array has items after the allowed prefix")
        if isinstance(item_schema, dict):
            for index, item in enumerate(instance):
                validate(item, item_schema, root, f"{path}[{index}]")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate-report.py SCHEMA REPORT", file=sys.stderr)
        return 2

    schema_path = Path(sys.argv[1])
    report_path = Path(sys.argv[2])
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        report = json.loads(report_path.read_text(encoding="utf-8"))
        if not isinstance(schema, dict):
            raise ValidationFailure("schema root is not an object")
        validate(report, schema, schema, "$")
    except (OSError, json.JSONDecodeError, KeyError, ValidationFailure) as error:
        print(f"report validation failed: {error}", file=sys.stderr)
        return 1

    print(f"report validation passed: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
