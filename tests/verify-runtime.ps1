$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $infra -Parent) -Parent
$id = [guid]::NewGuid().ToString('N')
$temp = Join-Path ([IO.Path]::GetTempPath()) "dlc-runtime-test-$id"
$registry = Join-Path $workspace 'dlc-front/dlc-front/fixtures/portal-registry.json'
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    $runtimeMount = $temp.Replace('\','/') + ':/runtime'
    $registryMount = $registry.Replace('\','/') + ':/input/portal-registry.json:ro'
    & docker run --rm -v $runtimeMount -v $registryMount dlc-infra-runtime-setup:test
    if ($LASTEXITCODE -ne 0) { throw 'Runtime initialization failed' }
    foreach ($file in @('.initialized','stack.env','secrets/iam.env','secrets/staff-password.txt','secrets/cln/clinical-runtime-password','mongo-secrets/mongo-keyfile','svc/jwks.json','registry/portal-registry.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temp $file) -PathType Leaf)) { throw "Missing generated file: $file" }
    }
    $first = (Get-FileHash -Algorithm SHA256 (Join-Path $temp 'secrets/staff-password.txt')).Hash
    & docker run --rm -v $runtimeMount -v $registryMount dlc-infra-runtime-setup:test
    if ($LASTEXITCODE -ne 0) { throw 'Repeated initialization failed' }
    $second = (Get-FileHash -Algorithm SHA256 (Join-Path $temp 'secrets/staff-password.txt')).Hash
    if ($first -ne $second) { throw 'Repeated initialization changed credentials' }
    Write-Output 'Runtime initialization and credential preservation passed.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
