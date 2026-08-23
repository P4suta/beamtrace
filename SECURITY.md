<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Security policy

BeamTrace handles production metadata and distribution credentials. Please do not open a public issue for a suspected vulnerability.

Report vulnerabilities privately through [a new GitHub Security Advisory](https://github.com/P4suta/beamtrace/security/advisories/new). Include affected versions, reproduction steps, impact, and any suggested mitigation. Do not include real cookies, tokens, raw captures, or customer data.

The maintainer aims to acknowledge a report within 7 days, provide a status update at least every 14 days, and coordinate a fix and disclosure within 90 days. A severe active exploit or a reporter-requested delay may require a different timeline; any change will be communicated in the private advisory.

Supported security updates currently target the latest `0.x` release on OTP 27–29. Alpha releases may contain breaking fixes.

## Security boundaries

- Distribution cookies remain in the relay/local process and are never accepted as plaintext CLI arguments.
- The team hub has no arbitrary RPC or code-loading capability on target nodes.
- Raw capture is not a safe default. Team relay ingestion currently rejects it; any future enablement must be short-lived, permission-gated, audited, bounded, and redacted.
- `.beamtrace` files are untrusted input. Import performs path, duplicate-entry, size, ratio, structure, and checksum validation.
- Self-contained HTML export has no network access and removes raw display values by default.

See [docs/threat-model.md](docs/threat-model.md) for assumptions and non-goals.
