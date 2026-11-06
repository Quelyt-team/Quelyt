param(
    [ValidateSet('check', 'analyze', 'test', 'doctor', 'windows', 'android', 'run')]
    [string]$Task = 'check'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workingRoot = $projectRoot

# Flutter's Windows shader compiler requires an ASCII SDK path. A junction is
# only an alias to this workspace; it does not move files or change the system.
if ($workingRoot -match '[^\x00-\x7F]') {
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $tag = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot)))).Replace('-', '').Substring(0, 12)
    } finally { $hash.Dispose() }
    $workingRoot = Join-Path ([IO.Path]::GetTempPath()) "local_study_$tag"
    if (Test-Path -LiteralPath $workingRoot) {
        $existing = Get-Item -LiteralPath $workingRoot -Force
        if (($existing.Target | Select-Object -First 1) -ne $projectRoot) {
            throw "The temporary alias points to another location: $workingRoot"
        }
    } else {
        New-Item -ItemType Junction -Path $workingRoot -Target $projectRoot | Out-Null
    }
}

$flutterPath = Join-Path $workingRoot '.tooling/flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $flutterPath)) {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutterCommand) { throw 'Install Flutter 3.47.9 or place it in .tooling/flutter first.' }
    $flutterPath = $flutterCommand.Source
}
$savedEnvironment = @{}
foreach ($name in @('PUB_CACHE', 'APPDATA', 'FLUTTER_SUPPRESS_ANALYTICS', 'DART_SUPPRESS_ANALYTICS', 'JAVA_HOME', 'ANDROID_HOME', 'GRADLE_USER_HOME')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:PUB_CACHE = Join-Path $workingRoot '.tooling/pub-cache'
$env:APPDATA = Join-Path $workingRoot '.tooling/appdata'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'GRADLE_USER_HOME')) {
    if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) {
        $installedValue = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($installedValue) { [Environment]::SetEnvironmentVariable($name, $installedValue, 'Process') }
    }
}

function Invoke-Flutter {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & $flutterPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter command failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

Push-Location -LiteralPath $workingRoot
try {
    & $flutterPath pub get
    $pubExit = $LASTEXITCODE
    # Flutter writes this inventory before trying plugin symlinks. Junctions
    # provide the same local directory access without a system setting.
    $inventory = Join-Path $workingRoot '.flutter-plugins-dependencies'
    if (Test-Path -LiteralPath $inventory) {
        $plugins = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
        $linkRoot = Join-Path $workingRoot 'windows/flutter/ephemeral/.plugin_symlinks'
        New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
        foreach ($plugin in $plugins.plugins.windows) {
            $link = Join-Path $linkRoot $plugin.name
            if (Test-Path -LiteralPath $link) {
                $entry = Get-Item -LiteralPath $link -Force
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    throw "A non-link directory occupies $link; inspect it manually."
                }
                if (($entry.Target | Select-Object -First 1) -eq $plugin.path) { continue }
                # Remove just this generated junction, never its target.
                [IO.Directory]::Delete($link)
            }
            New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
        }
    }
    if ($pubExit -ne 0) {
        Invoke-Flutter -Arguments @('pub', 'get')
    }
    switch ($Task) {
        'check' {
            Invoke-Flutter -Arguments @('analyze', '--no-pub')
            Invoke-Flutter -Arguments @('test', '--no-pub')
        }
        'analyze' { Invoke-Flutter -Arguments @('analyze', '--no-pub') }
        'test' { Invoke-Flutter -Arguments @('test', '--no-pub') }
        'doctor' { Invoke-Flutter -Arguments @('doctor', '-v') }
        'windows' { Invoke-Flutter -Arguments @('build', 'windows', '--release', '--no-pub') }
        'android' { Invoke-Flutter -Arguments @('build', 'apk', '--release', '--no-pub', '--target-platform', 'android-arm64') }
        'run' { Invoke-Flutter -Arguments @('run', '-d', 'windows', '--no-pub') }
    }
} finally {
    Pop-Location
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}

