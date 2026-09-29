package com.gdn.iam.keycloak.jasypt;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.util.Base64;

import org.keycloak.credential.hash.PasswordHashProvider;
import org.keycloak.models.PasswordPolicy;
import org.keycloak.models.credential.PasswordCredentialModel;

/**
 * Verify-only password hash provider matching the legacy CAS Jasypt digest.
 *
 * <p>Legacy encoder (cas: GenericPasswordEncoder / Jasypt StandardStringDigester):
 * <pre>
 *   stored = Base64( SHA-256( salt || UTF8(NFC(password)) ) )      // for iterations == 1
 *   // iterations &gt; 1: the raw digest is re-hashed (iterations-1) more times, no salt
 * </pre>
 * The salt is a FIXED value shared by all users (Jasypt StringFixedSaltGenerator),
 * truncated to {@code salt-byte-size} bytes. It is supplied per-credential via the
 * imported {@code secretData.salt} so this class needs no configuration.
 *
 * <p>This provider is for migration only. It never hashes new passwords; on first
 * successful login Keycloak re-hashes with the realm default (Argon2).
 */
public class JasyptSha256PasswordHashProvider implements PasswordHashProvider {

    public static final String ID = "jasypt-sha256";
    private static final String DIGEST_ALGORITHM = "SHA-256";

    @Override
    public boolean policyCheck(PasswordPolicy policy, PasswordCredentialModel credential) {
        return ID.equals(credential.getPasswordCredentialData().getAlgorithm());
    }

    @Override
    public boolean verify(String rawPassword, PasswordCredentialModel credential) {
        if (rawPassword == null) {
            return false;
        }
        byte[] salt = credential.getPasswordSecretData().getSalt();
        int iterations = credential.getPasswordCredentialData().getHashIterations();
        byte[] expected;
        try {
            expected = Base64.getDecoder().decode(credential.getPasswordSecretData().getValue());
        } catch (IllegalArgumentException e) {
            return false;
        }

        byte[] actual = digest(salt, rawPassword, iterations);
        return MessageDigest.isEqual(actual, expected);
    }

    private static byte[] digest(byte[] salt, String rawPassword, int iterations) {
        MessageDigest md = newDigest();
        if (salt != null) {
            md.update(salt);
        }
        String normalized = Normalizer.normalize(rawPassword, Normalizer.Form.NFC);
        md.update(normalized.getBytes(StandardCharsets.UTF_8));
        byte[] digest = md.digest();
        // Jasypt re-hashes the raw digest (without salt) for the remaining rounds.
        for (int i = 1; i < iterations; i++) {
            md.reset();
            digest = md.digest(digest);
        }
        return digest;
    }

    private static MessageDigest newDigest() {
        try {
            return MessageDigest.getInstance(DIGEST_ALGORITHM);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(DIGEST_ALGORITHM + " not available", e);
        }
    }

    @Override
    public PasswordCredentialModel encodedCredential(String rawPassword, int iterations) {
        // Legacy import format only: never used to hash new passwords. Setting or
        // changing a password always goes through the realm default provider.
        throw new UnsupportedOperationException(
                "jasypt-sha256 is a verify-only migration provider; it cannot create new hashes");
    }

    @Override
    public void close() {
        // no resources
    }
}
