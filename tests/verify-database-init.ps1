$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $infra -Parent) -Parent
$id = [guid]::NewGuid().ToString('N')
$project = "dlcinit$id"
$temp = Join-Path ([IO.Path]::GetTempPath()) "dlc-init-$id"
$oldRuntime = $env:DLC_RUNTIME_DIR
$oldAdminEmail = $env:DLC_ADMIN_EMAIL
$env:DLC_RUNTIME_DIR = $temp.Replace('\','/')
$env:DLC_ADMIN_EMAIL = 'admin@example.test'
$compose = @('compose','-p',$project,'-f',(Join-Path $infra 'compose.database-init.yaml'))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    $registry = (Join-Path $workspace 'dlc-front/dlc-front/fixtures/portal-registry.json').Replace('\','/') + ':/input/portal-registry.json:ro'
    $runtime = $temp.Replace('\','/') + ':/runtime'
    & docker run --rm -v $runtime -v $registry dlc-infra-runtime-setup:test
    if ($LASTEXITCODE -ne 0) { throw 'Runtime generation failed' }
    $password = [IO.File]::ReadAllText((Join-Path $temp 'secrets/pg.txt'))
    & docker @compose up -d iam-provision
    if ($LASTEXITCODE -ne 0) { throw 'Database migration pipeline failed to start' }
    $container = & docker @compose ps -aq iam-provision
    if ($LASTEXITCODE -ne 0 -or -not $container) { throw 'IAM provisioning container is missing' }
    $result = & docker wait $container
    if ($LASTEXITCODE -ne 0 -or $result -ne '0') { throw 'IAM provisioning failed' }
    $admin = & docker @compose exec -T -e PGPASSWORD=$password dlc-postgres psql -U postgres -d di_lucca -v ON_ERROR_STOP=1 -tAc "SELECT count(*) FROM iam.users u JOIN iam.user_roles r USING (user_id) WHERE u.email='admin@example.test' AND r.role='ADMINISTRATOR';"
    if ($LASTEXITCODE -ne 0 -or $admin.Trim() -ne '1') { throw 'Initial administrator was not created' }
    $clients = & docker @compose exec -T -e PGPASSWORD=$password dlc-postgres psql -U postgres -d di_lucca -v ON_ERROR_STOP=1 -tAc 'SELECT count(*) FROM iam.service_clients;'
    if ($LASTEXITCODE -ne 0 -or [int]$clients.Trim() -lt 5) { throw 'Service clients were not created' }
    & docker @compose run --rm --no-deps iam-provision
    if ($LASTEXITCODE -ne 0) { throw 'IAM provisioning cannot be repeated safely' }
    Write-Output 'Database initialization pipeline completed.'
} finally {
    $ErrorActionPreference = 'Continue'
    & docker @compose down -v --remove-orphans 2>$null | Out-Null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    $env:DLC_RUNTIME_DIR = $oldRuntime
    $env:DLC_ADMIN_EMAIL = $oldAdminEmail
}
