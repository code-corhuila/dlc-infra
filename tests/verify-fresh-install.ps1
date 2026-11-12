$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$id = [guid]::NewGuid().ToString('N')
$project = "dlcfreshfinal$id"
$temp = Join-Path ([IO.Path]::GetTempPath()) "dlc-fresh-final-$id"
$names = @('DLC_RUNTIME_DIR','DLC_IMAGE_TAG','DLC_FRONT_PORT','DLC_MAIL_PORT','DLC_PUBLIC_ORIGIN','DLC_EDGE_SUBNET','DLC_FRONT_IP','DLC_GATEWAY_IP','DLC_ADMIN_EMAIL','COMPOSE_PARALLEL_LIMIT')
$old = @{}
foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$env:DLC_RUNTIME_DIR = $temp.Replace('\','/')
$env:DLC_IMAGE_TAG = 'freshcheck'
$env:DLC_FRONT_PORT = '18081'
$env:DLC_MAIL_PORT = '28025'
$env:DLC_PUBLIC_ORIGIN = 'http://localhost:18081'
$env:DLC_EDGE_SUBNET = '172.31.99.0/24'
$env:DLC_FRONT_IP = '172.31.99.240'
$env:DLC_GATEWAY_IP = '172.31.99.241'
$env:DLC_ADMIN_EMAIL = 'admin@dilucca.local'
$env:COMPOSE_PARALLEL_LIMIT = '1'
$compose = @('compose','-p',$project,'-f',(Join-Path $infra 'compose.fresh.yaml'))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    & docker @compose up -d --build
    if ($LASTEXITCODE -ne 0) { throw 'Fresh installation failed to start' }
    $ready = $false
    for ($i=0; $i -lt 90; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing 'http://localhost:18081/api/v1/auth/jwks' -TimeoutSec 3
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'IAM did not become ready' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-fresh-smoke.ps1') -Origin 'http://localhost:18081' -Runtime $temp
    if ($LASTEXITCODE -ne 0) { throw 'Fresh installation smoke test failed' }
    foreach ($service in @('dlc-postgres','dlc-mongo','rabbitmq','auth-service','patients-api','appointments-api','billing-api','dlc-worker','clinical-api','clinical-outbox-relay','clinical-inbox-consumer','clinical-intent-reconciler','clinical-analytics-consumer','api-gateway','dlc-front','iam-portal','patient-portal','appointments-portal','billing-portal','clinical-portal','mailpit')) {
        $container = & docker @compose ps -q $service
        if (-not $container) { throw "Missing service: $service" }
        $state = & docker inspect --format '{{.State.Status}}' $container
        if ($LASTEXITCODE -ne 0 -or $state -ne 'running') { throw "Service is not running: $service" }
    }
    Write-Output 'Fresh installation from empty volumes passed.'
} finally {
    $ErrorActionPreference = 'Continue'
    & docker @compose down -v --remove-orphans 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process') }
}
