package com.gdn.iam.keycloak.jasypt;

import org.keycloak.Config;
import org.keycloak.credential.hash.PasswordHashProvider;
import org.keycloak.credential.hash.PasswordHashProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public class JasyptSha256PasswordHashProviderFactory implements PasswordHashProviderFactory {

    private final JasyptSha256PasswordHashProvider provider = new JasyptSha256PasswordHashProvider();

    @Override
    public PasswordHashProvider create(KeycloakSession session) {
        return provider;
    }

    @Override
    public String getId() {
        return JasyptSha256PasswordHashProvider.ID;
    }

    @Override
    public void init(Config.Scope config) {
        // no configuration
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // nothing to do
    }

    @Override
    public void close() {
        // nothing to do
    }
}
