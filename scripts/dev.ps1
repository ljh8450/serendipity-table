param([ValidateSet('db','backend','frontend','stop','doctor')][string]$Service = 'doctor')
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot
try {
    switch ($Service) {
        'doctor' { node scripts/check-runtime.mjs; docker info --format '{{.ServerVersion}}' }
        'db' { npm.cmd exec --yes --package=supabase@2.121.0 -- supabase start }
        'backend' { npm.cmd exec --yes --package=supabase@2.121.0 -- supabase functions serve system-status --env-file supabase/functions/.env.local }
        'stop' { npm.cmd exec --yes --package=supabase@2.121.0 -- supabase stop }
        'frontend' {
            if (-not (Test-Path frontend/.env.local)) { Copy-Item frontend/.env.example frontend/.env.local }
            npm.cmd --prefix frontend run dev
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "$Service failed." }
} finally { Pop-Location }
