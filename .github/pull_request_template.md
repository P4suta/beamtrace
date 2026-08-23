<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
## What changed

Describe the user-visible behavior and the smallest useful reason for the change.

## TDD evidence

- [ ] I added or changed a test before implementation.
- [ ] I observed the test fail for the intended reason.
- [ ] The narrow test now passes.
- [ ] `./scripts/test-all.ps1` passes, or I explained the environment-owned skip below.

## Safety review

- [ ] Capture cleanup and bounded-resource behavior remain covered.
- [ ] No secret, raw value, cookie, token, or customer trace is included.
- [ ] Any inferred causal result still carries evidence and confidence.
- [ ] User-facing or public-contract changes include documentation.

## Verification notes

List the commands run and any CI-owned checks that could not run locally.
