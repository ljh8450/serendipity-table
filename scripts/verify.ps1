param([switch]$UnitOnly)
. "$PSScriptRoot/env.ps1"
node "$PSScriptRoot/check-runtime.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Runtime version mismatch.' }
Push-Location "$ProjectRoot/frontend"
try {
    foreach ($script in @('lint', 'typecheck', 'test:ci', 'build')) {
        npm.cmd run $script
        if ($LASTEXITCODE -ne 0) { throw "Frontend $script failed." }
    }
} finally { Pop-Location }
Push-Location "$ProjectRoot/backend"
try {
    if ($UnitOnly) { & .\gradlew.bat test bootJar } else { & .\gradlew.bat check bootJar }
    if ($LASTEXITCODE -ne 0) { throw 'Backend verification failed.' }
} finally { Pop-Location }
