param()

# Validate build, test, pack and sign for the repository.
# This script is intended to be run from the repository root (where this workspace's repo lives).

$ErrorActionPreference = 'Stop'

function Write-Ok($m){ Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }

try {
    $repoRoot = Resolve-Path -LiteralPath '.'
    Write-Host "Repository root: $repoRoot"

    # Load env (if present) from sibling ulfbou/scripts/env.ps1
    $envScript = Resolve-Path -LiteralPath "..\ulfbou\scripts\env.ps1" -ErrorAction SilentlyContinue
    if ($envScript) {
        Write-Host "Loading env script: $envScript"
        . $envScript
        Write-Ok "Loaded env script"
    }
    else {
        Write-Warn "No env loader script found at ..\ulfbou\scripts\env.ps1; continuing without loading .env"
    }

    # Ensure artifacts directory
    $artifacts = Join-Path $repoRoot 'artifacts'
    if (-not (Test-Path $artifacts)) { New-Item -ItemType Directory -Path $artifacts | Out-Null }

    # Discover source projects
    $srcDir = Join-Path $repoRoot 'src'
    if (-not (Test-Path $srcDir)) { Write-Warn "src/ directory not found; searching entire repo for csproj"; $srcProjects = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.csproj' } else { $srcProjects = Get-ChildItem -Path $srcDir -Recurse -Filter '*.csproj' }

    if ($srcProjects.Count -eq 0) { Write-Warn "No source projects found." }
    else { Write-Host "Found source projects:`n"; $srcProjects | ForEach-Object { Write-Host "  $_" } }

    # Build all source projects
    $buildFailed = $false
    foreach ($p in $srcProjects) {
        Write-Host "Building $($p.FullName)";
        $b = dotnet build $p.FullName -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { Write-Err "Build failed for $($p.FullName)"; $buildFailed = $true; break }
    }
    if ($buildFailed) { throw "Build failed" } else { Write-Ok "All projects built" }

    # Discover test projects (tests/)
    $testsDir = Join-Path $repoRoot 'tests'
    $testProjects = @()
    if (Test-Path $testsDir) { $testProjects = Get-ChildItem -Path $testsDir -Recurse -Filter '*.csproj' }
    if ($testProjects.Count -eq 0) { Write-Warn "No test projects found under tests/" } else { Write-Host "Found test projects:"; $testProjects | ForEach-Object { Write-Host "  $_" } }

    # Build test projects first so dotnet test with no-build succeeds or to ensure test dlls exist
    $testBuildFailed = $false
    foreach ($t in $testProjects) {
        Write-Host "Building test project $($t.FullName)"
        dotnet build $t.FullName -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { Write-Err "Test project build failed for $($t.FullName)"; $testBuildFailed = $true; break }
    }
    if ($testBuildFailed) { throw "Test build failed" } else { Write-Ok "Test projects built" }

    # Ensure test results dir
    $testResultsDir = Join-Path $repoRoot 'tests\TestResults'
    if (-not (Test-Path $testResultsDir)) { New-Item -ItemType Directory -Path $testResultsDir | Out-Null }

    # Run tests
    $testFailed = $false
    foreach ($t in $testProjects) {
        Write-Host "Running tests for $($t.FullName)";
        dotnet test $t.FullName -c Release --no-build --logger trx --results-directory "$repoRoot/tests/TestResults"
        if ($LASTEXITCODE -ne 0) { Write-Err "Tests failed for $($t.FullName)"; $testFailed = $true; break }
    }
    if ($testFailed) { throw "Tests failed" } else { Write-Ok "All tests passed" }

    # Pack projects that declare IsPackable true
    $version = $env:PACKAGE_VERSION
    if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.1.0-alpha.1' }
    Write-Host "Using package version: $version"

    $packFailed = $false
    foreach ($proj in $srcProjects) {
        $content = Get-Content $proj.FullName -Raw
        if ($content -match '<IsPackable>\s*true\s*</IsPackable>') {
            Write-Host "Packing $($proj.FullName)"
            dotnet pack $proj.FullName -c Release -o $artifacts -p:Version=$version -p:PackageVersion=$version --include-symbols --include-source
            if ($LASTEXITCODE -ne 0) { Write-Err "Pack failed for $($proj.FullName)"; $packFailed = $true; break }
        }
        else {
            Write-Host "Skipping non-packable: $($proj.FullName)"
        }
    }
    if ($packFailed) { throw "Pack failed" } else { Write-Ok "Packing complete" }

    # Inspect packages
    $nupkgs = Get-ChildItem -Path $artifacts -Filter '*.nupkg' -File -ErrorAction SilentlyContinue
    if ($nupkgs.Count -eq 0) { Write-Warn "No nupkg files produced" } else { Write-Host "Produced packages:"; $nupkgs | ForEach-Object { Write-Host "  $($_.FullName)" } }

    # Optional signing
    if ($env:SIGNING_KEY) {
        Write-Host "Signing key detected; attempting to sign produced packages"
        $pfxPath = Join-Path $artifacts 'signing-cert.pfx'
        try {
            [System.IO.File]::WriteAllBytes($pfxPath, [System.Convert]::FromBase64String($env:SIGNING_KEY))
            foreach ($pkg in $nupkgs) {
                Write-Host "Signing $($pkg.FullName)"
                dotnet nuget sign $pkg.FullName --certificate-path $pfxPath --certificate-password $env:SIGNING_PASSWORD --timestamper http://timestamp.digicert.com
                if ($LASTEXITCODE -ne 0) { Write-Warn "Signing failed (continuing) for $($pkg.Name)" }
            }
            Write-Ok "Signing step completed (warnings possible)"
        }
        finally {
            if (Test-Path $pfxPath) { Remove-Item $pfxPath -Force }
        }
    }
    else {
        Write-Warn "No SIGNING_KEY present; skipping signing"
    }

    Write-Ok "Validation complete"
    exit 0
}
catch {
    Write-Err "Validation failed: $_"
    exit 2
}
