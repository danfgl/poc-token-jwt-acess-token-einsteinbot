# ============================================================
# SALESFORCE DEV - OAuth 2.0 JWT Bearer Flow
# ============================================================

$basePath = $PSScriptRoot

$clientId = "3MVG9jaVFD0NWW._5qYWhz2wlB0qiot.vxYtgfKSd2SdZADk0Fi3xqvXhK2WAsKFMIJfFMIRcHw3FYk2MiURr"

$username = "raphael.e.silva@accenture.com.aegea.dev"

$tokenUrl = "https://customer-force-2060--dev.sandbox.my.salesforce.com/services/oauth2/token"

$pfxPassword = "SFByoc2026!"

$pfxPath = Join-Path $basePath "server.pfx"


# ============================================================
# 1. VERIFICAR ARQUIVO PFX
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "SALESFORCE JWT - DEV" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Verificando certificado..." -ForegroundColor Cyan

if (-not (Test-Path $pfxPath)) {

    Write-Host ""
    Write-Host "ERRO: server.pfx nao encontrado." -ForegroundColor Red
    Write-Host "Caminho esperado:" -ForegroundColor Yellow
    Write-Host $pfxPath

    exit 1
}

Write-Host "server.pfx encontrado." -ForegroundColor Green


# ============================================================
# 2. CARREGAR CERTIFICADO
# ============================================================

Write-Host ""
Write-Host "Carregando certificado..." -ForegroundColor Cyan

try {

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $pfxPath,
        $pfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)

    if ($null -eq $rsa) {
        throw "Nao foi possivel obter a chave privada RSA do certificado."
    }

    Write-Host "Certificado carregado com sucesso." -ForegroundColor Green

}
catch {

    Write-Host ""
    Write-Host "ERRO AO CARREGAR CERTIFICADO:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow

    exit 1
}


# ============================================================
# 3. FUNCAO BASE64URL
# ============================================================

function ConvertTo-Base64Url {

    param(
        [byte[]]$Bytes
    )

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}


# ============================================================
# 4. CRIAR HEADER JWT
# ============================================================

Write-Host ""
Write-Host "Criando JWT..." -ForegroundColor Cyan

$headerJson = '{"alg":"RS256","typ":"JWT"}'

$headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerJson)

$header = ConvertTo-Base64Url -Bytes $headerBytes


# ============================================================
# 5. CRIAR PAYLOAD JWT
# ============================================================

$exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 180

$payloadObject = @{
    iss = $clientId
    sub = $username
    aud = "https://test.salesforce.com"
    exp = $exp
}

$payloadJson = $payloadObject | ConvertTo-Json -Compress

$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)

$payload = ConvertTo-Base64Url -Bytes $payloadBytes


# ============================================================
# 6. ASSINAR JWT
# ============================================================

$data = "$header.$payload"

$dataBytes = [System.Text.Encoding]::UTF8.GetBytes($data)

$signatureBytes = $rsa.SignData(
    $dataBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

$signature = ConvertTo-Base64Url -Bytes $signatureBytes

$jwt = "$data.$signature"

Write-Host "JWT gerado e assinado com sucesso." -ForegroundColor Green

Write-Host ""
Write-Host "JWT (assertion):" -ForegroundColor Yellow
Write-Host $jwt
Write-Host ""
Write-Host "Payload:" -ForegroundColor Yellow
Write-Host $payloadJson
Write-Host ""


# ============================================================
# 7. SOLICITAR ACCESS TOKEN
# ========================

Write-Host ""
Write-Host "Solicitando Access Token ao Salesforce..." -ForegroundColor Cyan

$body = @{
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assertion  = $jwt
}


try {

    $response = Invoke-RestMethod `
        -Uri $tokenUrl `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "AUTENTICACAO REALIZADA COM SUCESSO!" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""

    Write-Host "Instance URL:" -ForegroundColor Cyan
    Write-Host $response.instance_url

    Write-Host ""
Write-Host ""
Write-Host "ACCESS TOKEN PARA TESTE:" -ForegroundColor Yellow
Write-Host $response.access_token
Write-Host ""

}
catch {

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host "ERRO NA AUTENTICACAO SALESFORCE" -ForegroundColor Red
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host ""

    Write-Host "Exception:" -ForegroundColor Yellow
    Write-Host $_.Exception.Message

    Write-Host ""

    if ($_.ErrorDetails.Message) {

        Write-Host "Detalhe retornado pelo Salesforce:" -ForegroundColor Yellow
        Write-Host $_.ErrorDetails.Message

    }
    elseif ($_.Exception.Response) {

        try {

            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)

            $detail = $reader.ReadToEnd()

            Write-Host "Detalhe retornado pelo Salesforce:" -ForegroundColor Yellow
            Write-Host $detail

            $reader.Close()

        }
        catch {

            Write-Host "Nao foi possivel obter detalhes adicionais da resposta." -ForegroundColor Yellow

        }
    }

    Write-Host ""
}