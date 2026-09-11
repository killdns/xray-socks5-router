ARG ALPINE_IMAGE=alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG XRAY_IMAGE=ghcr.io/xtls/xray-core:26.7.28@sha256:b697cda1588faca696ab7f7755dd1161f60862af3ff6026300e44cff6aedd558

FROM ${ALPINE_IMAGE} AS hev-socks5-build

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG HEV_SOCKS5_VERSION=2.13.1
ARG HEV_SOCKS5_SHA256=aecff4c35d7ffa6458ff55512b04d00c1d102ddc3fbee466534a9b1876022da4

# Alpine package revisions intentionally follow the selected stable branch.
# hadolint ignore=DL3018
RUN apk add --no-cache build-base curl xz \
    && curl -fsSL "https://github.com/heiher/hev-socks5-server/releases/download/${HEV_SOCKS5_VERSION}/hev-socks5-server-${HEV_SOCKS5_VERSION}.tar.xz" -o /tmp/hev-socks5-server.tar.xz \
    && echo "${HEV_SOCKS5_SHA256}  /tmp/hev-socks5-server.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/hev-socks5-server \
    && tar -xJf /tmp/hev-socks5-server.tar.xz -C /tmp/hev-socks5-server --strip-components=1 \
    && make -C /tmp/hev-socks5-server ENABLE_STATIC=1 -j2

FROM ${XRAY_IMAGE} AS xray

FROM ${ALPINE_IMAGE}

ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE_URL="https://github.com/killdns/xray-socks5-router"
ARG XRAY_VERSION=26.7.28
ARG HEV_SOCKS5_VERSION=2.13.1

LABEL org.opencontainers.image.title="Xray SOCKS5 Router" \
      org.opencontainers.image.description="L3 Xray gateway with a HevSocks5Server frontend" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.documentation="https://hub.docker.com/r/killdns/xray-socks5-router" \
      io.killdns.xray.version="${XRAY_VERSION}" \
      io.killdns.hev-socks5-server.version="${HEV_SOCKS5_VERSION}"

# Alpine package revisions intentionally follow the selected stable branch.
# hadolint ignore=DL3018
RUN apk add --no-cache \
      ca-certificates \
      iproute2 \
      iptables \
      iptables-legacy \
      jq \
      libcap-utils \
      python3 \
      su-exec \
      tini \
    && addgroup -S socks \
    && adduser -S -D -H -s /sbin/nologin -G socks socks \
    && addgroup -S xray \
    && adduser -S -D -H -s /sbin/nologin -G xray xray \
    && install -d -o root -g root -m 0755 /run/xray-socks5-router

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=hev-socks5-build /tmp/hev-socks5-server/bin/hev-socks5-server /usr/local/bin/hev-socks5-server
COPY --from=hev-socks5-build /tmp/hev-socks5-server/LICENSE /usr/share/licenses/hev-socks5-server/LICENSE
COPY --chmod=0755 entrypoint.sh /usr/local/sbin/xray-socks5-router-entrypoint
COPY --chmod=0755 healthcheck.sh /usr/local/sbin/xray-socks5-router-healthcheck
COPY --chmod=0755 tools/vless_to_config.py /usr/local/libexec/xray-socks5-router/vless_to_config.py

EXPOSE 1080/tcp 20000-20999/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/usr/local/sbin/xray-socks5-router-healthcheck"]

STOPSIGNAL SIGTERM

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/sbin/xray-socks5-router-entrypoint"]
