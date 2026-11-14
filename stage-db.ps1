<#
.SYNOPSIS
  Start, inspect or remove one stage: develop, qa or main.
.DESCRIPTION
  Each stage is a separate Compose project (dlc-<stage>) with its own ports, subnet, volumes
  and generated secrets under .local/stages/<stage>. Liquibase runs every domain migration
  with the stage context (dev, qa or prod): synthetic seeds never reach prod. MongoDB uses
  TLS 1.2+ with a per-stage CA. A database viewer listens on 127.0.0.1 only.
  -Mode db starts the databases only; -Mode full also builds and starts the APIs, portals and
  front. develop uses the repositories next to this one; qa uses git worktrees of every
  repository's qa branch under <root>/.stages/qa. main has no deployable code before its
  first release, so it supports -Mode db only.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Mode full
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage main
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Mode full -Action status
  powershell -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Mode full -Action down
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('develop', 'qa', 'main')][string]$Stage,
    [ValidateSet('up', 'status', 'down')][string]$Action = 'up',
    [ValidateSet('db', 'full')][string]$Mode = 'db',
    [switch]$InStageTree
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if ($Mode -eq 'full' -and $Stage -eq 'main') { throw 'main has no deployable code yet: use -Mode db' }

# qa code comes from each repository's qa branch, in worktrees laid out like the project root.
if ($Mode -eq 'full' -and $Stage -eq 'qa' -and -not $InStageTree) {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $tree = Join-Path $root '.stages/qa'
    $repos = @('iam/dlc-iam-api', 'iam/dlc-iam-db', 'iam/dlc-iam-portal', 'patients/dlc-patient-api',
        'patients/dlc-patient-db', 'patients/dlc-patient-portal', 'appointments/dlc-appointments-api',
        'appointments/dlc-appointments-db', 'appointments/dlc-appointments-portal', 'billing/dlc-billing-api',
        'billing/dlc-billing-db', 'billing/dlc-billing-portal', 'clinical/dlc-clinical-api',
        'clinical/dlc-clinical-db', 'clinical/dlc-clinical-portal', 'worker/dlc-worker',
        'api gateway/dlc-api-gateway', 'dlc-front/dlc-front', 'dlc-infra-mongo/dlc-infra-mongo')
    foreach ($repo in $repos) {
        $source = Join-Path $root $repo
        $target = Join-Path $tree $repo
        & git -C $source fetch -q origin '+refs/heads/qa:refs/remotes/origin/qa'
        if (-not (Test-Path -LiteralPath $target)) {
            & git -C $source worktree add -q --detach $target origin/qa
        } elseif ($Action -eq 'up') {
            & git -C $target checkout -q --detach origin/qa
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not prepare the qa worktree of $repo" }
    }
    # Orchestration files come from this dlc-infra commit; application code from qa.
    $infra = Join-Path $tree 'dlc-infra/dlc-infra'
    $head = (& git -C $PSScriptRoot rev-parse HEAD)
    if (-not (Test-Path -LiteralPath $infra)) { & git -C $PSScriptRoot worktree add -q --detach $infra $head }
    elseif ($Action -eq 'up') { & git -C $infra checkout -q --detach $head }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $infra 'stage-db.ps1') `
        -Stage $Stage -Action $Action -Mode $Mode -InStageTree
    exit $LASTEXITCODE
}

$envFile = "env/$Stage.env"
$file = if ($Mode -eq 'db') { 'compose.stage-db.yaml' } elseif ($Stage -eq 'qa') { 'compose.stage.qa.yaml' } else { 'compose.stage.yaml' }
$compose = @('compose', '--env-file', $envFile, '-f', $file)
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
    $script = $script -replace "`r", ''   # Git may check this file out with CRLF line endings
    $mount = "$((Resolve-Path -LiteralPath $tlsDir).Path):/tls"
    Invoke-Docker @('run', '--rm', '-e', "STAGE=$Stage", '-v', $mount, '--entrypoint', 'sh', $mongoImage, '-c', $script)
}

# 3. Engines, bootstrap, every domain migration (stage context) and IAM provisioning.
Invoke-Docker ($compose + @('up', '-d', '--build', '--wait-timeout', '600'))
Invoke-Docker ($compose + @('ps', '-a', '--format', 'table {{.Service}}\t{{.Status}}'))
