$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $infra -Parent) -Parent
$id = [guid]::NewGuid().ToString('N')
$project = "dlcmongoinit$id"
$temp = Join-Path ([IO.Path]::GetTempPath()) "dlc-mongo-init-$id"
$oldRuntime = $env:DLC_RUNTIME_DIR
$env:DLC_RUNTIME_DIR = $temp.Replace('\','/')
$compose = @('compose','-p',$project,'-f',(Join-Path $infra 'compose.mongo-init.yaml'))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    $registry = (Join-Path $workspace 'dlc-front/dlc-front/fixtures/portal-registry.json').Replace('\','/') + ':/input/portal-registry.json:ro'
    $runtime = $temp.Replace('\','/') + ':/runtime'
    $billingMount = (Join-Path $workspace 'billing/dlc-billing-portal/package.json').Replace('\','/') + ':/input/billing-package.json:ro'
    & docker run --rm -v $runtime -v $registry -v $billingMount dlc-infra-runtime-setup:local
    if ($LASTEXITCODE -ne 0) { throw 'Runtime generation failed' }
    & docker @compose up -d --build dlc-mongo-runtime-identity
    if ($LASTEXITCODE -ne 0) { throw 'Clinical MongoDB initialization failed to start' }
    $container = & docker @compose ps -aq dlc-mongo-runtime-identity
    if ($LASTEXITCODE -ne 0 -or -not $container) { throw 'Runtime identity container is missing' }
    $result = & docker wait $container
    if ($LASTEXITCODE -ne 0 -or $result -ne '0') { throw 'Clinical runtime identity creation failed' }
    $mongo = & docker @compose ps -q dlc-mongo
    $runtimePassword = [IO.File]::ReadAllText((Join-Path $temp 'mongo-secrets/clinical-runtime-password.txt'))
    & docker exec $mongo mongosh --quiet --norc 'mongodb://dlc-mongo:27017/clinical?replicaSet=rs0' --username clinical_runtime --password $runtimePassword --authenticationDatabase clinical --eval 'quit(db.schema_info.countDocuments()>0?0:1)'
    if ($LASTEXITCODE -ne 0) { throw 'Clinical runtime could not read schema_info' }
    Write-Output 'Clinical MongoDB migration and runtime identity initialization completed.'
} finally {
    $ErrorActionPreference = 'Continue'
    & docker @compose down -v --remove-orphans 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    $env:DLC_RUNTIME_DIR = $oldRuntime
}
