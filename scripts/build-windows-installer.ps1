param(
    [string]$Source = '',
    [string]$OutputDir = '',
    [switch]$Build
)

# Builds a standalone one-click Windows installer (Setup.exe) using Inno Setup 6.
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ($Build) {
    & (Join-Path $PSScriptRoot 'check.ps1') -Task windows
    if ($LASTEXITCODE -ne 0) { throw "Windows release build failed (exit $LASTEXITCODE)." }
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $projectRoot 'build\windows\x64\runner\Release'
}
$Source = (Resolve-Path -LiteralPath $Source).Path
$executable = Join-Path $Source 'local_study.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    throw "Release executable not found at $executable. Run .\scripts\check.ps1 -Task windows first (or pass -Build)."
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $projectRoot 'build\dist'
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
if (-not $versionMatch) { throw 'Cannot read version from pubspec.yaml.' }
$version = $versionMatch.Matches[0].Groups[1].Value

# Convert SemVer (e.g. 0.3.0-dev+35) into Windows 4-part numeric version (0.3.0.35).
$major = 0; $minor = 0; $patch = 0; $buildNum = 0
if ($version -match '^(\d+)\.(\d+)\.(\d+)(?:-[^+]+)?(?:\+(\d+))?') {
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = [int]$Matches[3]
    if ($Matches[4]) { $buildNum = [int]$Matches[4] }
}
$numericVersion = "$major.$minor.$patch.$buildNum"

# Locate Inno Setup Compiler (ISCC.exe).
$isccCandidates = @(
    (Get-Command 'iscc' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path $projectRoot '.tooling\inno-setup\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$iscc = $isccCandidates | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup 6 (ISCC.exe) not found. Install via: winget install --id JRSoftware.InnoSetup --scope user'
}

$issPath = Join-Path $projectRoot 'windows\installer\quelyt.iss'
$baseName = "Quelyt-$version-windows-x64-setup"
$outputExe = Join-Path $OutputDir "$baseName.exe"

Write-Host "Compiling one-click installer with $iscc ..."
& $iscc `
    "/DMyAppVersion=$version" `
    "/DMyAppNumericVersion=$numericVersion" `
    "/DMySourceDir=$Source" `
    "/DMyOutputDir=$OutputDir" `
    "/DMyOutputBaseFilename=$baseName" `
    $issPath

if ($LASTEXITCODE -ne 0) {
    throw "ISCC.exe failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $outputExe)) {
    throw "Expected installer was not produced: $outputExe"
}

[pscustomobject]@{
    Version     = $version
    Installer   = $outputExe
    InstallerMB = [math]::Round((Get-Item -LiteralPath $outputExe).Length / 1MB, 1)
}
