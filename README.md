# poc-sf-jwt

POC em **Mule 4** para autenticar no Salesforce via **OAuth 2.0 JWT Bearer Flow**, com o JWT gerado e assinado dentro da aplicação Mule, e consumir a **Einstein Bot API** com o access token obtido.

A POC substitui o script PowerShell usado na validação inicial. O script carregava o certificado `.pfx`, montava o JWT, assinava com RS256 e trocava o JWT pelo access token. A aplicação faz o mesmo e acrescenta cache do token, tratamento de erros e configuração por ambiente.

---

## Sumário

1. [Visão geral do fluxo](#1-visão-geral-do-fluxo)
2. [Stack e versões](#2-stack-e-versões)
3. [Estrutura do projeto](#3-estrutura-do-projeto)
4. [Configuração (properties)](#4-configuração-properties)
5. [Classe Java: `JwtSigner`](#5-classe-java-jwtsigner)
6. [Fluxos Mule](#6-fluxos-mule)
7. [Tratamento de erros](#7-tratamento-de-erros)
8. [Como rodar](#8-como-rodar)
9. [Testes](#9-testes)
10. [Pré-requisitos no Salesforce](#10-pré-requisitos-no-salesforce)
11. [Troubleshooting](#11-troubleshooting)
12. [Segurança](#12-segurança)
13. [Limitações conhecidas e próximos passos](#13-limitações-conhecidas-e-próximos-passos)

---

## 1. Visão geral do fluxo

São **duas chamadas distintas**:

```
                    ┌──────────────────────────────┐
                    │        Aplicação Mule        │
                    │                              │
  (1) gera JWT      │  JwtSigner.sign()            │
      assinado ────►│  header.payload.assinatura   │
                    │  (RS256 com chave do .pfx)   │
                    └──────────────┬───────────────┘
                                   │ POST /services/oauth2/token
                                   │ grant_type=jwt-bearer
                                   │ assertion=<JWT>
                                   ▼
                    ┌──────────────────────────────┐
  (2) troca JWT     │     Salesforce (org)         │
      por token ───►│  valida assinatura com o     │
                    │  certificado do Connected App│
                    └──────────────┬───────────────┘
                                   │ access_token = 00D...!AQ...
                                   │ instance_url
                                   ▼
                    ┌──────────────────────────────┐
                    │  Object Store (cache)        │
                    └──────────────┬───────────────┘
                                   │ Authorization: Bearer <access_token>
                                   ▼
                    ┌──────────────────────────────┐
  (3) consome bot   │  Einstein Bot Runtime API    │
                    └──────────────────────────────┘
```

**JWT ≠ access token**:

| | JWT (assertion) | Access token |
|---|---|---|
| Quem gera | A aplicação Mule (`JwtSigner`) | O Salesforce |
| Formato | `eyJhbGciOi...` (3 partes Base64URL separadas por `.`) | `00Dxxxxxxxxxxxx!AQ...` (começa com o Org ID) |
| Validade | `exp` = agora + 180 s | Session Timeout da org / Connected App |
| Uso | Só na chamada ao `/services/oauth2/token` | Header `Authorization: Bearer` nas APIs |

---

## 2. Stack e versões

| Item | Versão |
|---|---|
| Mule Runtime | 4.9.0 |
| Java | 17 |
| mule-maven-plugin | 4.3.0 |
| HTTP Connector | 1.10.3 |
| ObjectStore Connector | 1.2.2 |
| Java Module | 2.0.1 |
| Secure Configuration Properties Module | 1.2.7 |
| maven-compiler-plugin | 3.11.0 (`release 17`) |

Definido em `pom.xml` e `mule-artifact.json` (`minMuleVersion: 4.9.0`, `javaSpecificationVersions: ["17"]`).

---

## 3. Estrutura do projeto

```
poc-sf-jwt/
├── pom.xml
├── mule-artifact.json
├── .gitignore
├── README.md
└── src/
    ├── main/
    │   ├── java/
    │   │   └── com/accenture/sf/auth/
    │   │       └── JwtSigner.java          # geração e assinatura do JWT
    │   ├── mule/
    │   │   └── poc-sf-jwt.xml              # configs globais, flows, sub-flows, error handler
    │   └── resources/
    │       ├── common.yaml                 # valores iguais em todos os ambientes
    │       ├── config_dev.yaml             # valores de DEV (abertos + ![criptografados])
    │       ├── config_hml.yaml             # valores de HML
    │       ├── config_prod.yaml            # valores de PROD
    │       ├── log4j2.xml
    │       └── certs/
    │           └── sf-jwt-<env>.pfx        # certificado por ambiente (NÃO versionado)
    └── test/
        └── resources/
```

---

## 4. Configuração (properties)

### 4.1 Arquivos

O Mule 4 só aceita **`.yaml`** ou **`.properties`** em `configuration-properties` e `secure-properties:config`. Arquivos `.yml` geram o erro `must end with yaml or properties extension`.

| Arquivo | Conteúdo |
|---|---|
| `common.yaml` | Valores fixos, iguais em todos os ambientes |
| `config_<env>.yaml` | Valores do ambiente. **Um único arquivo** com valores abertos e criptografados (`![...]`) misturados |

### 4.2 Como o arquivo único por ambiente funciona

O mesmo `config_${env}.yaml` é declarado **duas vezes** no XML:

```xml
<configuration-properties file="config_${env}.yaml"/>

<secure-properties:config name="Secure_Properties_Config"
                          file="config_${env}.yaml"
                          key="${secure.key}">
    <secure-properties:encrypt algorithm="AES" mode="CBC"/>
</secure-properties:config>
```

- Valor **aberto**: lido com `${chave}` ou `p('chave')`.
- Valor **criptografado** (`"![...]"`): lido com `${secure::chave}` ou `p('secure::chave')`.
- O prefixo `secure::` também lê valores em texto aberto. Por isso dá para começar com o valor aberto e criptografar depois sem mudar o código.

### 4.3 Propriedades de runtime

Não ficam nos arquivos e são passadas na execução:

| Property | Descrição | Default |
|---|---|---|
| `env` | Ambiente: `dev`, `hml` ou `prod`. Define qual `config_<env>.yaml` é carregado | `dev` (via `global-property`) |
| `secure.key` | Chave AES usada para criptografar/descriptografar os valores `![...]` do ambiente | **obrigatória** |

### 4.4 `common.yaml`

| Chave | Valor | Uso |
|---|---|---|
| `http.port` | `8081` | Porta do HTTP Listener |
| `sf.token.path` | `/services/oauth2/token` | Path do endpoint de token |
| `sf.token.cacheTtlMinutes` | `60` | TTL do access token no Object Store. Deve ficar abaixo do Session Timeout da org |
| `sf.jwt.ttlSeconds` | `180` | Validade do JWT (`exp`). O Salesforce aceita no máximo 3 minutos |
| `sf.jwt.keyAlias` | `""` | Alias da chave no `.pfx`. Vazio = usa o primeiro alias que contém chave privada |
| `bot.apiVersion` | `v5.0.0` | Versão da Einstein Bot Runtime API no path |

### 4.5 `config_<env>.yaml`

| Chave | Exemplo (DEV) | Secure? | Uso |
|---|---|---|---|
| `sf.token.host` | `<org>.sandbox.my.salesforce.com` | não | Host do endpoint de token (My Domain da org) |
| `sf.jwt.keystorePath` | `certs/sf-jwt-dev.pfx` | não | Caminho do `.pfx`, relativo ao classpath (`src/main/resources`) ou absoluto no filesystem |
| `sf.jwt.keystorePassword` | `![...]` | **sim** | Senha do `.pfx` |
| `sf.jwt.clientId` | `![...]` | **sim** | Consumer Key do Connected App → claim `iss` |
| `sf.jwt.username` | `usuario.integracao@dominio.dev` | não | Usuário Salesforce → claim `sub` |
| `sf.jwt.audience` | `https://test.salesforce.com` | não | Claim `aud`. Sandbox: `test`; produção: `https://login.salesforce.com` |
| `bot.runtimeHost` | `runtime-api-na-west.prod.chattr.salesforce.com` | não | Host do Bot Runtime (Setup > Einstein Bots > Overview) |
| `bot.botId` | `0Xx...` | não | ID do bot |
| `bot.orgId` | `00D...` | não | Org ID (15 caracteres), enviado no header da Bot API |

### 4.6 Criptografar valores

Com o [Secure Properties Tool](https://docs.mulesoft.com/mule-runtime/latest/secure-configuration-properties#secure_props_tool) (versão compatível com Java 17):

```bash
java -cp secure-properties-tool-j17.jar com.mulesoft.tools.SecurePropertiesTool \
  string encrypt AES CBC <secure.key> "<valor>"
```

Cole o resultado entre `![` e `]`:

```yaml
sf:
  jwt:
    keystorePassword: "![AbCdEf123...]"
```

Cada ambiente pode ter sua própria `secure.key`. O valor criptografado com a chave de DEV só abre com a chave de DEV.

---

## 5. Classe Java: `JwtSigner`

`src/main/java/com/accenture/sf/auth/JwtSigner.java`

Classe utilitária **sem dependências externas** (só `java.security` e `java.util` da JDK). Gera e assina o JWT no formato exigido pelo Salesforce.

### 5.1 Campos estáticos

```java
private static volatile PrivateKey cachedKey;
private static final Base64.Encoder B64URL = Base64.getUrlEncoder().withoutPadding();
```

| Campo | Descrição |
|---|---|
| `cachedKey` | Chave privada já extraída do `.pfx`. Carregada **uma vez por JVM** e reutilizada nas chamadas seguintes. `volatile` garante visibilidade entre threads no padrão *double-checked locking* (ver `loadKey`) |
| `B64URL` | Encoder **Base64URL sem padding** (`=`), como exige a RFC 7515 (JWS). Troca `+` por `-` e `/` por `_` e remove o `=` final. É o equivalente ao `ConvertTo-Base64Url` do script PowerShell |

### 5.2 `sign(...)`: método público

```java
public static String sign(String keystorePath,
                          String keystorePassword,
                          String alias,
                          String clientId,
                          String username,
                          String audience,
                          int ttlSeconds) throws Exception
```

**Parâmetros**

| # | Parâmetro | Origem (property) | Descrição |
|---|---|---|---|
| arg0 | `keystorePath` | `sf.jwt.keystorePath` | Caminho do `.pfx` |
| arg1 | `keystorePassword` | `secure::sf.jwt.keystorePassword` | Senha do `.pfx` |
| arg2 | `alias` | `sf.jwt.keyAlias` | Alias da chave; vazio = autodetecta |
| arg3 | `clientId` | `secure::sf.jwt.clientId` | Vai para o claim `iss` |
| arg4 | `username` | `sf.jwt.username` | Vai para o claim `sub` |
| arg5 | `audience` | `sf.jwt.audience` | Vai para o claim `aud` |
| arg6 | `ttlSeconds` | `sf.jwt.ttlSeconds` | Segundos somados ao horário atual para o claim `exp` |

> O Java Module identifica os parâmetros como `arg0..arg6` porque a classe é compilada sem a flag `-parameters`. Para usar os nomes reais no XML, adicione `<parameters>true</parameters>` na configuração do `maven-compiler-plugin`.

**Retorno**: a string do JWT no formato `base64url(header).base64url(payload).base64url(assinatura)`.

**Passo a passo**

1. **Carrega a chave privada** chamando `loadKey(...)`. Na primeira chamada ela é lida do `.pfx`; nas seguintes, vem do cache.
2. **Calcula o `exp`**: `System.currentTimeMillis() / 1000 + ttlSeconds`, em Unix epoch (segundos, UTC).
3. **Monta o header** (fixo):
   ```json
   {"alg":"RS256","typ":"JWT"}
   ```
4. **Monta o payload**:
   ```json
   {"iss":"<clientId>","sub":"<username>","aud":"<audience>","exp":<epoch>}
   ```
   | Claim | Significado para o Salesforce |
   |---|---|
   | `iss` | Consumer Key do Connected App |
   | `sub` | Username do usuário em nome de quem o token é emitido |
   | `aud` | Servidor de autorização: `https://test.salesforce.com` (sandbox) ou `https://login.salesforce.com` (produção) |
   | `exp` | Expiração do JWT. O Salesforce rejeita valores acima de 3 minutos no futuro ou já vencidos |
5. **Gera o conteúdo a assinar**: `base64url(header) + "." + base64url(payload)`, em UTF-8.
6. **Assina** com `Signature.getInstance("SHA256withRSA")`, ou seja, RSA PKCS#1 v1.5 + SHA-256 = **RS256**. É o equivalente a `rsa.SignData(..., SHA256, Pkcs1)` no PowerShell.
7. **Concatena** `conteúdo + "." + base64url(assinatura)` e retorna.

### 5.3 `loadKey(...)`: privado

```java
private static PrivateKey loadKey(String path, String password, String alias) throws Exception
```

Carrega a chave privada RSA do `.pfx` (PKCS#12) e guarda em `cachedKey`.

1. **Fast path**: se `cachedKey` já existe, retorna sem lock.
2. **`synchronized (JwtSigner.class)`**: só uma thread carrega o keystore. Dentro do lock, verifica `cachedKey` de novo (*double-checked locking*), porque outra thread pode ter carregado enquanto esta esperava.
3. **Valida a senha**: se vier nula ou vazia, lança `IllegalStateException`. Isso evita um erro genérico do `KeyStore` e aponta direto para a property.
4. **Abre o keystore**: `KeyStore.getInstance("PKCS12")` + `ks.load(stream, senha)`. O stream vem de `open(path)`.
5. **Resolve o alias**:
   - Se `alias` foi informado, usa esse valor.
   - Se veio vazio, percorre `ks.aliases()` e usa o **primeiro com `isKeyEntry == true`**, ou seja, que contém chave privada e não só certificado. Isso é útil porque `.pfx` gerado por PowerShell, `New-SelfSignedCertificate` ou OpenSSL costuma ter alias aleatório (GUID) ou `1`.
6. **Extrai a chave** com `ks.getKey(alias, senha)`. Se não encontrar, lança `IllegalStateException`.
7. **Grava em `cachedKey`** e retorna.

**Exceções possíveis**

| Exceção | Causa provável |
|---|---|
| `IllegalStateException: Senha do keystore vazia...` | Property `sf.jwt.keystorePassword` vazia, ou `secure.key` errada |
| `IOException: keystore password was incorrect` | Senha não corresponde ao `.pfx` |
| `FileNotFoundException` | `.pfx` não está no classpath nem no caminho informado |
| `IllegalStateException: Nenhuma chave privada encontrada...` | O arquivo só tem certificado (ex.: `.cer`/`.crt` renomeado) |
| `IllegalStateException: Alias '...' sem chave privada` | Alias informado em `sf.jwt.keyAlias` não tem chave privada |

### 5.4 `open(...)`: privado

```java
private static InputStream open(String path) throws Exception
```

Localiza o `.pfx` em três tentativas, nesta ordem:

1. **Context ClassLoader da thread**: é o caminho normal no Mule, já que o ClassLoader da aplicação enxerga `src/main/resources`. Por isso `certs/sf-jwt-dev.pfx` funciona como caminho relativo.
2. **ClassLoader da própria classe**: fallback para quando o context ClassLoader da thread não é o da aplicação.
3. **Filesystem** (`FileInputStream`): permite usar caminho absoluto, por exemplo um certificado montado fora do pacote.

### 5.5 Equivalência com o script PowerShell

| Etapa do script | Implementação |
|---|---|
| 1. Verificar arquivo PFX | `open()` (lança `FileNotFoundException`) |
| 2. Carregar certificado / `GetRSAPrivateKey` | `loadKey()` |
| 3. `ConvertTo-Base64Url` | `B64URL` |
| 4. Header | `sign()`, variável `header` |
| 5. Payload (`exp = now + 180`) | `sign()`, variável `payload` + `ttlSeconds` |
| 6. `SignData(SHA256, Pkcs1)` | `Signature.getInstance("SHA256withRSA")` |
| 7. `Invoke-RestMethod` no token | Sub-flow `sf-generate-access-token` (Mule) |

---

## 6. Fluxos Mule

Todos ficam em `src/main/mule/poc-sf-jwt.xml`.

### 6.1 Configurações globais

| Elemento | Nome | Descrição |
|---|---|---|
| `global-property` | `env` | Default `dev`. Sobrescrito por `-Denv=...` |
| `configuration-properties` | — | `common.yaml` e `config_${env}.yaml` |
| `secure-properties:config` | `Secure_Properties_Config` | `config_${env}.yaml`, AES/CBC, chave `${secure.key}` |
| `http:listener-config` | `HTTP_Listener_Config` | `0.0.0.0:${http.port}` |
| `http:request-config` | `SF_Token_Config` | HTTPS `${sf.token.host}:443` |
| `http:request-config` | `Bot_Runtime_Config` | HTTPS `${bot.runtimeHost}:443` |
| `os:object-store` | `SF_Token_Store` | Não persistente, TTL `${sf.token.cacheTtlMinutes}` minutos |

### 6.2 Endpoints (flows)

#### `get-jwt`: `GET /api/jwt`

Endpoint de **diagnóstico**. Gera um JWT e devolve o token e o conteúdo decodificado, **sem chamar o Salesforce**.

1. `flow-ref` → `sf-build-jwt` (resultado em `vars.jwt`).
2. `ee:transform` decodifica header e payload:
   - `b64url(s)`: converte Base64URL → Base64 (`-`→`+`, `_`→`/`), completa o padding com `=` usando `rightPad` até o tamanho ser múltiplo de 4, decodifica com `fromBase64` e faz `read` como JSON.
   - `expiraEm`: converte o `exp` (epoch) para `DateTime` em `America/Sao_Paulo`.

Resposta:
```json
{
  "jwt": "eyJhbGciOi...",
  "header":  { "alg": "RS256", "typ": "JWT" },
  "payload": { "iss": "...", "sub": "...", "aud": "https://test.salesforce.com", "exp": 1791926567 },
  "expiraEm": "2026-10-13T18:22:47-03:00"
}
```

> Em DataWeave não existe repetição de string com `*` (`"=" * 2` dá erro de tipo). Para padding, use `rightPad` de `dw::core::Strings`.

#### `get-token`: `GET /api/token[?force=true]`

Valida a **troca do JWT pelo access token**.

1. Se `force=true`, chama `sf-invalidate-access-token` para ignorar o cache.
2. `flow-ref` → `sf-get-access-token`.
3. Responde:
```json
{
  "origem": "salesforce | cache",
  "instanceUrl": "https://<org>.sandbox.my.salesforce.com",
  "accessToken": "00D...!AQ..."
}
```
Error handler: `Poc_Error_Handler`.

#### `post-bot-session`: `POST /api/bot/session`

Abre uma sessão no Einstein Bot. Body de entrada: `{ "text": "Oi" }`. Se `text` não vier, usa `"Oi"`.

1. Guarda o texto em `vars.userText`.
2. `flow-ref` → `sf-get-access-token`.
3. `POST https://${bot.runtimeHost}/${bot.apiVersion}/bots/{botId}/sessions`
   - Headers: `Authorization: Bearer <token>`, `X-Org-Id: ${bot.orgId}`, `X-Request-ID: <uuid>`
   - Body:
     ```json
     {
       "externalSessionKey": "<uuid>",
       "message": { "text": "<userText>" },
       "forceConfig": { "endpoint": "<instance_url>/" }
     }
     ```
4. Devolve a resposta do bot como veio.

> Antes de usar, confira no Bot Overview (e no teste manual que funcionou) o nome do header do Org ID, a versão da API e o runtime host. Ajuste se forem diferentes.

### 6.3 Sub-flows (reutilizáveis)

#### `sf-get-access-token`

Ponto de entrada para **obter um token válido**. Qualquer fluxo que precise chamar o Salesforce usa este sub-flow.

1. `os:retrieve` da chave `sfToken` em `SF_Token_Store` (default `{}`), resultado em `vars.cached`.
2. `choice`:
   - **Sem token em cache**: `sf-generate-access-token`.
   - **Com token em cache**: preenche `vars.sfToken`, `vars.instanceUrl` e `vars.tokenFromCache = true`.

Saída: `vars.sfToken`, `vars.instanceUrl` e, quando veio do cache, `vars.tokenFromCache`.

#### `sf-build-jwt`

Chama `JwtSigner.sign(...)` via `java:invoke-static`, passando as properties como `arg0..arg6` (ver [5.2](#52-sign-método-público)). Resultado em `vars.jwt`.

#### `sf-generate-access-token`

Executa o JWT Bearer Flow:

1. `sf-build-jwt`, resultado em `vars.jwt`.
2. `POST https://${sf.token.host}${sf.token.path}`, `application/x-www-form-urlencoded`:
   ```
   grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
   assertion=<JWT>
   ```
3. Da resposta, extrai `access_token` para `vars.sfToken` e `instance_url` para `vars.instanceUrl`.
4. `os:store` de `{ accessToken, instanceUrl }` na chave `sfToken`.

> O JWT Bearer Flow do Salesforce **não retorna `expires_in`**. Por isso o tempo de vida no cache é controlado pelo `entryTtl` do Object Store (`sf.token.cacheTtlMinutes`), que precisa ser menor que o Session Timeout da org/Connected App.

#### `sf-invalidate-access-token`

Remove a chave `sfToken` do Object Store. Fica dentro de um `try` com `on-error-continue` para `OS:KEY_NOT_FOUND`, então não falha se o cache já estiver vazio.

Usado no `?force=true` e no tratamento de `401`.

---

## 7. Tratamento de erros

`Poc_Error_Handler` (global, referenciado pelos flows `get-token` e `post-bot-session`):

| Tipo de erro | Ação | Status HTTP | Resposta |
|---|---|---|---|
| `HTTP:UNAUTHORIZED` | Limpa o cache do token (`sf-invalidate-access-token`), então a próxima chamada gera um token novo | 401 | `{ erro: "UNAUTHORIZED", detalhe: <corpo do Salesforce> }` |
| `HTTP:BAD_REQUEST`, `HTTP:FORBIDDEN`, `HTTP:NOT_FOUND` | Repassa o corpo de erro do Salesforce (ex.: `invalid_grant`) | Status original | `{ erro: <tipo>, detalhe: <corpo do Salesforce> }` |
| `ANY` | Erro genérico (ex.: falha no Java, property ausente) | 500 | `{ erro: "<namespace>:<tipo>", detalhe: <descrição> }` |

O status é definido em `vars.httpStatus` e aplicado pelo `http:error-response` do listener.

---

## 8. Como rodar

### 8.1 Pré-requisitos

- Anypoint Studio 7.x com runtime 4.9 e JDK 17.
- Certificado `.pfx` (chave privada + certificado) **cujo certificado público está carregado no Connected App** da org.

### 8.2 Passos

1. Clone o repositório e importe no Studio (*File > Import > Anypoint Studio project from File System*, ou Maven).
2. Copie o `.pfx` do ambiente para `src/main/resources/certs/` com o nome definido em `sf.jwt.keystorePath` (ex.: `sf-jwt-dev.pfx`).
3. Preencha o `config_dev.yaml`.
4. Em *Run Configurations > Arguments > **VM arguments***:
   ```
   -Denv=dev -Dsecure.key=<chave-de-dev>
   ```
   > No Studio, use `-D` em **VM arguments**. O formato `-M-D...` só vale para o Mule standalone na linha de comando.
5. Rode a aplicação. Ela sobe na porta `8081`.

### 8.3 CloudHub 2.0

- Em **Properties** da aplicação no Runtime Manager: `env=hml` (ou `prod`) e `secure.key=<chave>`, com a `secure.key` marcada como protected.
- O `.pfx` precisa estar no pacote (`src/main/resources/certs`) ou ser fornecido por outro mecanismo (ver [13](#13-limitações-conhecidas-e-próximos-passos)).

---

## 9. Testes

Faça os testes nesta ordem. Cada etapa isola uma parte do fluxo:

| # | Requisição | O que valida | Resultado esperado |
|---|---|---|---|
| 1 | `GET http://localhost:8081/api/jwt` | Leitura do `.pfx`, senha e assinatura RS256 | `200` com header/payload decodificados. O `jwt` pode ser conferido em jwt.io |
| 2 | `GET http://localhost:8081/api/token` | Troca do JWT no Salesforce | `200`, `origem: "salesforce"`, `accessToken` começando com o Org ID (`00D...!`) |
| 3 | `GET http://localhost:8081/api/token` (de novo) | Cache | `origem: "cache"`, resposta em milissegundos |
| 4 | `GET http://localhost:8081/api/token?force=true` | Invalidação | `origem: "salesforce"` |
| 5 | `POST http://localhost:8081/api/bot/session` `{"text":"Oi"}` | Einstein Bot API | `200` com `sessionId` e mensagens do bot |

Exemplos com curl:

```bash
curl http://localhost:8081/api/jwt
curl http://localhost:8081/api/token
curl "http://localhost:8081/api/token?force=true"
curl -X POST http://localhost:8081/api/bot/session \
     -H "Content-Type: application/json" \
     -d '{"text":"Oi"}'
```

> A primeira chamada pode levar alguns segundos, por causa do carregamento da classe, do keystore e da conexão TLS. As seguintes são rápidas.

---

## 10. Pré-requisitos no Salesforce

No **Connected App** (ou External Client App) da org:

- [ ] **Use digital signatures** habilitado, com o certificado público (`.crt`) correspondente ao `.pfx`.
- [ ] Escopos OAuth: `api`, `refresh_token, offline_access` e, para a Bot API, **`chatbot_api`**.
- [ ] *Policies > Permitted Users*: **Admin approved users are pre-authorized**.
- [ ] Perfil ou Permission Set do usuário de `sf.jwt.username` adicionado ao Connected App.
- [ ] Consumer Key copiado para `sf.jwt.clientId`.

Na **Einstein Bot**:

- [ ] Bot ativo e com o Connected App associado (Einstein Bots > Overview > Connected App).
- [ ] Runtime host, Bot ID e Org ID copiados para `bot.runtimeHost`, `bot.botId` e `bot.orgId`.

---

## 11. Troubleshooting

### Inicialização

| Erro | Causa | Solução |
|---|---|---|
| `Configuration properties file common.yml must end with yaml or properties extension` | Extensão `.yml` | Renomear para `.yaml` e ajustar as referências no XML |
| `Couldn't find configuration property value for key ${secure.key}` | `secure.key` não informada | Adicionar `-Dsecure.key=...` em VM arguments |
| Property `${...}` não encontrada | Chave ausente no `common.yaml`/`config_<env>.yaml`, ou `env` errado | Conferir o nome da chave e o `-Denv` |

### `/api/jwt`

| Erro | Causa | Solução |
|---|---|---|
| `Senha do keystore vazia` | `sf.jwt.keystorePassword` vazia | Preencher no `config_<env>.yaml` |
| `keystore password was incorrect` | Senha errada | Conferir a senha do `.pfx` |
| `FileNotFoundException` | `.pfx` ausente ou nome diferente do `keystorePath` | Conferir o arquivo em `src/main/resources/certs` |
| `You called the function '*' with ... String, Number` | Repetição de string com `*` no DataWeave | Usar `rightPad` (já corrigido) |

### `/api/token`: erros devolvidos pelo Salesforce

| `error_description` | Causa | Solução |
|---|---|---|
| `user hasn't approved this consumer` | Usuário não pré-autorizado | Policies do Connected App + perfil/permission set |
| `invalid assertion` | Certificado do Connected App diferente do `.pfx`, ou `exp` vencido (relógio da máquina) | Reenviar o `.crt` correto; conferir o horário |
| `invalid_client_id` / `client identifier invalid` | Consumer Key errado ou Connected App recém-criado | Conferir o `clientId`; aguardar a propagação (até ~10 min) |
| `audience is invalid` | `aud` errado para o tipo de org | Sandbox: `https://test.salesforce.com`; Produção: `https://login.salesforce.com` |
| `user is not admin approved to access this app` | Perfil do usuário não está no Connected App | Adicionar o perfil/permission set |

### `/api/bot/session`

| Status | Causa provável |
|---|---|
| `401` | Token sem escopo `chatbot_api`, ou expirado. O cache é limpo automaticamente |
| `403` | Connected App não associado ao bot |
| `404` | `botId`, `apiVersion` ou `runtimeHost` incorretos |

---

## 12. Segurança

- **`.pfx` nunca vai para o Git**: `*.pfx`, `*.p12` e `*.key` já estão no `.gitignore`.
- **Senha do `.pfx` e Consumer Key** devem ficar criptografados (`![...]`) no `config_<env>.yaml` antes de qualquer commit.
- **`secure.key`** nunca fica em arquivo do projeto: só em VM arguments (local) ou em propriedade protected no Runtime Manager.
- Use um **usuário de integração** dedicado em `sf.jwt.username`, e não um usuário pessoal.
- Se a senha ou o `.pfx` vazarem, gere um novo certificado, atualize o Connected App e descarte o antigo.

---

## 13. Limitações conhecidas e próximos passos

**Limitações da POC**

- `cachedKey` é estático: a chave é lida uma vez por JVM. Se o `.pfx` mudar, a aplicação precisa ser reiniciada. Isso não é problema porque cada aplicação roda um único ambiente.
- O payload do JWT é montado por concatenação de strings, sem escape de JSON. Funciona para Consumer Key, usernames e URLs, que não têm aspas nem barras invertidas.
- O Object Store é não persistente e local a cada réplica: cada réplica gera o próprio token na primeira chamada.
- No `401`, o cache é limpo, mas a requisição original **não** é reprocessada automaticamente. Quem chamou deve repetir a requisição.
- A sessão do bot só cobre a abertura (`/sessions`). Ainda faltam envio de mensagem (`/sessions/{id}/messages`) e encerramento (`DELETE /sessions/{id}`).

**Próximos passos sugeridos**

- [ ] Criptografar `keystorePassword` e `clientId` em todos os ambientes.
- [ ] Usuário de integração dedicado por ambiente.
- [ ] Retry automático (1x) após `401`, com token novo.
- [ ] Endpoints de mensagem e encerramento de sessão do bot, controlando `sessionId` e `sequenceId` por conversa.
- [ ] Avaliar outra forma de fornecer o `.pfx` em CloudHub 2.0, fora do pacote da aplicação.
- [ ] Testes MUnit para `sf-get-access-token` (cache hit/miss) e para o error handler.
- [ ] Pipeline de deploy por ambiente.
