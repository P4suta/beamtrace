# SPDX-License-Identifier: Apache-2.0 OR MIT
FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine@sha256:7c82e4a284b7c05c26eac34db497ea0e63ce7cb04bd019d966d70338eb172b68 AS builder

RUN apk add --no-cache build-base=0.5-r3 git=2.52.0-r0
WORKDIR /src
COPY packages/beamtrace_core packages/beamtrace_core
COPY packages/beamtrace_tui packages/beamtrace_tui
COPY packages/beamtrace_web packages/beamtrace_web
COPY packages/beamtrace_runtime packages/beamtrace_runtime
COPY agent agent

WORKDIR /src/packages/beamtrace_web
RUN gleam deps download \
    && gleam run -m lustre/dev build
WORKDIR /src
RUN mkdir -p /out/agent \
    && erlc +debug_info -Werror -o /out/agent agent/src/beamtrace_agent.erl
WORKDIR /src/packages/beamtrace_runtime
RUN gleam deps download \
    && gleam export erlang-shipment

FROM erlang:29-alpine@sha256:77074ad338ad7303c2f127eb686759721dffbff952f7c8db162bb4adac1e1e1c

LABEL org.opencontainers.image.title="BeamTrace" \
      org.opencontainers.image.description="BEAM causal workbench" \
      org.opencontainers.image.licenses="Apache-2.0 OR MIT"

RUN apk add --no-cache ca-certificates=20260611-r0 \
    && addgroup -S -g 10001 beamtrace \
    && adduser -S -D -H -u 10001 -G beamtrace beamtrace \
    && mkdir -p /opt/beamtrace /var/lib/beamtrace \
    && chown -R beamtrace:beamtrace /var/lib/beamtrace

COPY --from=builder /src/packages/beamtrace_runtime/build/erlang-shipment /opt/beamtrace/runtime
COPY --from=builder /out/agent/beamtrace_agent.beam /opt/beamtrace/beamtrace_agent.beam
COPY --from=builder /src/packages/beamtrace_web/dist /opt/beamtrace/web

ENV BEAMTRACE_AGENT_BEAM=/opt/beamtrace/beamtrace_agent.beam \
    BEAMTRACE_WEB_ROOT=/opt/beamtrace/web \
    BEAMTRACE_DATA_DIR=/var/lib/beamtrace

VOLUME ["/var/lib/beamtrace"]
EXPOSE 4040
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/bin/wget", "-q", "--spider", "-T", "2", "http://127.0.0.1:4040/api/v2/ready"]
USER 10001:10001
WORKDIR /var/lib/beamtrace
ENTRYPOINT ["/bin/sh", "/opt/beamtrace/runtime/entrypoint.sh", "run"]
CMD ["serve", "--port", "4040", "--no-open"]
