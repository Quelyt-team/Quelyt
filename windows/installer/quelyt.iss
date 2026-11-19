; Quelyt Windows One-Click Installer Script (Inno Setup 6)
; Compiled by scripts/build-windows-installer.ps1

#ifndef MyAppVersion
  #define MyAppVersion "0.3.0-dev+35"
#endif
#ifndef MyAppNumericVersion
  #define MyAppNumericVersion "0.3.0.35"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\build\dist"
#endif
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "Quelyt-" + MyAppVersion + "-windows-x64-setup"
#endif

#define MyAppName "Quelyt"
#define MyAppPublisher "Quelyt"
#define MyAppURL "https://github.com/Quelyt-team/Quelyt"
#define MyAppExeName "local_study.exe"

[Setup]
AppId={{8F54A3E1-9A2D-4C8B-B62F-3E17D94C0B5E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
VersionInfoVersion={#MyAppNumericVersion}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppNumericVersion}
VersionInfoDescription=Quelyt 本地教材自学与论文精读安装程序
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UsePreviousAppDir=yes
DirExistsWarning=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableWelcomePage=yes
DisableDirPage=no
DisableProgramGroupPage=yes
DisableReadyPage=yes
AllowNoIcons=yes
WizardStyle=modern
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"; WorkingDir: "{app}"; Comment: "Quelyt 本地教材自学与论文精读"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"; WorkingDir: "{app}"; Comment: "Quelyt 本地教材自学与论文精读"; Check: ShouldCreateDesktopShortcut

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DesktopShortcutCheck: TNewCheckBox;
  DataSafeLabel: TNewStaticText;

procedure InitializeWizard();
begin
  DesktopShortcutCheck := TNewCheckBox.Create(WizardForm);
  DesktopShortcutCheck.Parent := WizardForm.SelectDirPage;
  DesktopShortcutCheck.Left := WizardForm.DirEdit.Left;
  DesktopShortcutCheck.Top := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(18);
  DesktopShortcutCheck.Width := WizardForm.SelectDirPage.Width - DesktopShortcutCheck.Left - ScaleX(12);
  DesktopShortcutCheck.Height := ScaleY(20);
  DesktopShortcutCheck.Caption := CustomMessage('DesktopShortcut');
  DesktopShortcutCheck.Checked := True;

  DataSafeLabel := TNewStaticText.Create(WizardForm);
  DataSafeLabel.Parent := WizardForm.SelectDirPage;
  DataSafeLabel.Left := WizardForm.DirEdit.Left;
  DataSafeLabel.Top := DesktopShortcutCheck.Top + DesktopShortcutCheck.Height + ScaleY(10);
  DataSafeLabel.Width := WizardForm.SelectDirPage.Width - DataSafeLabel.Left - ScaleX(12);
  DataSafeLabel.AutoSize := True;
  DataSafeLabel.WordWrap := True;
  DataSafeLabel.Caption := CustomMessage('DataSafeNote');
end;

function ShouldCreateDesktopShortcut(): Boolean;
begin
  Result := (DesktopShortcutCheck = nil) or DesktopShortcutCheck.Checked;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  // Gracefully stop running Quelyt instances so in-place upgrades succeed cleanly.
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM local_study.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(400);
  Result := '';
end;
