<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# HTTP API reference

All supported Web and TUI calls use `/api/v2`. The bundled OpenAPI 3.1 document
is available offline as `priv/openapi-v2.json` and at:

```text
GET /api/v2/openapi.json
```

V2 errors always have this shape:

```json
{"error":{"code":"invalid_request","message":"…","hint":"…"}}
```

The API includes health/readiness/capabilities, bounded event and graph pages,
attached capture state and control, bounded Live sampling, 2–20 trace compare,
and authorized Team trace selection. Team raw data is authorized before any
memory, filesystem, or S3 fetch.

`/api/v1` is a v0.3 compatibility projection. Every response includes
deprecation, successor-version, warning, and v0.4 removal headers. A v1
projection fails rather than discarding v2 time uncertainty or inferred
evidence.
