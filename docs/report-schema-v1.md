# Report schema version 1

Both `swiss.sh` and `swiss.ps1` emit the same ordered set of facts. JSON values
are strings so unavailable data can be represented consistently without
platform-specific type coercion. The canonical field list is
[`schema/fields-v1.txt`](../schema/fields-v1.txt).

Each fact contains:

- `key`: stable dotted identifier;
- `value`: collected value, or an empty string when unavailable;
- `status`: `ok`, `unknown`, `unsupported`, `missing`, `denied`, or `error`;
- `source`: the local file, command, API, or derivation used;
- `confidence`: `exact`, `derived`, or `heuristic`.

Status meanings are deliberately narrow:

| Status | Meaning |
| --- | --- |
| `ok` | A value was collected. |
| `unknown` | The probe exists but did not determine a value. |
| `unsupported` | This platform has no meaningful implementation for the fact. |
| `missing` | An optional local file, command, or API is absent. |
| `denied` | The current user cannot read the source. |
| `error` | The probe failed unexpectedly. |

`exact` describes direct API/file output, `derived` describes a deterministic
conversion such as uptime from a boot timestamp, and `heuristic` identifies an
inference such as physical-versus-virtual environment detection.

The top-level `collector` object duplicates essential run metadata for easy
routing. `warnings` is reserved for non-fatal report-level warnings. Individual
probe failures remain facts and never make the JSON document partial.

Inventory facts use compact semicolon-separated records. A record's first
component identifies the object and subsequent pipe-separated components use
`name=value`, for example:

```text
eth0|state=up|type=wired|mac=00:00:00:00:00:00
```

Within every inventory component, reserved delimiters are percent-encoded in
this order: `%` becomes `%25`, `;` becomes `%3B`, `|` becomes `%7C`, and `=`
becomes `%3D`. Consumers decode those four sequences after splitting records
on `;`, components on `|`, and component names from values on the first `=`.
The encoding is textual and case-sensitive; no other URL-decoding is implied.

This representation is intentionally conservative for the first schema. A
future schema may add typed inventories without changing version 1.
