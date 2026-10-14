package com.accenture.sf.auth;

import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.util.Base64;
import java.util.Enumeration;

/**
 * Gera e assina (RS256) o JWT do OAuth 2.0 JWT Bearer Flow do Salesforce.
 * Equivalente às etapas 2 a 6 do script PowerShell.
 */
public class JwtSigner {

    private static volatile PrivateKey cachedKey;

    private static final Base64.Encoder B64URL = Base64.getUrlEncoder().withoutPadding();

    public static String sign(String keystorePath,
                              String keystorePassword,
                              String alias,
                              String clientId,
                              String username,
                              String audience,
                              int ttlSeconds) throws Exception {

        PrivateKey key = loadKey(keystorePath, keystorePassword, alias);

        long exp = (System.currentTimeMillis() / 1000L) + ttlSeconds;

        String header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
        String payload = "{"
                + "\"iss\":\"" + clientId + "\","
                + "\"sub\":\"" + username + "\","
                + "\"aud\":\"" + audience + "\","
                + "\"exp\":" + exp
                + "}";

        String data = B64URL.encodeToString(header.getBytes(StandardCharsets.UTF_8))
                + "."
                + B64URL.encodeToString(payload.getBytes(StandardCharsets.UTF_8));

        Signature sig = Signature.getInstance("SHA256withRSA");
        sig.initSign(key);
        sig.update(data.getBytes(StandardCharsets.UTF_8));

        return data + "." + B64URL.encodeToString(sig.sign());
    }

    private static PrivateKey loadKey(String path, String password, String alias) throws Exception {
        if (cachedKey != null) {
            return cachedKey;
        }
        synchronized (JwtSigner.class) {
            if (cachedKey != null) {
                return cachedKey;
            }
            if (password == null || password.isEmpty()) {
                throw new IllegalStateException(
                        "Senha do keystore vazia. Verifique sf.jwt.keystorePassword no config-${env}.yaml.");
            }

            KeyStore ks = KeyStore.getInstance("PKCS12");
            try (InputStream in = open(path)) {
                ks.load(in, password.toCharArray());
            }

            String resolvedAlias = alias;
            if (resolvedAlias == null || resolvedAlias.isEmpty()) {
                // .pfx gerado por PowerShell/OpenSSL costuma ter alias aleatorio: usa o primeiro com chave
                Enumeration<String> aliases = ks.aliases();
                while (aliases.hasMoreElements()) {
                    String a = aliases.nextElement();
                    if (ks.isKeyEntry(a)) {
                        resolvedAlias = a;
                        break;
                    }
                }
            }
            if (resolvedAlias == null) {
                throw new IllegalStateException("Nenhuma chave privada encontrada no keystore " + path);
            }

            PrivateKey key = (PrivateKey) ks.getKey(resolvedAlias, password.toCharArray());
            if (key == null) {
                throw new IllegalStateException("Alias '" + resolvedAlias + "' sem chave privada");
            }
            cachedKey = key;
            return key;
        }
    }

    /** Procura primeiro no classpath (src/main/resources), depois no filesystem. */
    private static InputStream open(String path) throws Exception {
        InputStream in = Thread.currentThread().getContextClassLoader().getResourceAsStream(path);
        if (in == null) {
            in = JwtSigner.class.getClassLoader().getResourceAsStream(path);
        }
        return in != null ? in : new FileInputStream(path);
    }
}
