# Changelog

## Unreleased

### ⚠ BREAKING CHANGES

* **core:** finalize the public vocabulary before the first stable release (see `docs/migration-v0.4.md`): the unchecked `diff.compare` is removed and `diff.compare_checked` takes its name; `aql.compile_agent`/`AgentPlan` are removed in favour of `compile_trigger`; `beamtrace.prepare` becomes `prepared`; `types.Mfa` labels drop their trailing underscores; `TermView.Tag`/`ListView`/`MapView` become `TagOnly`/`BoundedList`/`BoundedMap`; `anomaly.Metric`/`SystemSignal` become `MetricKind`/`VmSignal`

### Features

* **core:** add opaque prepared traces and reusable multi-run comparison APIs
* **codec:** add direct typed validators and single-parse versioned decoding

### Performance

* reuse causal analysis, process grouping, signatures, and diff aggregation
* avoid JSON round trips while saving generated archives and ingesting relay batches
* read schema-v2 windows selectively and stream archive search segment by segment
* reuse NDJSON framing and canonical graph output, and parallelize full-load event decoding
* skip duplicate-root and identity-propagation work for ordinary captures

## [0.2.0](https://github.com/P4suta/beamtrace/compare/v0.1.1...v0.2.0) (2026-08-25)


### ⚠ BREAKING CHANGES

* Relay protocol v1 now receives `upgrade_required`; relays must use signed, session-scoped v2 messages.
* `GET /api/v1/relays/:id/frames` now returns `410 Gone`; clients must use the trace APIs.
* Legacy relay frames migrate to synthetic `unknown` and `incomplete` sessions instead of remaining independent frame records.


### Features

* **runtime:** deliver the v0.2 tracing platform ([#22](https://github.com/P4suta/beamtrace/issues/22)) ([20f6960](https://github.com/P4suta/beamtrace/commit/20f6960099bc5b2c13ce9d0205a5ba35bc6d52e2))


### Bug Fixes

* **package:** scope SBOM to locked manifests ([#25](https://github.com/P4suta/beamtrace/issues/25)) ([9ab64ba](https://github.com/P4suta/beamtrace/commit/9ab64ba1fba64b52a3a9b86f6448f1a7f56339c8))
* **record:** use platform EPMD bootstrap paths ([#24](https://github.com/P4suta/beamtrace/issues/24)) ([bf07bb9](https://github.com/P4suta/beamtrace/commit/bf07bb9199e41e283b97db5abbcdaef189c9525b))

## [0.1.1](https://github.com/P4suta/beamtrace/compare/v0.1.0...v0.1.1) (2026-08-24)


### Bug Fixes

* **ci:** acknowledge pre-1.0 Hex releases ([#16](https://github.com/P4suta/beamtrace/issues/16)) ([94c9792](https://github.com/P4suta/beamtrace/commit/94c9792517d8f05167d1bbbdd4b194551b47a630))
* **ci:** list draft releases explicitly ([#14](https://github.com/P4suta/beamtrace/issues/14)) ([63b4965](https://github.com/P4suta/beamtrace/commit/63b4965c4afdec9a2861d56e7b35e0d4c926a07f))
* **ci:** normalize Hex metadata ordering ([#19](https://github.com/P4suta/beamtrace/issues/19)) ([bfef1cb](https://github.com/P4suta/beamtrace/commit/bfef1cb80a6aada4951e9ef651423a2cb1f77d97))
* **ci:** recover immutable draft releases ([459cd47](https://github.com/P4suta/beamtrace/commit/459cd47c558e541fcaf61275808acb8793f27cd1))
* **ci:** resolve release upload repository ([#18](https://github.com/P4suta/beamtrace/issues/18)) ([55867a2](https://github.com/P4suta/beamtrace/commit/55867a24987459d8c420d305a2b87ab5bfbb571c))
* **ci:** resolve the Hex tarball exactly ([#15](https://github.com/P4suta/beamtrace/issues/15)) ([d6c20e2](https://github.com/P4suta/beamtrace/commit/d6c20e288c979476e87915fd4fd11fa5770cf7e7))
* **ci:** reuse matching GHCR release tags ([#20](https://github.com/P4suta/beamtrace/issues/20)) ([945705c](https://github.com/P4suta/beamtrace/commit/945705c12cad2625b9794c886317c9c7ac611aa4))
* **ci:** separate release source from tooling ([#17](https://github.com/P4suta/beamtrace/issues/17)) ([646fa3f](https://github.com/P4suta/beamtrace/commit/646fa3ff158d058324e4666fb700ca372595cafa))
* **runtime:** enforce relay frame read authorization ([#21](https://github.com/P4suta/beamtrace/issues/21)) ([b2e77f6](https://github.com/P4suta/beamtrace/commit/b2e77f6ed86988a562bf015844e513f1be6a661a))

## 0.1.0 (2026-08-23)


### Features

* **ci:** automate releases with release-please ([6446d81](https://github.com/P4suta/beamtrace/commit/6446d81c180899f88834f3880ec3d8b56c8d4f32))
* launch BeamTrace causal workbench ([f92d855](https://github.com/P4suta/beamtrace/commit/f92d855d6a7902f1f07e407008941b0fb8315a27))


### Bug Fixes

* **ci:** harden release candidate validation ([f03c1b7](https://github.com/P4suta/beamtrace/commit/f03c1b7716e0d4bb3dd9dc99ad10d2388c43a2db))
* harden portable gates and dependency boundaries ([#3](https://github.com/P4suta/beamtrace/issues/3)) ([9bd90dc](https://github.com/P4suta/beamtrace/commit/9bd90dced4bd0e4ebf7d9a5cba711905f7a0fcc0))


### Security

* harden supply-chain and fuzzing gates ([#4](https://github.com/P4suta/beamtrace/issues/4)) ([42976c1](https://github.com/P4suta/beamtrace/commit/42976c1f276083f7f75523e4c8e9b3e8b230d911))
