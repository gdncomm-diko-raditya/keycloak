# Deployment template (for a separate deployment repo)

> ⚠️ **This is a template, not deployed from here.** By gdncomm convention,
> deployment lives in its own repo (e.g. `nonprod-deployment-gdn-keycloak`),
> with a **branch per environment** (`qa2`, …). Copy these files into that repo
> when ready. Mirrors `nonprod-deployment-gdn-mcp-customer-exp`.

## Layout
```
Jenkinsfile                  # @Library('gcp-jenkins-library') → app([...])
deployment/values.yaml       # base Helm values
deployment/qa2/values.yaml   # qa2 (lower env) overrides
```

## How it deploys
The shared `gcp-jenkins-library` carries the Helm chart; this repo only supplies
values. The CD job is triggered per environment branch.

## Open items to confirm with the platform team
These are Keycloak-specific gaps vs the stateless Node apps this chart assumes:

1. **PostgreSQL** — Keycloak needs a database the chart does **not** provision.
   Decide: CloudSQL (point `KC_DB_URL` at it) or an in-cluster Postgres
   (StatefulSet + PVC, deployed separately). Credentials must come from a
   **Secret**, never plaintext in `values.yaml`.
2. **Secrets mechanism** — how does the shared chart inject secret env vars
   (DB password, bootstrap admin)? The mcp app only used plaintext `env:`.
   `KC_DB_PASSWORD` / `KC_BOOTSTRAP_ADMIN_PASSWORD` must be secret-backed.
3. **Health probe port** — Keycloak serves `/health/ready` on management port
   **9000**, not 8080. Either the chart must support probing port 9000, or we
   enable the (deprecated) `--legacy-observability-interface=true` build flag so
   `/health` is served on 8080. See note in `deployment/values.yaml`.
4. **Resources** — base chart defaults are sized for Node (64Mi). Keycloak JVM
   needs ≥512Mi (overridden below).
5. **Image registry path & tag** — confirm where the app-repo CI publishes
   (`docker-releases/blibli-apps` vs `docker-snapshots/base-images`) and the tag
   format, then set `image.repository` / `image.tag` to match.
