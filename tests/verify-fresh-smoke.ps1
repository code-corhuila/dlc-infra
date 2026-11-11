param(
    [string]$Origin = 'http://localhost:8081',
    [string]$Runtime = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local'),
    [string]$AdminEmail = 'admin@dilucca.local'
)
$ErrorActionPreference = 'Stop'
foreach ($path in @('/portal-registry.json','/auth-config.json')) {
    $response = Invoke-WebRequest -UseBasicParsing ($Origin + $path) -TimeoutSec 20
    if ($response.StatusCode -ne 200) { throw "Frontend configuration unavailable: $path" }
}
$registry = Get-Content -Raw -LiteralPath (Join-Path $Runtime 'registry/portal-registry.json') | ConvertFrom-Json
foreach ($portal in $registry.portals) {
    $response = Invoke-WebRequest -UseBasicParsing ($Origin + $portal.entryUrl) -TimeoutSec 20
    if ($response.StatusCode -ne 200) { throw "Portal unavailable: $($portal.portalId)" }
}
$jwks = Invoke-WebRequest -UseBasicParsing ($Origin + '/api/v1/auth/jwks') -TimeoutSec 20
if ($jwks.StatusCode -ne 200) { throw 'IAM JWKS unavailable' }
$password = [IO.File]::ReadAllText((Join-Path $Runtime 'secrets/staff-password.txt'))
$body = @{ email = $AdminEmail; password = $password } | ConvertTo-Json -Compress
$login = Invoke-RestMethod -Method Post -Uri ($Origin + '/api/v1/auth/login') -Headers @{ Origin = $Origin } -ContentType 'application/json' -Body $body -TimeoutSec 20
if (-not $login.accessToken) { throw 'Administrator login returned no access token' }
foreach ($path in @('/api/v1/patients?limit=10','/api/v1/appointment-types','/api/v1/invoices')) {
    Write-Output "Checking $path"
    $success = $false
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing ($Origin + $path) -Headers @{ Authorization = ('Bearer ' + $login.accessToken) } -TimeoutSec 60
            if ($response.StatusCode -eq 200) { $success = $true; break }
        } catch {
            if ($attempt -eq 2) { throw "Authenticated request failed: $path ($($_.Exception.Message))" }
            Start-Sleep -Seconds 3
        }
    }
    if (-not $success) { throw "Authenticated request failed: $path" }
}
Write-Output 'Portals, IAM login and authenticated patient, appointment and billing requests passed.'
