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
    npm.cmd exec --yes --package=deno@2.9.6 -- deno check supabase/functions/system-status/index.ts supabase/functions/member/index.ts supabase/functions/push-dispatch/index.ts supabase/functions/privacy-dispatch/index.ts
    if ($LASTEXITCODE -ne 0) { throw 'Edge typecheck failed.' }
    npm.cmd exec --yes --package=deno@2.9.6 -- deno test supabase/functions/
    if ($LASTEXITCODE -ne 0) { throw 'Edge tests failed.' }
    if (-not $UnitOnly) {
        $localStartOutput = npm.cmd exec --yes --package=supabase@2.121.0 -- supabase start 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Supabase start failed. Docker must be running.' }
        Write-Output 'Local Supabase ready (configuration output withheld).'
        foreach ($sqlTest in Get-ChildItem supabase/tests/*.sql) {
            Get-Content $sqlTest.FullName -Raw | docker exec -i supabase_db_serendipity-table psql -U postgres -d postgres -v ON_ERROR_STOP=1
            if ($LASTEXITCODE -ne 0) { throw "Database test failed: $($sqlTest.Name)" }
        }
        node scripts/verify-privacy-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Privacy concurrency verification failed.' }
        node scripts/verify-operations-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Operations concurrency verification failed.' }
        node scripts/verify-safety-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Safety concurrency verification failed.' }
        node scripts/verify-preferences-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Preference concurrency verification failed.' }
        node scripts/verify-feedback-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Feedback concurrency verification failed.' }
        node scripts/verify-content-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Scheduled content Cron/concurrency verification failed.' }
        node scripts/verify-push-queue-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Push queue concurrency verification failed.' }
        node scripts/verify-resolution-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Resolution concurrency verification failed.' }
        node scripts/verify-chat-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Chat Cron/concurrency verification failed.' }
        node scripts/verify-venue-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Venue Cron/concurrency verification failed.' }
        node scripts/verify-matching-local.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Actual Cron/concurrency verification failed.' }
    }
} finally { Pop-Location }
