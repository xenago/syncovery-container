# syntax=docker/dockerfile:1
# The above directive must be the first line; it enables newer Dockerfile syntax features

# ================
# Builder stage - download, verify, and extract Syncovery

FROM docker.io/debian:13-slim AS builder
# Include TLS certificates from the matching Apache Debian image to enable HTTPS initially (Debian base does not contain certs).
# Keep httpd's tag on the same Debian release as the base image above: Dependabot bumps the two independently,
# so if they drift apart the certs would come from a different Debian release than the runtime.
COPY --from=docker.io/httpd:trixie /etc/ssl /etc/ssl
COPY --from=docker.io/httpd:trixie /lib/ssl /lib/ssl

# Syncovery install location (extraction target, copied into the runtime stage below)
ENV SYNCOVERY_INSTALL_DIR=/syncovery

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBCONF_NOWARNINGS="yes"
# Update the sources list to be HTTPS, then install only what is needed to fetch and verify the tarball
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl && \
    rm -rf /var/lib/apt/lists/*

# Install Syncovery:
# The latest version, download URL, and SHA256 per architecture are published in pointer files
# (URL on line 3, version on line 5, SHA256 on line 7):
# - https://www.syncovery.com/linver_x86_64-Web.tar.gz.txt
# - https://www.syncovery.com/linver_aarch64-Web.tar.gz.txt
# The build uses the URL published in the pointer file when its version matches the pinned SYNCOVERY_VERSION,
# and verifies the download against the published SHA256.
# The pointer always tracks the latest release, so building an older pinned version falls back to a URL reconstructed from the version, with no checksum verification.
# If the pointer is unreachable the build fails rather than guessing.
# See sc_version_detector.sh, which performs automated bumps.
ARG TARGETARCH
ARG SYNCOVERY_VERSION=11.17.2
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) sc_arch=x86_64;  sc_pointer="https://www.syncovery.com/linver_x86_64-Web.tar.gz.txt" ;; \
      arm64) sc_arch=aarch64; sc_pointer="https://www.syncovery.com/linver_aarch64-Web.tar.gz.txt" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p "$SYNCOVERY_INSTALL_DIR"; \
    sc_url="https://www.syncovery.com/release/SyncoveryCL-${sc_arch}-${SYNCOVERY_VERSION}-Web.tar.gz"; \
    sc_sha256=""; \
    sc_pointer_info="$(curl -fsSL "$sc_pointer")" || { echo "ERROR: could not fetch Syncovery pointer file: $sc_pointer" >&2; exit 1; }; \
    sc_pointer_version="$(printf '%s\n' "$sc_pointer_info" | sed -n '5p' | tr -d '[:space:]')"; \
    sc_pointer_url="$(printf '%s\n' "$sc_pointer_info" | sed -n '3p' | tr -d '[:space:]')"; \
    sc_pointer_sha256="$(printf '%s\n' "$sc_pointer_info" | sed -n '7p' | tr -d '[:space:]')"; \
    if [ "$sc_pointer_version" = "$SYNCOVERY_VERSION" ] && [ -n "$sc_pointer_url" ]; then \
      sc_url="$sc_pointer_url"; \
      sc_sha256="$sc_pointer_sha256"; \
    fi; \
    curl -fsSLo /tmp/syncovery.tar.gz "$sc_url"; \
    if [ -n "$sc_sha256" ]; then \
      echo "${sc_sha256}  /tmp/syncovery.tar.gz" | sha256sum -c - || { echo "ERROR: Syncovery download failed SHA256 verification" >&2; exit 1; }; \
    else \
      echo "WARNING: no SHA256 for ${SYNCOVERY_VERSION}; skipping checksum verification" >&2; \
    fi; \
    tar -xf /tmp/syncovery.tar.gz --directory "$SYNCOVERY_INSTALL_DIR"; \
    rm /tmp/syncovery.tar.gz; \
    chmod +x "$SYNCOVERY_INSTALL_DIR/SyncoveryCL"

# ================
# Runtime stage - minimal contents

# Use Debian stable as the base image
FROM docker.io/debian:13-slim
# Include TLS certificates from Apache image derived from the matching base Debian release to enable HTTPS initially (Debian base does not contain certs).
COPY --from=docker.io/httpd:trixie /etc/ssl /etc/ssl
COPY --from=docker.io/httpd:trixie /lib/ssl /lib/ssl

# Label using OCI image labels https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.url="https://github.com/xenago/syncovery-container"
LABEL org.opencontainers.image.source="https://github.com/xenago/syncovery-container"
LABEL org.opencontainers.image.title="Syncovery"
LABEL org.opencontainers.image.description="Containerized Syncovery"
LABEL org.opencontainers.image.licenses="MIT"

# Specify Syncovery install and config locations
ENV SYNCOVERY_INSTALL_DIR=/syncovery
ENV SYNCOVERY_HOME=/config

# Set default timezone to UTC (can be overridden at runtime)
ENV TZ=Etc/UTC

# Use UTF-8 for Python IO streams
ENV PYTHONIOENCODING=UTF-8
# Do not buffer Python output
ENV PYTHONUNBUFFERED=1
# Do not cache .pyc bytecode since the scripts run once per container lifetime
ENV PYTHONDONTWRITEBYTECODE=1

# Install general dependencies:
# - ca-certificates     (Cert bundle)
# - libcrypto++         (Used by Syncovery)
# - libsmbclient        (Used by Syncovery)
# - libssl-dev          (Used by Syncovery)
# - locales             (Used for internationalization/timezones)
# - openssh-client      (Used by Syncovery)
# - openssl             (Used by Syncovery)
# - procps              (Access to basic commands like `kill`, used for startup/orchestration)
# - python3             (System Python, used by the container init scripts)
# - rsyslog             (Log management with syslog)
# - sqlite3             (Used by Syncovery)
# - supervisor          (Service manager)
# - tini                (Init/PID 1)
# - tzdata              (Timezone DB)
ARG DEBIAN_FRONTEND=noninteractive
ARG DEBCONF_NOWARNINGS="yes"
# Update the sources list to be HTTPS before downloading
# Install container and Syncovery -specific dependencies
# Based on info posted by Stefan Ruepp on the Syncovery forum:
# - https://www.syncovery.com/forum/viewtopic.php?t=42
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libcrypto++ \
    libsmbclient \
    libssl-dev \
    locales \
    openssh-client \
    openssl \
    procps \
    python3 \
    rsyslog \
    sqlite3 \
    supervisor \
    tini \
    tzdata && \
    apt-get autoremove -y && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt/archives/* && \
    rm -rf /var/tmp/* && \
    rm -rf /tmp/*

# Import supervisord configs
COPY config/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/supervisor/conf.d/* /etc/supervisor/conf.d/

# Import rsyslog configs
COPY config/rsyslog/rsyslog.conf /etc/rsyslog.conf
COPY config/rsyslog/rsyslog.d/* /etc/rsyslog.d/

# Syncovery is downloaded and verified in the builder stage
COPY --from=builder /syncovery /syncovery

# Import container management code
COPY app/ /app/
RUN chmod +x /app/startup.sh

# Create the persistent config mount point and prepare machine-id.
# Syncovery sometimes uses /etc/machine-id when storing credentials, so it is persisted via a mount.
RUN mkdir -p /config && \
    rm -f /etc/machine-id && \
    mkdir -p /var/lib/dbus && \
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Syncovery uses /tmp for temporary/scratch files, which can be large during backups.
# Declare it a volume to keep that data off the container's writable layer.
VOLUME /tmp

# Tie reported container health to the Syncovery process being alive. The web UI's port and bind
# address are user-configurable (and the web server can be disabled entirely), so an HTTP probe on
# a fixed port would mark a healthy but reconfigured container as unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ps -e -o comm= | grep -qx SyncoveryCL || exit 1

# Define expected ports
# Cloud authentication
EXPOSE 8889
# HTTPS Web UI (if enabled in Syncovery)
EXPOSE 8943
# Remote
EXPOSE 8949
# Web UI
EXPOSE 8999

# Handle signals and run startup script
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/startup.sh"]
