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

## Deploying to Kubernetes (gdncomm convention)

gdncomm ships services with a **two-repo, two-pipeline** model on Jenkins +
a shared Helm library + **Google Artifact Registry** (`asia-southeast1`):

- **This (app) repo** builds & pushes the image. [`Jenkinsfile`](Jenkinsfile)
  uses `BlibliPipeline([type:'docker', ...])` to build the Dockerfile and push
  to Artifact Registry. The Dockerfile defaults to `CMD ["start","--optimized"]`
  so the image boots correctly when the chart runs it with no args.
- **A separate deployment repo** (`nonprod-deployment-gdn-keycloak`, branch per
  env) deploys it via the shared chart, supplying only Helm values. A template
  for that repo lives in [`deploy/`](deploy/) — see [`deploy/README.md`](deploy/README.md).

**Keycloak-specific gaps to resolve with the platform team** (it's stateful and
JVM-heavy, unlike the stateless Node apps the chart assumes): a PostgreSQL
source (CloudSQL vs in-cluster), secret-backed DB/admin credentials, the health
probe port (9000 vs 8080), and right-sized resources. All flagged in
[`deploy/README.md`](deploy/README.md).

## Notes on the Dockerfile
The image uses Keycloak's recommended two-stage build: stage 1 runs
`kc.sh build` with `KC_DB=postgres` baked in, stage 2 is a slim runtime started
with `start --optimized` (skips the build step at boot). Steps 2 & 3 add
`themes/` and `providers/` into the builder stage.
