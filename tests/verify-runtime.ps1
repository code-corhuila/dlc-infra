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
    $billingMount = (Join-Path $workspace 'billing/dlc-billing-portal/package.json').Replace('\','/') + ':/input/billing-package.json:ro'
    & docker run --rm -v $runtimeMount -v $registryMount -v $billingMount dlc-infra-runtime-setup:local
    if ($LASTEXITCODE -ne 0) { throw 'Runtime initialization failed' }
    foreach ($file in @('.initialized','stack.env','secrets/iam.env','secrets/staff-password.txt','secrets/cln/clinical-runtime-password','mongo-secrets/mongo-keyfile','svc/jwks.json','registry/portal-registry.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temp $file) -PathType Leaf)) { throw "Missing generated file: $file" }
    }
    $generatedRegistry = Get-Content -Raw (Join-Path $temp 'registry/portal-registry.json') | ConvertFrom-Json
    $billingVersion = (Get-Content -Raw (Join-Path $workspace 'billing/dlc-billing-portal/package.json') | ConvertFrom-Json).version
    $billingPortal = $generatedRegistry.portals | Where-Object { $_.portalId -eq 'billing' }
    if ($billingPortal.release -ne $billingVersion -or $billingPortal.entryUrl -notmatch "/$([regex]::Escape($billingVersion))/") { throw 'Billing registry version does not match its package' }
    $first = (Get-FileHash -Algorithm SHA256 (Join-Path $temp 'secrets/staff-password.txt')).Hash
    $billingMount = (Join-Path $workspace 'billing/dlc-billing-portal/package.json').Replace('\','/') + ':/input/billing-package.json:ro'
    & docker run --rm -v $runtimeMount -v $registryMount -v $billingMount dlc-infra-runtime-setup:local
    if ($LASTEXITCODE -ne 0) { throw 'Repeated initialization failed' }
    $second = (Get-FileHash -Algorithm SHA256 (Join-Path $temp 'secrets/staff-password.txt')).Hash
    if ($first -ne $second) { throw 'Repeated initialization changed credentials' }
    [IO.File]::WriteAllText((Join-Path $temp 'launcher-test.env'), "DLC_TEST_VALUE=expected-value`n")
    & docker run --rm --entrypoint /runtime/launcher -e DLC_LAUNCH_ENV=/runtime/launcher-test.env -v $runtimeMount dlc-infra-runtime-setup:local /bin/sh -c 'test "$DLC_TEST_VALUE" = expected-value'
    if ($LASTEXITCODE -ne 0) { throw 'Launcher did not pass generated environment to the service' }
    Write-Output 'Runtime initialization and credential preservation passed.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
