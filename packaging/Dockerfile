# SPDX-License-Identifier: Apache-2.0 OR MIT
FROM oven/bun:1.4.4-alpine@sha256:4cf82f5686b196504fe119db3fcd9185b191f82ece82c40680e597228ec6070a AS bun

FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine@sha256:64b1df35a9611332d51f77c97f16f50ec97863162ba8824400ed4c8dff6378ac AS builder

RUN apk add --no-cache build-base git
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
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

FROM erlang:29-alpine@sha256:8cd3da3d4d04563479655f7b1d8cf24f075e3ab8f665f21ca18eab1593365256

LABEL org.opencontainers.image.title="BeamTrace" \
      org.opencontainers.image.description="BEAM causal workbench" \
      org.opencontainers.image.licenses="Apache-2.0 OR MIT"

RUN apk add --no-cache ca-certificates \
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
