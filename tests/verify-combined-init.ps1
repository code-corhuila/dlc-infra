$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$id = [guid]::NewGuid().ToString('N')
$project = "dlcfullinit$id"
$temp = Join-Path ([IO.Path]::GetTempPath()) "dlc-full-init-$id"
$oldRuntime = $env:DLC_RUNTIME_DIR
$oldEmail = $env:DLC_ADMIN_EMAIL
$env:DLC_RUNTIME_DIR = $temp.Replace('\','/')
$env:DLC_ADMIN_EMAIL = 'admin@example.test'
$compose = @('compose','-p',$project,'-f',(Join-Path $infra 'compose.prepare.yaml'),'-f',(Join-Path $infra 'compose.database-init.yaml'),'-f',(Join-Path $infra 'compose.mongo-init.yaml'),'-f',(Join-Path $infra 'compose.init.yaml'))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    & docker @compose up -d --build iam-provision dlc-mongo-runtime-identity
    if ($LASTEXITCODE -ne 0) {
        & docker @compose logs --no-color --tail 15 prepare-runtime
        throw 'Combined initialization failed to start'
    }
    foreach ($service in @('iam-provision','dlc-mongo-runtime-identity')) {
        $container = & docker @compose ps -aq $service
        if ($LASTEXITCODE -ne 0 -or -not $container) { throw "$service container is missing" }
        $result = & docker wait $container
        if ($LASTEXITCODE -ne 0 -or $result -ne '0') { throw "$service failed" }
    }
    Write-Output 'Combined database and IAM initialization completed.'
} finally {
    $ErrorActionPreference = 'Continue'
    & docker @compose down -v --remove-orphans 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    $env:DLC_RUNTIME_DIR = $oldRuntime
    $env:DLC_ADMIN_EMAIL = $oldEmail
}
