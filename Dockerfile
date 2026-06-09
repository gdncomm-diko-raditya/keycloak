# syntax=docker/dockerfile:1
#
# Optimized Keycloak image configured for PostgreSQL.
#
# Keycloak's recommended production pattern is a two-stage build: run
# `kc.sh build` once to bake the chosen feature/DB configuration into the
# image, then ship a slim runtime that starts with `--optimized` (no build
# step at boot). See https://www.keycloak.org/server/containers
#
# Build args let you pin the Keycloak version without editing the file.
ARG KEYCLOAK_VERSION=26.1

# ---------------------------------------------------------------------------
# Stage 1 — builder: produce an augmented/optimized server
# ---------------------------------------------------------------------------
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

# Database vendor is baked in at build time so it can't be changed at runtime.
ENV KC_DB=postgres

# Expose health + metrics endpoints (used by container healthchecks / probes).
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

# Steps 2 & 3 of the exploration drop custom themes and SPI providers here.
# They are picked up by the build below. Kept as commented examples for now:
# COPY themes/   /opt/keycloak/themes/
# COPY providers/*.jar /opt/keycloak/providers/

WORKDIR /opt/keycloak
RUN /opt/keycloak/bin/kc.sh build

# ---------------------------------------------------------------------------
# Stage 2 — runtime: slim image that starts already optimized
# ---------------------------------------------------------------------------
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# 8080 = HTTP (app), 9000 = management (health/metrics).
EXPOSE 8080 9000

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
# Default to an optimized start so the image boots correctly when an
# orchestrator (e.g. the shared Helm chart) runs it with no extra args.
# Overridable: `docker run <img> start-dev`, or compose's `command:`.
CMD ["start", "--optimized"]
