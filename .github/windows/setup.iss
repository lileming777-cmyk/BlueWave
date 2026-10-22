[Setup]
AppId={{B3D5574D-B560-4F24-B687-B03EF637B902}
AppName=BlueWave 蓝调音乐
AppVersion=1.0.4
AppPublisher=BlueWave contributors
DefaultDirName={localappdata}\Programs\BlueWave
DefaultGroupName=BlueWave
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=BlueWave-1.0.4-windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\BlueWave.exe

[Tasks]
Name: desktopicon; Description: "创建桌面快捷方式"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\BlueWave 蓝调音乐"; Filename: "{app}\BlueWave.exe"
Name: "{autodesktop}\BlueWave 蓝调音乐"; Filename: "{app}\BlueWave.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\BlueWave.exe"; Description: "启动 BlueWave"; Flags: nowait postinstall skipifsilent
