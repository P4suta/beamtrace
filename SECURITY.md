<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Security policy

BeamTrace handles production metadata and distribution credentials. Please do not open a public issue for a suspected vulnerability.

Report vulnerabilities privately to the repository's GitHub Security Advisory channel. Include affected versions, reproduction steps, impact, and any suggested mitigation. Do not include real cookies, tokens, raw captures, or customer data.

Supported security updates currently target the latest `0.x` release on OTP 27–29. Alpha releases may contain breaking fixes.

## Security boundaries

- Distribution cookies remain in the relay/local process and are never accepted as plaintext CLI arguments.
- The team hub has no arbitrary RPC or code-loading capability on target nodes.
- Raw capture is not a safe default. Team relay ingestion currently rejects it; any future enablement must be short-lived, permission-gated, audited, bounded, and redacted.
- `.beamtrace` files are untrusted input. Import performs path, duplicate-entry, size, ratio, structure, and checksum validation.
- Self-contained HTML export has no network access and removes raw display values by default.

See [docs/threat-model.md](docs/threat-model.md) for assumptions and non-goals.
