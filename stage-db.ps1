<#
.SYNOPSIS
  Start, inspect or remove the databases (PostgreSQL + MongoDB) of one stage.
.DESCRIPTION
  develop, qa and main are separate Compose projects (dlc-db-<stage>) with their own volumes,
  networks and generated secrets under .local/stages/<stage>. Liquibase runs every domain
  migration with the stage context (dev, qa or prod): synthetic seeds never reach prod.
  MongoDB uses TLS 1.2+ with a per-stage CA. No database port is published.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Action status
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Action down
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('develop', 'qa', 'main')][string]$Stage,
    [ValidateSet('up', 'status', 'down')][string]$Action = 'up'
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$envFile = "env/$Stage.env"
$compose = @('compose', '--env-file', $envFile, '-f', 'compose.stage-db.yaml')
$runtime = Join-Path $PSScriptRoot ".local/stages/$Stage"
$tlsDir = Join-Path $runtime 'mongo-secrets/tls'
$mongoImage = 'mongo:8.0.32@sha256:4968f22d0c6c10ef29952f3e807f62872ba22b3312f25803564fbfc08255efc2'

function Invoke-Docker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments -join ' ') failed ($LASTEXITCODE)" }
}

switch ($Action) {
    'status' {
        Invoke-Docker ($compose + @('ps', '-a', '--format', 'table {{.Service}}\t{{.Status}}'))
        return
    }
    'down' {
        # Removes this stage's containers and volumes only; other stages are untouched.
        Invoke-Docker ($compose + @('down', '-v', '--remove-orphans'))
        return
    }
}

# 1. Stage secrets (prepare-runtime refuses to overwrite an existing runtime).
Invoke-Docker ($compose + @('run', '--rm', '--build', 'prepare-runtime'))

# 2. Per-stage MongoDB CA and server certificate (SAN dlc-mongo), created once.
if (-not (Test-Path -LiteralPath (Join-Path $tlsDir 'server.pem'))) {
    New-Item -ItemType Directory -Force -Path $tlsDir | Out-Null
    $script = @'
set -eu
cd /tls
openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=dlc-$STAGE-mongo-ca" -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=dlc-mongo" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:dlc-mongo,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 -extfile server.ext -out server.crt 2>/dev/null
cat server.crt server.key > server.pem
rm -f ca.key ca.srl server.csr server.ext server.crt server.key
chmod 444 ca.pem server.pem
'@
    $mount = "$((Resolve-Path -LiteralPath $tlsDir).Path):/tls"
    Invoke-Docker @('run', '--rm', '-e', "STAGE=$Stage", '-v', $mount, '--entrypoint', 'sh', $mongoImage, '-c', $script)
}

# 3. Engines, bootstrap, every domain migration (stage context) and IAM provisioning.
Invoke-Docker ($compose + @('up', '-d', '--build', '--wait-timeout', '600'))
Invoke-Docker ($compose + @('ps', '-a', '--format', 'table {{.Service}}\t{{.Status}}'))
