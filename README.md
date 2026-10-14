# poc-sf-jwt

POC Mule 4 (runtime 4.9, Java 17) para o OAuth 2.0 JWT Bearer Flow do Salesforce
e consumo da Einstein Bot API.

## Configuração

| Arquivo | Conteúdo |
|---|---|
| `common.yml` | Valores iguais em todos os ambientes (porta, TTLs, paths, versão da API do bot) |
| `config_dev.yml` / `config_hml.yml` / `config_prod.yml` | Valores do ambiente, abertos e criptografados (`![...]`) no mesmo arquivo |
| `certs/sf-jwt-<env>.pfx` | Certificado do Connected App de cada ambiente (fora do Git) |

Leitura no código:
- valor aberto: `${chave}` ou `p('chave')`
- valor criptografado: `${secure::chave}` ou `p('secure::chave')`

Propriedades de runtime:
- `env`: `dev` (default), `hml` ou `prod`
- `secure.key`: chave AES usada para criptografar os valores `![...]` daquele ambiente

No Studio: Run Configurations > Arguments > **VM arguments**:
`-Denv=dev -Dsecure.key=<chave-dev>`

No CloudHub 2.0: Runtime Manager > app > Properties (`secure.key` como protected).

## Criptografar valores

```
java -cp secure-properties-tool-j17.jar com.mulesoft.tools.SecurePropertiesTool \
  string encrypt AES CBC <secure.key> "<valor>"
```
Cole o resultado como `"![resultado]"` no `config_<env>.yml`.

## Testes

| Endpoint | O que valida |
|---|---|
| `GET /api/jwt` | Geração e assinatura do JWT (header, payload, expiração) |
| `GET /api/token[?force=true]` | Troca do JWT pelo access token (`00D...!...`), com cache |
| `POST /api/bot/session` `{"text":"Oi"}` | Abertura de sessão no Einstein Bot |

## Erros comuns no /api/token

- `user hasn't approved this consumer`: usuário não pré-autorizado no Connected App.
- `invalid assertion`: certificado do Connected App diferente do `.pfx`, ou `exp` vencido.
- `invalid_client_id`: clientId errado ou Connected App ainda propagando.
- `audience is invalid`: sandbox usa `https://test.salesforce.com`, prod `https://login.salesforce.com`.
