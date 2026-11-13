param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Quelyt'),
    [string]$Source = '',
    [switch]$SkipLaunch,
    [switch]$SkipDataBackup
)

# Updates the local Quelyt installation from a Windows Release build and
# creates a portable ZIP package. It never touches the user's library; that
# data lives under %APPDATA%\Quelyt and is copied aside once before first launch
# of a new version so a schema migration can be rolled back manually.
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $projectRoot 'build\windows\x64\runner\Release'
}
$Source = (Resolve-Path -LiteralPath $Source).Path
$executable = Join-Path $Source 'local_study.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    throw "Release executable not found. Run: .\scripts\check.ps1 -Task windows"
}

$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
if (-not $versionMatch) { throw 'Cannot read the version from pubspec.yaml.' }
$version = $versionMatch.Matches[0].Groups[1].Value
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$stageRoot = Join-Path $projectRoot "build\package\Quelyt-$version"
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
Copy-Item -Path (Join-Path $Source '*') -Destination $stageRoot -Recurse -Force
$icon = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
if (Test-Path -LiteralPath $icon) {
    Copy-Item -LiteralPath $icon -Destination (Join-Path $stageRoot 'app_icon.ico') -Force
}
@"
Quelyt $version (Windows x64)
================================
1. 将整个文件夹放到任意可写位置，运行 local_study.exe。
2. 资料库、笔记与设置保存在 %APPDATA%\Quelyt\Quelyt\local_study，
   升级或替换程序文件夹不会删除它们。
3. 更新前建议在设置 → 隐私与数据中执行一次整库备份。
4. API Key 使用 Windows 凭据保护保存，不在程序文件夹内。
"@ | Set-Content -LiteralPath (Join-Path $stageRoot '安装说明.txt') -Encoding UTF8

$dist = Join-Path $projectRoot 'build\dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$package = Join-Path $dist "Quelyt-$version-windows-x64.zip"
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $package -CompressionLevel Optimal

Get-Process -Name 'local_study' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

$installBackup = "$InstallDir.backup-$stamp"
$hadInstall = Test-Path -LiteralPath $InstallDir
if ($hadInstall) {
    if (Test-Path -LiteralPath $installBackup) {
        Remove-Item -LiteralPath $installBackup -Recurse -Force
    }
    Move-Item -LiteralPath $InstallDir -Destination $installBackup
}
try {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $stageRoot '*') -Destination $InstallDir -Recurse -Force
} catch {
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($hadInstall -and (Test-Path -LiteralPath $installBackup)) {
        Move-Item -LiteralPath $installBackup -Destination $InstallDir
    }
    throw
}

$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Quelyt.lnk'
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $InstallDir 'local_study.exe'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.IconLocation = (Join-Path $InstallDir 'app_icon.ico') + ',0'
$shortcut.Description = 'Quelyt'
$shortcut.Save()

$dataDir = Join-Path $env:APPDATA 'Quelyt\Quelyt\local_study'
$dataBackup = $null
if (-not $SkipDataBackup -and (Test-Path -LiteralPath $dataDir)) {
    $dataBackup = "$dataDir.pre-$version-$stamp"
    Copy-Item -LiteralPath $dataDir -Destination $dataBackup -Recurse -Force
}

$started = $false
if (-not $SkipLaunch) {
    Start-Process -FilePath (Join-Path $InstallDir 'local_study.exe') -WorkingDirectory $InstallDir | Out-Null
    Start-Sleep -Seconds 5
    $started = (Get-Process -Name 'local_study' -ErrorAction SilentlyContinue) -ne $null
}

[pscustomobject]@{
    Version = $version
    Package = $package
    PackageMB = [math]::Round((Get-Item -LiteralPath $package).Length / 1MB, 1)
    InstallDir = $InstallDir
    PreviousInstall = if ($hadInstall) { $installBackup } else { $null }
    Shortcut = $shortcutPath
    DataBackup = $dataBackup
    Started = $started
}
