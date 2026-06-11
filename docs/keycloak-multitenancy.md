# Multitenancy in Keycloak with Organizations

How we model **Company A / B / C, each with users 1/2/3** in a single realm using
Keycloak 26's **Organizations** feature, and how the tenant identity reaches CAS.

Reproduce everything with:
```bash
./scripts/setup-cas-realm.sh       # realm `cas` + OIDC/SAML clients + a test user
./scripts/setup-organizations.sh   # Organizations A/B/C, 9 users, org claim wiring
```

## The model

```
realm: cas   (organizationsEnabled = true)
├── Organization "Company A"  alias company-a  domain companya.test
│     members: usera1, usera2, usera3
├── Organization "Company B"  alias company-b  domain companyb.test
│     members: userb1, userb2, userb3
└── Organization "Company C"  alias company-c  domain companyc.test
      members: userc1, userc2, userc3
```
All passwords are `password`.

### Why Organizations (not realm-per-tenant or groups)
- **One realm** → one OIDC issuer + one SAML descriptor → CAS needs only **one**
  delegated OIDC client and one SAML client, not one per company.
- **Tenant is first-class**: each Organization has members, email **domains**
  (for home-org discovery), and can even have its **own brokered IdP** later.
- The tenant travels in the token as an `organization` claim — apps stay
  tenant-aware without separate endpoints per company.

## How it's built (Admin REST API)

1. **Enable the feature on the realm** (off by default):
   ```
   PUT /admin/realms/cas   { "organizationsEnabled": true }
   ```
2. **Create an organization** (note the email domain):
   ```
   POST /admin/realms/cas/organizations
   { "name":"Company A","alias":"company-a","enabled":true,
     "domains":[{"name":"companya.test","verified":true}] }
   ```
3. **Create a user**, then **add as a member** (body = the user id as a JSON string):
   ```
   POST /admin/realms/cas/users   { "username":"usera1","email":"usera1@companya.test", ... }
   POST /admin/realms/cas/organizations/{orgId}/members   "{userId}"
   ```

> Gotcha we hit: the `?search=` param on `/organizations` is unreliable — list
> all and match by `alias`. Also admin-cli tokens expire in ~60s; fetch a fresh
> one per call in scripts.

## Making the tenant claim flow to CAS

Membership alone doesn't put the tenant in the token — you need the mapper.

### OIDC
Keycloak auto-creates an **`organization`** client scope (mapper
`oidc-organization-membership-mapper`, claim `organization`). It's assigned to
clients as **optional**, so either request it or make it default. We make it
default on `cas-oidc`:
```
DELETE /clients/{casOidcId}/optional-client-scopes/{orgScopeId}
PUT    /clients/{casOidcId}/default-client-scopes/{orgScopeId}
```
Result — an access token for an org user now carries:
```json
{ "email": "usera1@companya.test", "organization": ["company-a"] }
```
Verified for all three tenants (usera1→company-a, userb2→company-b, userc3→company-c).

### SAML
SAML has no scopes, so add the mapper directly to the `cas-saml` client:
```
POST /clients/{casSamlId}/protocol-mappers/models
{ "name":"organization","protocol":"saml",
  "protocolMapper":"saml-organization-membership-mapper","config":{} }
```
The SAML assertion then includes an `organization` attribute with the tenant.

## What CAS does with it
When CAS delegates login to Keycloak (see [cas-integration.md](cas-integration.md)),
the user authenticates in Keycloak and the `organization` claim/attribute comes
back in the OIDC token / SAML assertion. CAS can map it to a principal attribute
and use it to know which tenant the user belongs to — one Keycloak, many tenants.
```
usera1 logs in via CAS → Keycloak → token { organization: ["company-a"] } → CAS knows tenant = Company A
```
