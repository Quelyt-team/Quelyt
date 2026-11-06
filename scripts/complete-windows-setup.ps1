$ErrorActionPreference = 'Stop'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$installer = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe'
$installPath = 'D:\DevTools\VS2022BuildTools'
if (-not (Test-Path -LiteralPath $installer)) { throw 'Visual Studio Installer is not installed.' }

if (Test-Path -LiteralPath $vswhere) {
    $installed = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.ATL -property installationPath
    if ($installed -contains $installPath -or $installed -eq $installPath) {
        Write-Output 'The required ATL component is already installed.'
        exit 0
    }
}
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
    throw 'Microsoft installer signature validation failed.'
}
$arguments = @('modify', '--installPath', $installPath, '--add',
    'Microsoft.VisualStudio.Component.VC.ATL', '--quiet', '--norestart', '--nocache')
Write-Output 'Allow the Microsoft installer in the Windows administrator permission dialog.'
try {
    $process = Start-Process -FilePath $installer -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru -Wait
} catch {
    throw 'Windows administrator confirmation was not completed. ATL has not been installed.'
}
if ($process.ExitCode -notin @(0, 3010)) { throw "ATL installation failed with exit code $($process.ExitCode)." }
Write-Output 'ATL component installation completed.'
if ($process.ExitCode -eq 3010) { Write-Output 'The installer requires a Windows restart before building.' }
