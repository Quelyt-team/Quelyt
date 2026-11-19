; Simplified Chinese messages for Quelyt Windows Installer (Inno Setup 6.5+)

[LangOptions]
LanguageName=简体中文
LanguageID=$0804
LanguageCodePage=936
DialogFontName=Microsoft YaHei UI
DialogFontSize=9
WelcomeFontName=Microsoft YaHei UI
WelcomeFontSize=13

[Messages]
SetupAppTitle=Quelyt 安装程序
SetupWindowTitle=安装 %1
UninstallAppTitle=卸载 Quelyt
UninstallAppFullTitle=卸载 %1

InformationTitle=提示
ConfirmTitle=确认
ErrorTitle=错误

SetupLdrStartupMessage=即将安装 %1，是否继续？
LdrCannotCreateTemp=无法创建临时文件，安装已中止。
LdrCannotExecTemp=无法在临时目录中执行文件，安装已中止。

SetupAlreadyRunning=安装程序已在运行中。
WindowsVersionNotSupported=当前 Windows 版本不支持此程序。
OnlyOnTheseArchitectures=此程序仅支持在以下架构的 Windows 系统上安装：%n%n%1
SetupAppRunningError=检测到 %1 正在运行。%n%n请先关闭它，然后点击“确定”继续，或点击“取消”退出。
UninstallAppRunningError=检测到 %1 正在运行。%n%n请先关闭它，然后点击“确定”继续，或点击“取消”退出。

ExitSetupTitle=退出安装
ExitSetupMessage=安装尚未完成。如果现在退出，程序将不会被安装。%n%n确定要退出安装程序吗？
AboutSetupMenuItem=关于安装程序(&A)...
AboutSetupTitle=关于安装程序

ButtonBack=< 上一步(&B)
ButtonNext=下一步(&N) >
ButtonInstall=立即安装(&I)
ButtonOK=确定
ButtonCancel=取消
ButtonYes=是(&Y)
ButtonYesToAll=全部是(&A)
ButtonNo=否(&N)
ButtonNoToAll=全部否(&O)
ButtonFinish=完成(&F)
ButtonBrowse=浏览(&B)...
ButtonWizardBrowse=浏览(&R)...
ButtonNewFolder=新建文件夹(&M)

ClickNext=点击“下一步”继续，或点击“取消”退出安装。
BrowseDialogTitle=选择安装文件夹
BrowseDialogLabel=请在下方选择一个文件夹，然后点击“确定”。
NewFolderName=新建文件夹

WizardSelectDir=一键安装 Quelyt
SelectDirDesc=选择安装位置后，点击“立即安装”即可开始（升级不会影响已有资料库与笔记）。
SelectDirLabel3=将把 [name] 安装到以下文件夹：
SelectDirBrowseLabel=如需更改目录请点击“浏览”；确认无误后点击“立即安装”。
DiskSpaceGBLabel=至少需要 [gb] GB 可用磁盘空间。
DiskSpaceMBLabel=至少需要 [mb] MB 可用磁盘空间。
CannotInstallToNetworkDrive=无法安装到网络驱动器。
CannotInstallToUNCPath=无法安装到 UNC 网络路径。
InvalidPath=请输入包含盘符的完整路径，例如：%n%nC:\Quelyt
InvalidDrive=所选驱动器不存在或无法访问，请重新选择。
DiskSpaceWarningTitle=磁盘空间不足
DiskSpaceWarning=安装至少需要 %1 KB 可用空间，但所选驱动器仅剩 %2 KB。%n%n是否仍要继续安装？
DirNameTooLong=文件夹名称或路径过长。
InvalidDirName=文件夹名称无效。
BadDirName32=文件夹名称不能包含以下字符：%n%n%1
DirExistsTitle=文件夹已存在
DirExists=文件夹：%n%n%1%n%n已存在。是否仍要安装到此目录？
DirDoesntExistTitle=文件夹不存在
DirDoesntExist=文件夹：%n%n%1%n%n尚不存在，是否创建？

WizardPreparing=正在准备安装
PreparingDesc=正在准备将 [name] 安装到您的电脑上。
ApplicationsFound=以下程序正在使用需要更新的文件，建议允许安装程序自动关闭它们。
ApplicationsFound2=以下程序正在使用需要更新的文件，建议允许安装程序自动关闭它们。安装完成后将尝试重新启动。
CloseApplications=自动关闭这些程序(&A)
DontCloseApplications=不关闭这些程序(&D)
ErrorCloseApplications=无法自动关闭所有占用文件的程序，建议手动关闭后再继续。

WizardInstalling=正在安装
InstallingLabel=正在安装 [name]，请稍候...

FinishedHeadingLabel=[name] 安装完成
FinishedLabelNoIcons=[name] 已成功安装到您的电脑上。
FinishedLabel=[name] 已成功安装到您的电脑上。可通过桌面或开始菜单快捷方式启动。
ClickFinish=点击“完成”退出安装程序。
RunEntryExec=立即启动 %1
RunEntryShellExec=查看 %1

SetupAborted=安装未完成。%n%n请排查问题后重新运行安装程序。
StatusClosingApplications=正在关闭运行中的程序...
StatusCreateDirs=正在创建目录...
StatusExtractFiles=正在解压程序文件...
StatusCreateIcons=正在创建快捷方式...
StatusCreateRegistryEntries=正在写入系统注册信息...
StatusSavingUninstall=正在保存卸载信息...
StatusRunProgram=正在完成安装...
StatusRollback=正在回滚更改...

ConfirmUninstall=确定要卸载 %1 及其程序文件吗？%n%n（您的资料库、笔记和设置保存在用户数据目录中，不会被删除。）
UninstallStatusLabel=正在从您的电脑中移除 %1，请稍候...
UninstalledAll=%1 已成功卸载。
UninstalledMost=%1 卸载完成，部分残留文件可手动删除。
WizardUninstalling=正在卸载
StatusUninstalling=正在卸载 %1...

[CustomMessages]
LaunchProgram=立即启动 %1
UninstallProgram=卸载 %1
DesktopShortcut=创建桌面快捷方式
DataSafeNote=本地资料库、笔记与 API 凭据保存在用户数据目录，升级或卸载均不会清除。
