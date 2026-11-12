$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $infra -Parent) -Parent
$id = [guid]::NewGuid().ToString('N')
$name = "dlc-bootstrap-test-$id"
$temp = Join-Path ([IO.Path]::GetTempPath()) $name
$secret = [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force (Join-Path $temp 'secrets/patients-db') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $temp 'bootstrap') | Out-Null
try {
    foreach ($file in @('pg.txt','iam-migrator-password.txt','iam-runtime.txt','patients-migrator.txt','patients-db/password','appointments-migrator.txt','appointments-runtime.txt','billing-migrator.txt','billing-runtime.txt','notifications-migrator.txt','notifications-runtime.txt')) {
        [IO.File]::WriteAllText((Join-Path $temp "secrets/$file"), $secret)
    }
    $sources = @{
        'iam' = 'iam/dlc-iam-db/deploy/bootstrap.sql'
        'patients' = 'patients/dlc-patient-db/deploy/bootstrap.sql'
        'appointments' = 'appointments/dlc-appointments-db/deploy/bootstrap.sql'
        'billing' = 'billing/dlc-billing-db/deploy/bootstrap.sql'
        'notifications' = 'worker/dlc-worker/db/deploy/bootstrap.sql'
    }
    foreach ($domain in $sources.Keys) {
        Copy-Item -LiteralPath (Join-Path $workspace $sources[$domain]) -Destination (Join-Path $temp "bootstrap/$domain.sql")
    }
    $mount = $temp.Replace('\','/') + ':/test:ro'
    $script = (Join-Path $infra 'docker/bootstrap-postgres.sh').Replace('\','/') + ':/bootstrap.sh:ro'
    & docker run -d --name $name -e POSTGRES_PASSWORD_FILE=/test/secrets/pg.txt -e POSTGRES_DB=di_lucca -v $mount -v $script postgres:17.11-alpine3.24 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start test database' }
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        & docker exec $name pg_isready -h localhost -U postgres -d di_lucca 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Test database did not become ready' }
    & docker exec -e PGHOST=localhost -e PGDATABASE=di_lucca -e PGUSER=postgres -e PGPASSWORD_FILE=/test/secrets/pg.txt -e DLC_SECRETS_DIR=/test/secrets -e DLC_BOOTSTRAP_DIR=/test/bootstrap $name sh /bootstrap.sh
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap failed' }
    foreach ($role in @('iam_runtime','patients_app','appointments_runtime','billing_runtime','notifications_runtime')) {
        & docker exec -e PGPASSWORD=$secret $name psql -X -q -h localhost -U $role -d di_lucca -c 'SELECT 1' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Cannot authenticate as $role" }
    }
    Write-Output 'PostgreSQL bootstrap and runtime role authentication passed.'
} finally {
    & docker rm -fv $name 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
