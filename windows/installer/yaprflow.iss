#define AppVersion "0.2.1"
[Setup]
AppId={{D8556A6D-96DC-47B0-8B96-A80F932A9460}
AppName=yaprflow
AppVersion={#AppVersion}
AppPublisher=Team Wong
AppPublisherURL=https://github.com/M1w234/yaprflow-mw
DefaultDirName={localappdata}\Programs\yaprflow
DefaultGroupName=yaprflow
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\artifacts
OutputBaseFilename=yaprflow-{#AppVersion}-windows-x64-preview-setup
SetupIconFile=..\src\YaprFlow.Windows\Assets\yaprflow.ico
UninstallDisplayIcon={app}\yaprflow.exe
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
AppMutex=Local\TeamWong.YaprFlow.Windows

[Files]
Source: "..\artifacts\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\yaprflow"; Filename: "{app}\yaprflow.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "YaprFlow"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\yaprflow.exe"; Description: "Open yaprflow"; Flags: nowait postinstall skipifsilent

; Uninstall preserves user history and the downloaded model. The app provides
; explicit history deletion; data location is documented in Settings and README.
