# CAS ↔ Keycloak (delegated authentication, local)

Make the local **Apereo CAS** server (`Code/cas`) delegate login to this local
**Keycloak** as an external IdP — over both **OIDC** and **SAML**.

CAS is already built with `cas-server-support-pac4j-oidc` and
`cas-server-support-pac4j-saml`; it only needs the `cas.authn.pac4j.*`
properties below. (In real envs these come from Consul — here you supply them
locally for testing.)

## 0. Keycloak side (already done)
Run once against a running Keycloak (`admin`/`admin` on :8080):
```bash
./scripts/setup-cas-realm.sh
```
This creates:
- realm **`cas`**, test user **`casuser` / `password`**
- OIDC client **`cas-oidc`** (confidential — the script prints its secret)
- SAML client **`cas-saml`**

Endpoints CAS will use:
| | URL |
|---|---|
| OIDC discovery | `http://localhost:8080/realms/cas/.well-known/openid-configuration` |
| SAML IdP metadata | `http://localhost:8080/realms/cas/protocol/saml/descriptor` |

## ⚠️ Port conflict
Keycloak uses **8080**, and CAS also defaults to 8080. Run **CAS on 8081** so
both coexist. Set when launching CAS:
```
SERVER_PORT=8081
cas.server.prefix=http://localhost:8081
```
(The setup script registered CAS redirect/callback URLs under
`http://localhost:8081`. If you use a different prefix, re-run it with
`CAS_PREFIX=... ./scripts/setup-cas-realm.sh`.)

> If you run CAS inside a container instead of on the host, `localhost:8080`
> won't reach Keycloak — use `http://host.containers.internal:8080` (podman) /
> `host.docker.internal` (docker) in the discovery/metadata URLs.

---

## 1. OIDC — add to CAS local config
`cas.properties` (or a local override / Consul KV). Use the **generic** OIDC
client pointed at Keycloak's discovery document:
```properties
cas.authn.pac4j.oidc[0].generic.id=cas-oidc
cas.authn.pac4j.oidc[0].generic.secret=PASTE_OIDC_SECRET_FROM_SCRIPT
cas.authn.pac4j.oidc[0].generic.client-name=KeycloakOidc
cas.authn.pac4j.oidc[0].generic.discovery-uri=http://localhost:8080/realms/cas/.well-known/openid-configuration
cas.authn.pac4j.oidc[0].generic.scope=openid profile email
cas.authn.pac4j.oidc[0].generic.response-type=code
cas.authn.pac4j.oidc[0].generic.use-nonce=true
```
pac4j's OIDC callback is `http://localhost:8081/login` (Keycloak already allows
`http://localhost:8081/login*` as a redirect URI for `cas-oidc`).

## 2. SAML — add to CAS local config
```properties
cas.authn.pac4j.saml[0].client-name=KeycloakSaml
cas.authn.pac4j.saml[0].service-provider-entity-id=cas-saml
cas.authn.pac4j.saml[0].identity-provider-metadata-path=http://localhost:8080/realms/cas/protocol/saml/descriptor
# pac4j auto-generates the SP keystore + metadata on first run at these paths:
cas.authn.pac4j.saml[0].keystore-path=/tmp/cas/saml/samlKeystore.jks
cas.authn.pac4j.saml[0].keystore-password=changeit
cas.authn.pac4j.saml[0].private-key-password=changeit
cas.authn.pac4j.saml[0].service-provider-metadata-path=/tmp/cas/saml/sp-metadata.xml
```
Notes:
- `service-provider-entity-id` **must equal** the Keycloak SAML client id
  (`cas-saml`). The script set the client's ACS to
  `http://localhost:8081/login?client_name=KeycloakSaml`.
- The Keycloak client has `saml.client.signature=false`, so CAS doesn't need to
  pre-register a signing cert — good enough for local testing. For a stricter
  setup, import CAS's generated `sp-metadata.xml` into the Keycloak `cas-saml`
  client instead.

---

## 3. Service registry — REQUIRED to show the Keycloak login

Two pac4j properties are not enough. gdn-cas has a custom login flow
(`GdnInitializeLoginAction` → `GdnPrimaryLoginMode`) that decides what the login
page shows **based on the registered service in the request**:

| Mode | When | Login page shows |
|---|---|---|
| `NO_REGISTERED_SERVICE` | no/unknown `service` param | nothing (hidden) |
| `DEFAULT` | service registered, no delegated policy | generic path |
| `DELEGATED` | service's access strategy has **non-empty** delegated `allowedProviders` | the delegated IdP buttons (Keycloak) |

So to make CAS show / use the Keycloak login for a service, you **register that
service with `delegatedAuthenticationAllowedProviders` matching your pac4j
client-names**. From source (`CreateGdnRegexServiceImpl`), a non-empty list sets
`DefaultRegisteredServiceDelegatedAuthenticationPolicy.allowedProviders`, which
flips the mode to `DELEGATED`.

Register a service (values must equal the pac4j `client-name`s exactly):
```bash
curl -X POST http://localhost:8081/internal/gdn-service-registry/regex-service \
  -H 'Content-Type: application/json' -d '{
    "actor": "IAM-LOCAL",
    "host": "^(http|https)://localhost:9999.*",
    "name": "Local Keycloak Test",
    "description": "verify Keycloak delegated login",
    "delegatedAuthenticationAllowedProviders": ["KeycloakOidc", "KeycloakSaml"]
  }'
```
- `host` is a **regex** that must match the `service` URL you log in for.
  Escape dots as `\\.` in JSON (unescaped dots cause HTTP 500).
- If a service already lacks the policy, use the upsert endpoint instead:
  `PATCH /internal/gdn-service-registry/regex-service/properties` with
  `delegatedAuthenticationAllowedProviders` (it replaces the access-strategy
  delegated policy).
- The service registry is cached and reloads periodically; allow a moment (or
  restart CAS) for a new registration to take effect.

## 4. Try it
1. Start Keycloak: `./scripts/run-podman.sh up` (this repo).
2. Start CAS on 8081 with the OIDC **and** SAML pac4j properties above.
3. Register the test service (section 3) for `http://localhost:9999`.
4. Hit `http://localhost:8081/login?service=http://localhost:9999/`.
   With the delegated policy set, CAS is in `DELEGATED` mode and shows the
   **KeycloakOidc** / **KeycloakSaml** options (or, with `&client_name=KeycloakOidc`,
   redirects straight to Keycloak's authorization endpoint).
5. Log in as a tenant user, e.g. `usera1` / `password` → back to CAS,
   authenticated, with `organization: ["company-a"]` available as an attribute.

> Note: a prebuilt CAS jar may have **non-local (QA) backends baked in** — then
> its service registry is the QA Mongo, not your local one, and local
> registrations won't apply. Rebuild from source (with localhost `cas.properties`)
> for a clean local run.

## How this maps to production
Locally you hand-set `cas.authn.pac4j.*` and point at `localhost` Keycloak. In
qa2/prod the same properties come from **Consul**, pointing at the deployed
Keycloak (the image this repo builds). Nothing about the integration changes —
only the IdP URL and client secret differ per environment.
