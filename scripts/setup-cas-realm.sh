#!/usr/bin/env bash
#
# Configure Keycloak so the local CAS server can use it as a delegated IdP.
# Creates a realm `cas` with one OIDC client and one SAML client, plus a test
# user. Idempotent: it deletes and recreates the `cas` realm each run.
#
# Prereq: Keycloak running on http://localhost:8080 (admin/admin).
# Usage:   ./scripts/setup-cas-realm.sh
set -euo pipefail

KC=${KC_URL:-http://localhost:8080}
ADMIN=${KC_ADMIN:-admin}
ADMIN_PW=${KC_ADMIN_PASSWORD:-admin}
REALM=${REALM:-cas}

# Where CAS runs locally. 8080 is taken by Keycloak, so CAS uses 8081 here.
# Must match `cas.server.prefix` when you run CAS. pac4j callback is <prefix>/login.
CAS_PREFIX=${CAS_PREFIX:-http://localhost:8081}

echo ">> getting admin token"
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" -d grant_type=password \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "ERROR: could not get admin token"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"
JSON="Content-Type: application/json"

echo ">> (re)creating realm '$REALM'"
curl -s -o /dev/null -X DELETE "$KC/admin/realms/$REALM" -H "$AUTH" || true
curl -s -o /dev/null -w "   realm -> %{http_code}\n" -X POST "$KC/admin/realms" -H "$AUTH" -H "$JSON" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"CAS delegated IdP test\"}"

echo ">> creating OIDC client 'cas-oidc'"
curl -s -o /dev/null -w "   oidc client -> %{http_code}\n" -X POST "$KC/admin/realms/$REALM/clients" -H "$AUTH" -H "$JSON" -d "{
  \"clientId\": \"cas-oidc\",
  \"name\": \"CAS (delegated OIDC)\",
  \"protocol\": \"openid-connect\",
  \"publicClient\": false,
  \"standardFlowEnabled\": true,
  \"directAccessGrantsEnabled\": false,
  \"redirectUris\": [\"$CAS_PREFIX/login*\", \"https://localhost:8443/login*\"],
  \"webOrigins\": [\"+\"],
  \"attributes\": {\"post.logout.redirect.uris\": \"+\"}
}"

# Fetch the generated client secret
OIDC_ID=$(curl -s "$KC/admin/realms/$REALM/clients?clientId=cas-oidc" -H "$AUTH" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
OIDC_SECRET=$(curl -s "$KC/admin/realms/$REALM/clients/$OIDC_ID/client-secret" -H "$AUTH" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')

echo ">> creating SAML client 'cas-saml'"
curl -s -o /dev/null -w "   saml client -> %{http_code}\n" -X POST "$KC/admin/realms/$REALM/clients" -H "$AUTH" -H "$JSON" -d "{
  \"clientId\": \"cas-saml\",
  \"name\": \"CAS (delegated SAML)\",
  \"protocol\": \"saml\",
  \"enabled\": true,
  \"frontchannelLogout\": true,
  \"redirectUris\": [\"$CAS_PREFIX/login*\"],
  \"attributes\": {
    \"saml.assertion.signature\": \"true\",
    \"saml.server.signature\": \"true\",
    \"saml.client.signature\": \"false\",
    \"saml.authnstatement\": \"true\",
    \"saml_name_id_format\": \"username\",
    \"saml_assertion_consumer_url_post\": \"$CAS_PREFIX/login?client_name=KeycloakSaml\",
    \"saml_single_logout_service_url_post\": \"$CAS_PREFIX/logout\"
  }
}"

echo ">> creating test user 'casuser' / 'password'"
curl -s -o /dev/null -w "   user -> %{http_code}\n" -X POST "$KC/admin/realms/$REALM/users" -H "$AUTH" -H "$JSON" -d "{
  \"username\": \"casuser\",
  \"enabled\": true,
  \"emailVerified\": true,
  \"email\": \"casuser@example.com\",
  \"firstName\": \"Cas\",
  \"lastName\": \"User\",
  \"credentials\": [{\"type\":\"password\",\"value\":\"password\",\"temporary\":false}]
}"

cat <<EOF

============================================================
 Keycloak configured for CAS delegated auth.
 Realm:        $REALM
 Test user:    casuser / password
 OIDC client:  cas-oidc
 OIDC secret:  $OIDC_SECRET
 SAML client:  cas-saml
------------------------------------------------------------
 Endpoints for CAS:
   OIDC discovery: $KC/realms/$REALM/.well-known/openid-configuration
   SAML IdP meta:  $KC/realms/$REALM/protocol/saml/descriptor
============================================================
EOF
