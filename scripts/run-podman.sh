#!/usr/bin/env bash
#
# Run the Keycloak + PostgreSQL stack with plain podman (no compose provider).
# Mirrors docker-compose.yml. Usage: ./scripts/run-podman.sh {up|down|logs|ps}
set -euo pipefail

# Make sure podman is reachable even if not on the default PATH.
export PATH="/opt/podman/bin:$PATH"

# --- config (override via environment or .env) ---
[ -f "$(dirname "$0")/../.env" ] && set -a && . "$(dirname "$0")/../.env" && set +a
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.1}"
KC_DB_NAME="${KC_DB_NAME:-keycloak}"
KC_DB_USER="${KC_DB_USER:-keycloak}"
KC_DB_PASSWORD="${KC_DB_PASSWORD:-keycloak}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"

NET=keycloak-net
PG=keycloak-postgres
KC=keycloak
IMAGE=keycloak-idp:local
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

up() {
  podman network exists "$NET" || podman network create "$NET"

  echo ">> building $IMAGE"
  podman build --build-arg "KEYCLOAK_VERSION=${KEYCLOAK_VERSION}" -t "$IMAGE" "$ROOT"

  echo ">> starting postgres"
  podman run -d --name "$PG" --network "$NET" \
    -e POSTGRES_DB="$KC_DB_NAME" \
    -e POSTGRES_USER="$KC_DB_USER" \
    -e POSTGRES_PASSWORD="$KC_DB_PASSWORD" \
    -v keycloak_postgres_data:/var/lib/postgresql/data \
    docker.io/library/postgres:16-alpine

  echo ">> waiting for postgres to be ready"
  for i in $(seq 1 30); do
    if podman exec "$PG" pg_isready -U "$KC_DB_USER" -d "$KC_DB_NAME" >/dev/null 2>&1; then
      echo "   postgres ready"; break
    fi
    sleep 2
  done

  echo ">> starting keycloak"
  podman run -d --name "$KC" --network "$NET" \
    -p 8080:8080 -p 9000:9000 \
    -e KC_DB=postgres \
    -e KC_DB_URL="jdbc:postgresql://${PG}:5432/${KC_DB_NAME}" \
    -e KC_DB_USERNAME="$KC_DB_USER" \
    -e KC_DB_PASSWORD="$KC_DB_PASSWORD" \
    -e KC_BOOTSTRAP_ADMIN_USERNAME="$KC_ADMIN" \
    -e KC_BOOTSTRAP_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
    -e KC_HOSTNAME=localhost \
    -e KC_HOSTNAME_STRICT=false \
    -e KC_HTTP_ENABLED=true \
    -e KC_HEALTH_ENABLED=true \
    -e KC_METRICS_ENABLED=true \
    "$IMAGE" start --optimized

  echo ">> stack starting. Admin console: http://localhost:8080/"
}

down() {
  podman rm -f "$KC" "$PG" 2>/dev/null || true
  echo ">> removed containers (volume keycloak_postgres_data kept)"
}

case "${1:-up}" in
  up)   up ;;
  down) down ;;
  logs) podman logs -f "$KC" ;;
  ps)   podman ps --filter "network=$NET" ;;
  *)    echo "usage: $0 {up|down|logs|ps}"; exit 1 ;;
esac
