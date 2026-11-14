$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$json = & docker compose -f (Join-Path $root 'compose.build.yaml') config --format json
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose could not parse the build configuration.' }
$config = $json | ConvertFrom-Json
$expected = @('auth-service','patients-api','appointments-api','billing-api','clinical-api',
    'dlc-worker','api-gateway','dlc-front','iam-portal','patient-portal',
    'appointments-portal','clinical-portal','billing-portal')
foreach ($name in $expected) {
    $service = $config.services.$name
    if (-not $service -or -not $service.image -or -not $service.build.context -or -not $service.build.dockerfile) {
        throw "Missing image or build settings for $name."
    }
    $context = $service.build.context
    if (-not (Test-Path -LiteralPath $context -PathType Container)) { throw "Missing build context for $name." }
    $dockerfile = [IO.Path]::GetFullPath((Join-Path $context $service.build.dockerfile))
    if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) { throw "Missing Dockerfile for $name." }
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'docker/billing.Dockerfile.dockerignore'))) {
    throw 'Billing build must exclude secrets and use its Dockerfile-specific ignore file.'
}
Write-Output 'All 13 application image build contexts and Dockerfiles exist.'
