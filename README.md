# Keycloak In-House IdP — Exploration

Running [Keycloak](https://www.keycloak.org/) as an in-house Identity Provider, backed by PostgreSQL, in Docker/Podman. A three-step exploration:

- **Step 1 — Run Keycloak locally** (this step): custom Dockerfile, PostgreSQL, verify OIDC & SAML.
- **Step 2 — Custom theme/layout**: brand the login pages, rebuild, verify.
- **Step 3 — Custom SPI**: extend functionality (e.g. email OTP), rebuild, verify.

---

## Step 1 — Run Keycloak locally

### Prerequisites
- Docker (with `docker compose`) **or** Podman with a running machine.
- ~1 GB free disk for images.

### Layout
```
.
├── Dockerfile          # optimized Keycloak image, baked for postgres
├── docker-compose.yml  # keycloak + postgres
├── .env.example        # copy to .env to override defaults
└── README.md
```

### Run with Docker Compose
```bash
cp .env.example .env          # optional, defaults are fine for local
docker compose up --build
```

### Run with Podman (no compose)
The repo ships a helper script that builds the image and runs both containers
on a shared pod/network using plain `podman` commands:
```bash
./scripts/run-podman.sh up      # build + start
./scripts/run-podman.sh logs    # follow keycloak logs
./scripts/run-podman.sh down     # stop + remove
```

### Verify it's up
- Admin console: <http://localhost:8080/> → **Administration Console**
  - Login: `admin` / `admin` (from `.env`)
- Health: <http://localhost:9000/health/ready> → `{"status": "UP"}`
- The DB tables are created in the `keycloak` Postgres database on first boot.

### Verify OIDC login
1. In the admin console create a realm, e.g. `demo`.
2. **Clients → Create client** → type *OpenID Connect*, id `demo-oidc`.
   - Set a valid redirect URI (e.g. `https://www.keycloak.org/app/*` for the
     official test app, or your app's callback).
3. Use Keycloak's OIDC endpoints (discovery document):
   `http://localhost:8080/realms/demo/.well-known/openid-configuration`
4. Create a user under the realm and test the login flow.

### Verify SAML login
1. In the same realm, **Clients → Create client** → type *SAML*.
2. Keycloak's SAML IdP metadata is at:
   `http://localhost:8080/realms/demo/protocol/saml/descriptor`
3. Point a SAML SP at that metadata, or use the SAML test client and complete
   a login with the realm user.

### Use Keycloak as the IdP for the local CAS server
To make the local Apereo CAS server (`Code/cas`) delegate login to this Keycloak
over OIDC **and** SAML:
- `./scripts/setup-cas-realm.sh` — realm `cas` + OIDC/SAML clients + a test user
- `./scripts/setup-organizations.sh` — **multitenancy**: Companies A/B/C as
  Keycloak Organizations, 9 users, and the `organization` (tenant) claim wired
  into both clients. See [docs/keycloak-multitenancy.md](docs/keycloak-multitenancy.md).
- Then follow [docs/cas-integration.md](docs/cas-integration.md) (pac4j config +
  the CAS service-registry step that actually shows the Keycloak login).

---

## Configuration

All settings have local-friendly defaults in `docker-compose.yml`; override via `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `KEYCLOAK_VERSION` | `26.1` | Keycloak image tag |
| `KC_DB_NAME` / `KC_DB_USER` / `KC_DB_PASSWORD` | `keycloak` | Postgres credentials |
| `KC_ADMIN` / `KC_ADMIN_PASSWORD` | `admin` | Bootstrap admin (first boot only) |

> **Local only.** `KC_HTTP_ENABLED=true` and `KC_HOSTNAME_STRICT=false` make
> local testing easy but must not be used in production.

---

## Database: external & DBA-managed

Keycloak needs a Postgres database, but **we do not provision or ship one** for
real environments — the **DBA provisions it**, and Keycloak simply points at it.

The split is deliberate:

- **Baked into the image (build time):** only the DB *vendor*, via `KC_DB=postgres`
  in the [`Dockerfile`](Dockerfile). This just selects the Postgres JDBC driver.
- **Provided at runtime (deploy time):** the actual connection — `KC_DB_URL`,
  `KC_DB_USERNAME`, `KC_DB_PASSWORD`. In qa2/prod these come from the DBA and are
  injected as secret-backed env by the (separate) deployment repo. **No host,
  credential, or DB name is ever committed or baked into the image.**

So the same image runs against any Postgres just by changing three env vars.

| Mode | How | Postgres source |
|---|---|---|
| Local dev | `docker compose up --build` | bundled throwaway container in [`docker-compose.yml`](docker-compose.yml) |
| Point at a real DB | `docker compose -f docker-compose.external-db.yml up --build` | external, set `KC_DB_URL`/`KC_DB_USERNAME`/`KC_DB_PASSWORD` in `.env` |
| qa2 / prod | deployment repo (later) | DBA-provisioned; only the 3 `KC_DB_*` values supplied |

The bundled Postgres in `docker-compose.yml` exists **only** so you can run
Keycloak on your laptop without a database handy — it is never used in a real
environment.

---

## CI: build & push the image (Jenkins → Artifact Registry)

This repo is structured like gdncomm's other app repos (e.g. `mcp-customer-exp`)
so the shared Jenkins pipeline can build and push the image — no manual push.

The build inputs are these files at the repo root:

| File | Role |
|---|---|
| [`Dockerfile`](Dockerfile) | Builds the optimized Keycloak image. Defaults to `CMD ["start","--optimized"]` so it boots with no extra args. |
| [`.dockerignore`](.dockerignore) | Keeps the build context small (excludes local-dev/docs). |
| [`pom.xml`](pom.xml) | **Version carrier** the pipeline reads to tag the image. Not a real Maven build — bump `<version>` to cut a new image version. Mirrors mcp-customer-exp's build-branch pom. |
| [`Jenkinsfile`](Jenkinsfile) | `@Library('jenkins-ci-automation@develop')` → `BlibliPipeline([type:'docker', ...])`. Builds the Dockerfile and pushes to `asia-southeast1-docker.pkg.dev/nonprod-utility-233414/docker-releases/blibli-apps`, tribe/squad `iam`, `service_name: keycloak`. |

Jenkins fetches this repo from GitHub, runs `BlibliPipeline`, reads the version
from `pom.xml`, and publishes the image to Artifact Registry (GCR) with a tag
like `keycloak-...-1.0.0-1-SNAPSHOT`. Deployment is a **separate repo** (Helm
values + a deploy Jenkinsfile) to be created later — same split as
`mcp-customer-exp` / `nonprod-deployment-gdn-mcp-customer-exp`.

## Notes on the Dockerfile
The image uses Keycloak's recommended two-stage build: stage 1 runs
`kc.sh build` with `KC_DB=postgres` baked in, stage 2 is a slim runtime started
with `start --optimized` (skips the build step at boot). Steps 2 & 3 add
`themes/` and `providers/` into the builder stage.
