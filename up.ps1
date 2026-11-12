param([switch]$Validate, [switch]$RefreshMounts)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$workspace = Split-Path (Split-Path $root -Parent) -Parent
$mongo = Join-Path $workspace 'dlc-infra-mongo/dlc-infra-mongo/compose.yml'
$private = if ($env:DLC_RUNTIME_DIR) { $env:DLC_RUNTIME_DIR } else { Join-Path $env:USERPROFILE 'DLC/infra-local' }
$private = [IO.Path]::GetFullPath($private)
$env:DLC_RUNTIME_DIR = $private.Replace('\','/')
$envFile = Join-Path $private 'stack.env'
$mongoSecrets = Join-Path $private 'mongo-secrets'
$mongoEnv = Join-Path $private 'mongo.env'

function Require-Path([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Falta un archivo o directorio necesario: $path" }
}
function Run-Docker([string[]]$arguments) {
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker terminó con código $LASTEXITCODE." }
}

Require-Path $mongo
Require-Path $envFile
Require-Path (Join-Path $private 'secrets/iam.env')
Require-Path (Join-Path $private 'registry/portal-registry.json')
Require-Path (Join-Path $private 'auth-config.json')
Require-Path (Join-Path $private 'svc')
foreach ($file in @('mongo-root-password.txt','mongo-keyfile','clinical-migrator-password.txt','clinical-runtime-password.txt','clinical-backup-password.txt')) {
    Require-Path (Join-Path $mongoSecrets $file)
}
foreach ($path in @('iam/dlc-iam-db','patients/dlc-patient-db','appointments/dlc-appointments-db','billing/dlc-billing-db','worker/dlc-worker')) {
    Require-Path (Join-Path $workspace $path)
}

$mongoEnvLines = @(
    'CLINICAL_DATA_NETWORK_NAME=clinical-data-e2e'
    ('DLC_MONGO_ROOT_PASSWORD_FILE=' + (Join-Path $mongoSecrets 'mongo-root-password.txt').Replace('\','/'))
    ('DLC_MONGO_KEYFILE=' + (Join-Path $mongoSecrets 'mongo-keyfile').Replace('\','/'))
    ('DLC_CLINICAL_MIGRATOR_PASSWORD_FILE=' + (Join-Path $mongoSecrets 'clinical-migrator-password.txt').Replace('\','/'))
    ('DLC_CLINICAL_RUNTIME_PASSWORD_FILE=' + (Join-Path $mongoSecrets 'clinical-runtime-password.txt').Replace('\','/'))
    ('DLC_CLINICAL_BACKUP_PASSWORD_FILE=' + (Join-Path $mongoSecrets 'clinical-backup-password.txt').Replace('\','/'))
)
[IO.File]::WriteAllLines($mongoEnv, $mongoEnvLines, (New-Object Text.UTF8Encoding($false)))
$platformArgs = @('compose','--project-name','dlc-e2e','--env-file',$envFile,'-f',(Join-Path $root 'compose.yaml'),'-f',(Join-Path $root 'compose.override.yaml'))
$mongoArgs = @('compose','--project-name','dlc-e2e-mongo','--env-file',$mongoEnv,'-f',$mongo)
Run-Docker ($platformArgs + @('config','--quiet'))
Run-Docker ($mongoArgs + @('config','--quiet'))

# This entry point restarts a provisioned installation; never create empty data volumes implicitly.
foreach ($volume in @('dlc-e2e_pg_data','dlc-e2e-mongo_mongo_data','dlc-e2e-mongo_mongo_config')) {
    & docker volume inspect $volume *> $null
    if ($LASTEXITCODE -ne 0) { throw "No existe el volumen $volume. Primero debe prepararse una instalación nueva y ejecutar sus migraciones." }
}
& docker network inspect clinical-data-e2e *> $null
if ($LASTEXITCODE -ne 0) { throw 'No existe la red clinical-data-e2e de la instalación aprovisionada.' }
$images = & docker @platformArgs config --images
if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer la lista de imágenes.' }
foreach ($image in $images) {
    if ($image -and $image -like '*:e2e') {
        & docker image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) { throw "Falta la imagen $image. Construya las imágenes de los repositorios antes de iniciar." }
    }
}
# Docker Desktop must be able to mount this path, not merely see it on Windows.
$probeMount = $private.Replace('\','/') + '/secrets/cln:/probe:ro'
& docker run --rm --entrypoint sh -v $probeMount dlc-billing-api:e2e -c 'test -r /probe/clinical-runtime-password' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker no puede leer la configuración privada. Revise las rutas compartidas de Docker Desktop.' }
if ($Validate) { Write-Output 'Configuración, volúmenes e imágenes disponibles.'; return }

Write-Output 'Iniciando MongoDB...'
if ($RefreshMounts) { Run-Docker ($mongoArgs + @('up','-d','--force-recreate','dlc-mongo')) }
else { Run-Docker ($mongoArgs + @('up','-d','dlc-mongo')) }
$healthy = $false
for ($i=0; $i -lt 60; $i++) {
    $state = & docker inspect --format '{{.State.Health.Status}}' dlc-e2e-mongo-dlc-mongo-1 2>$null
    if ($LASTEXITCODE -eq 0 -and $state -eq 'healthy') { $healthy = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $healthy) { throw 'MongoDB no alcanzó el estado saludable; la plataforma no fue iniciada.' }
if ($RefreshMounts) {
    Write-Output 'Actualizando el montaje privado de PostgreSQL...'
    Run-Docker ($platformArgs + @('up','-d','--no-build','--force-recreate','dlc-postgres'))
    $healthy = $false
    for ($i=0; $i -lt 60; $i++) {
        $state = & docker inspect --format '{{.State.Health.Status}}' dlc-e2e-dlc-postgres-1 2>$null
        if ($LASTEXITCODE -eq 0 -and $state -eq 'healthy') { $healthy = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw 'PostgreSQL no alcanzó el estado saludable; revise sus registros.' }
}
Write-Output 'Iniciando servicios de la plataforma...'
Run-Docker ($platformArgs + @('up','-d','--no-build'))
$services = @('dlc-e2e-dlc-postgres-1','dlc-e2e-rabbitmq-1','dlc-e2e-mailpit-1',
    'dlc-e2e-auth-service-1','dlc-e2e-patients-api-1','dlc-e2e-appointments-api-1',
    'dlc-e2e-billing-api-1','dlc-e2e-clinical-api-1','dlc-e2e-dlc-worker-1',
    'dlc-e2e-clinical-outbox-relay-1','dlc-e2e-clinical-inbox-consumer-1',
    'dlc-e2e-clinical-intent-reconciler-1','dlc-e2e-clinical-analytics-consumer-1',
    'dlc-e2e-api-gateway-1','dlc-e2e-dlc-front-1','dlc-e2e-iam-portal-1',
    'dlc-e2e-patient-portal-1','dlc-e2e-appointments-portal-1',
    'dlc-e2e-clinical-portal-1','dlc-e2e-billing-portal-1')
$ready = $false
for ($i=0; $i -lt 60; $i++) {
    $states = & docker inspect --format '{{.State.Status}}' @services 2>$null
    if ($LASTEXITCODE -eq 0 -and @($states).Count -eq $services.Count -and @($states | Where-Object { $_ -ne 'running' }).Count -eq 0) {
        try {
            $front = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8081/' -TimeoutSec 3
            $jwks = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8081/api/v1/auth/jwks' -TimeoutSec 3
            if ($front.StatusCode -eq 200 -and $jwks.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    Start-Sleep -Seconds 2
}
if (-not $ready) { throw 'Uno o más servicios no alcanzaron el estado esperado. Revise docker compose ps y sus registros.' }
Write-Output 'Servicios iniciados. Aplicación: http://localhost:8081 ; correo de pruebas: http://localhost:18025'
