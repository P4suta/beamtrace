<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# Positioning BeamTrace 0.3

BeamTrace provides bounded, delivery-verified causal observation for BEAM applications. It records what its agents observed, the exact causal edges supported by OTP trace identifiers, explicit boundaries, and reproducible inferences. It does not claim a complete execution history, a perfectly synchronized distributed clock, calibrated anomaly probabilities, or visibility into ports, ETS, external I/O, and unobserved nodes.

The primary workflow is Capture → Compare: capture one bounded operation, preserve integrity evidence and clock uncertainty, then compare logical actors and causal neighborhoods across runs. Live and Team modes support triage and collaboration but do not upgrade sampled or transferred data into a stronger causal outcome.

Current completion means the v2 format/API/protocol specifications, implementation, migration path, conformance corpus, acceptance gates, and an OTP proposal draft are available. External adoption, additional maintainers, dependency-fork resolution, and upstream OTP acceptance depend on parties outside this repository and are not represented as delivered features.
