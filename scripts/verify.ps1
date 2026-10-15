param([switch]$UnitOnly)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot
try {
    node scripts/check-runtime.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Runtime mismatch.' }
    foreach ($task in @('lint','typecheck','test:ci','build')) {
        npm.cmd --prefix frontend run $task
        if ($LASTEXITCODE -ne 0) { throw "Frontend $task failed." }
    }
    npm.cmd exec --yes --package=deno@2.9.6 -- deno check supabase/functions/system-status/index.ts
    if ($LASTEXITCODE -ne 0) { throw 'Edge typecheck failed.' }
    npm.cmd exec --yes --package=deno@2.9.6 -- deno test supabase/functions/system-status/handler_test.ts
    if ($LASTEXITCODE -ne 0) { throw 'Edge tests failed.' }
    if (-not $UnitOnly) {
        npm.cmd exec --yes --package=supabase@2.121.0 -- supabase start
        if ($LASTEXITCODE -ne 0) { throw 'Supabase start failed. Docker must be running.' }
        Get-Content supabase/tests/connection_permissions.sql -Raw | docker exec -i supabase_db_serendipity-table psql -U postgres -d postgres -v ON_ERROR_STOP=1
        if ($LASTEXITCODE -ne 0) { throw 'Database permissions failed.' }
    }
} finally { Pop-Location }
