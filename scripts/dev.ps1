param([ValidateSet('db', 'backend', 'frontend', 'stop', 'doctor')][string]$Service = 'doctor')
. "$PSScriptRoot/env.ps1"
if ($Service -in @('doctor', 'backend', 'frontend')) {
    node "$PSScriptRoot/check-runtime.mjs"
    if ($LASTEXITCODE -ne 0) { throw 'Runtime version mismatch.' }
}
switch ($Service) {
    'doctor' {
        node --version; npm.cmd --version; java -version; docker version
        if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop Linux engine must be running.' }
    }
    'db' {
        docker compose --env-file "$ProjectRoot/.env" -f "$ProjectRoot/infra/compose.yaml" up -d --wait
        if ($LASTEXITCODE -ne 0) { throw 'Database startup failed.' }
    }
    'stop' {
        docker compose --env-file "$ProjectRoot/.env" -f "$ProjectRoot/infra/compose.yaml" down
        if ($LASTEXITCODE -ne 0) { throw 'Database shutdown failed.' }
    }
    'backend' {
        Push-Location "$ProjectRoot/backend"
        try { & .\gradlew.bat bootRun; if ($LASTEXITCODE -ne 0) { throw 'Backend failed.' } } finally { Pop-Location }
    }
    'frontend' {
        $localEnv = "$ProjectRoot/frontend/.env.local"
        if (-not (Test-Path $localEnv)) { Copy-Item "$ProjectRoot/frontend/.env.example" $localEnv }
        Push-Location "$ProjectRoot/frontend"
        try { npm.cmd run dev; if ($LASTEXITCODE -ne 0) { throw 'Frontend failed.' } } finally { Pop-Location }
    }
}
