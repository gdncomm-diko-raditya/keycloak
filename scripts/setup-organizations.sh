#!/usr/bin/env bash
#
# Multitenancy demo using Keycloak 26 Organizations.
# In ONE realm (`cas`) we model 3 tenants (Company A/B/C), each an Organization
# with its own email domain and 3 member users.
#
#   realm: cas
#   ├── Organization "Company A"  (domain companya.test)  → usera1..3
#   ├── Organization "Company B"  (domain companyb.test)  → userb1..3
#   └── Organization "Company C"  (domain companyc.test)  → userc1..3
#
# Every user password is `password`. Idempotent-ish: re-running re-adds users
# that don't exist; orgs already present are skipped.
set -euo pipefail

KC=${KC_URL:-http://localhost:8080}
REALM=${REALM:-cas}
ADMIN=${KC_ADMIN:-admin}; ADMIN_PW=${KC_ADMIN_PASSWORD:-admin}

# admin-cli access tokens expire in ~60s, so fetch a fresh one before each call.
tok() { curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" -d grant_type=password \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }
auth() { echo "Authorization: Bearer $(tok)"; }
JSON="Content-Type: application/json"
[ -n "$(tok)" ] || { echo "no admin token"; exit 1; }

echo ">> 1) enable Organizations on realm '$REALM'"
curl -s -o /dev/null -w "   realm update -> %{http_code}\n" -X PUT "$KC/admin/realms/$REALM" \
  -H "$(auth)" -H "$JSON" -d '{"realm":"'"$REALM"'","organizationsEnabled":true}'

# company name | alias | domain | user-prefix
TENANTS=(
  "Company A|company-a|companya.test|usera"
  "Company B|company-b|companyb.test|userb"
  "Company C|company-c|companyc.test|userc"
)

create_user() {  # $1=username $2=email  -> echoes user id
  local uname="$1" email="$2"
  curl -s -o /dev/null -X POST "$KC/admin/realms/$REALM/users" -H "$(auth)" -H "$JSON" -d '{
    "username":"'"$uname"'","email":"'"$email"'","emailVerified":true,"enabled":true,
    "firstName":"'"$uname"'","lastName":"User",
    "credentials":[{"type":"password","value":"password","temporary":false}]
  }'
  curl -s "$KC/admin/realms/$REALM/users?username=$uname&exact=true" -H "$(auth)" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1
}

# Resolve an organization id by alias from the full list (search param is unreliable).
org_id_by_alias() {  # $1=alias
  curl -s "$KC/admin/realms/$REALM/organizations" -H "$(auth)" \
    | tr '}' '\n' | grep "\"alias\":\"$1\"" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1
}

for t in "${TENANTS[@]}"; do
  IFS='|' read -r NAME ALIAS DOMAIN PREFIX <<< "$t"
  echo ">> 2) organization '$NAME' (domain $DOMAIN)"
  curl -s -o /dev/null -w "   org create -> %{http_code}\n" -X POST "$KC/admin/realms/$REALM/organizations" \
    -H "$(auth)" -H "$JSON" -d '{
      "name":"'"$NAME"'","alias":"'"$ALIAS"'","enabled":true,
      "domains":[{"name":"'"$DOMAIN"'","verified":true}]
    }'
  ORG_ID=$(org_id_by_alias "$ALIAS")
  echo "   org id: $ORG_ID"

  for n in 1 2 3; do
    UNAME="${PREFIX}${n}"; EMAIL="${UNAME}@${DOMAIN}"
    UID_=$(create_user "$UNAME" "$EMAIL")
    # add user as a member of the organization (body = user id as a JSON string)
    MC=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC/admin/realms/$REALM/organizations/$ORG_ID/members" \
      -H "$(auth)" -H "Content-Type: application/json" -d "\"$UID_\"")
    echo "   user $UNAME ($EMAIL) id=$UID_  member-add->$MC"
  done
done

echo ">> 3) emit the organization (tenant) claim to CAS clients"
# OIDC: make the built-in 'organization' client scope DEFAULT on cas-oidc so the
# `organization` claim is always present (Keycloak assigns it as optional by default).
ORG_SCOPE=$(curl -s "$KC/admin/realms/$REALM/client-scopes" -H "$(auth)" \
  | tr '}' '\n' | grep '"name":"organization"' | grep 'openid-connect' \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
OID=$(curl -s "$KC/admin/realms/$REALM/clients?clientId=cas-oidc" -H "$(auth)" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$ORG_SCOPE" ] && [ -n "$OID" ]; then
  curl -s -o /dev/null -X DELETE "$KC/admin/realms/$REALM/clients/$OID/optional-client-scopes/$ORG_SCOPE" -H "$(auth)" || true
  curl -s -o /dev/null -w "   cas-oidc default org scope -> %{http_code}\n" -X PUT \
    "$KC/admin/realms/$REALM/clients/$OID/default-client-scopes/$ORG_SCOPE" -H "$(auth)"
fi
# SAML: add the org membership mapper directly to cas-saml (SAML has no scopes).
SID=$(curl -s "$KC/admin/realms/$REALM/clients?clientId=cas-saml" -H "$(auth)" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$SID" ]; then
  curl -s -o /dev/null -w "   cas-saml org mapper -> %{http_code}\n" -X POST \
    "$KC/admin/realms/$REALM/clients/$SID/protocol-mappers/models" -H "$(auth)" -H "$JSON" -d '{
      "name":"organization","protocol":"saml","protocolMapper":"saml-organization-membership-mapper","config":{}
    }' || true
fi

echo
echo "Done. Verify:"
echo "  orgs:    $KC/admin/realms/$REALM/organizations"
echo "  members: pick an org id above, GET /organizations/{id}/members"
echo "  claim:   an OIDC token for an org user now carries  organization: [\"company-x\"]"
