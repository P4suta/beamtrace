<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Contributing

Thank you for helping build BeamTrace. Start with an issue for changes that alter a public contract, trace semantics, privacy behavior, or network protocol.

## TDD is the development process

1. Add the smallest test that demonstrates the missing behavior or regression.
2. Run the narrow package test and confirm the new test fails for the intended reason.
3. Implement the smallest complete behavior.
4. Run the narrow test until it is green.
5. Refactor without changing observable behavior.
6. Run `./scripts/test-all.ps1` before submitting.

A compile error caused by an intentionally absent public API is an acceptable first Red. A syntax error in the test is not.

Security fixes need an adversarial regression test. Capture changes need a cleanup assertion. Inference changes need evidence and confidence assertions. Storage changes need malformed-input tests.

## Design constraints

- Do not add arbitrary RPC, process mutation, process killing, or ETS browsing.
- Do not infer a causal edge across an unobserved boundary.
- Do not add a plaintext cookie CLI flag or persist secrets to TOML.
- Keep the injected agent dependency-free Erlang.
- Keep external I/O, OS integration, and Canvas work behind narrow FFI modules.
- Preserve both dark/light and reduced-motion/high-contrast paths.

Run `gleam format` on edited Gleam files. Erlang is compiled with warnings as errors in the agent suite.

By contributing, you agree that your contribution is licensed under `Apache-2.0 OR MIT`.
