# Jasypt SHA-256 password hash provider

Verify-only Keycloak `PasswordHashProvider` (SPI id **`jasypt-sha256`**) that
understands the legacy CAS Jasypt digests, so existing users can be imported into
Keycloak **without changing their password**.

## Why

The legacy CAS "login with Mongo" path hashes passwords with Jasypt
(`GenericPasswordEncoder` → `StandardStringDigester`): `SHA-256`, a fixed salt,
`strength` iterations. Keycloak has no built-in verifier for that format. This
provider adds one so the stored hashes can be imported as-is.

On the first successful login Keycloak re-hashes the password with the realm
default (Argon2) and replaces the credential. The legacy hash is therefore
transient; users never notice, and the end state is Argon2.

## Hash format it verifies

```
stored = Base64( SHA-256( salt || UTF8(NFC(password)) ) )      # iterations == 1
# iterations > 1: the raw digest is re-hashed (iterations-1) more times, no salt
```

The salt is the CAS `StringFixedSaltGenerator` value, truncated to
`salt-byte-size` bytes and shared by all users. It is supplied per credential via
`secretData.salt`, so this provider needs no configuration.

## Build

```
mvn -f providers/jasypt-hash/pom.xml package
# -> target/keycloak-jasypt-hash.jar  (dependency-free; only JDK crypto)
```

The image `Dockerfile` compiles this in a Maven stage and copies the jar into
`/opt/keycloak/providers/` before `kc.sh build`, so it is baked into the
optimized server automatically.

`keycloak.version` in `pom.xml` is compile-only (`provided` scope). The provider
uses only long-stable SPI, so a jar compiled against that version runs on the
`26.1` runtime image.

## Import format

Copy the Mongo `encrypted_password` verbatim; supply the salt as the Base64 of
the salt bytes. Example (`strength=1`, salt `a2ca73669110422c87cf5ea58f924e88`,
`salt-byte-size=20` → first 20 bytes `a2ca73669110422c87cf`):

```json
{
  "type": "password",
  "credentialData": "{\"hashIterations\":1,\"algorithm\":\"jasypt-sha256\",\"additionalParameters\":{}}",
  "secretData": "{\"value\":\"<encrypted_password>\",\"salt\":\"YTJjYTczNjY5MTEwNDIyYzg3Y2Y=\",\"additionalParameters\":{}}"
}
```

Load via the Admin API (`POST /admin/realms/<realm>/users`) or, for bulk,
`POST /admin/realms/<realm>/partialImport`. Keep the realm password policy on
Argon2 — do **not** set the realm hashing algorithm to `jasypt-sha256` (the
provider is verify-only and refuses to hash new passwords).

**Confirm the production salt / `salt-byte-size` / `strength`** before a bulk
import, and validate against one account whose plaintext is known.

## Retirement

Once no credentials remain on the legacy algorithm, remove the jar and rebuild:

```sql
select count(*) from credential
where type = 'password' and credential_data like '%jasypt-sha256%';
```
