#ifndef BundleDir
#error BundleDir is required
#endif
#ifndef OutputDir
#error OutputDir is required
#endif
[Setup]
AppId={{6E813503-7B69-4843-91A0-7970281F48B8}
AppName=Deskling
AppVersion=0.2.2
AppPublisher=Michael Wong
DefaultDirName={localappdata}\Deskling\App
DisableDirPage=yes
DefaultGroupName=Deskling
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#OutputDir}
OutputBaseFilename=Deskling-0.2.2-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#BundleDir}\deskling.ico
UninstallDisplayIcon={app}\deskling.ico
CloseApplications=yes
RestartApplications=no
SignTool=deskling
SignedUninstaller=yes
UninstallDisplayName=Deskling companion
[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleDir}\tools\gift_setup\installer_hooks.py"; Flags: dontcopy
[Icons]
Name: "{group}\Deskling Setup"; Filename: "{app}\runtime\pythonw.exe"; Parameters: "-m tools.gift_setup.app"; WorkingDir: "{app}"; IconFilename: "{app}\deskling.ico"
[Run]
Filename: "{app}\runtime\pythonw.exe"; Parameters: "-m tools.gift_setup.app"; WorkingDir: "{app}"; Description: "Open Deskling setup"; Flags: nowait postinstall skipifsilent
[Code]
function RunHook(Action: String; Temporary: Boolean): Boolean;
var Python, Hook: String; ResultCode: Integer;
begin
  Python := ExpandConstant('{app}\runtime\python.exe');
  if not FileExists(Python) then begin Result := True; exit; end;
  if Temporary then begin
    ExtractTemporaryFile('installer_hooks.py');
    Hook := ExpandConstant('{tmp}\installer_hooks.py');
  end else Hook := ExpandConstant('{app}\tools\gift_setup\installer_hooks.py');
  Result := Exec(Python, '"' + Hook + '" ' + Action, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if Result then Result := ResultCode = 0;
end;
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if not RunHook('prepare', True) then Result := 'Deskling could not safely stop its existing companion. Close Deskling and retry.' else Result := '';
end;
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    if not RunHook('finish', False) then
      MsgBox('Deskling was installed, but the companion could not restart. Open Deskling Setup from Start to finish setup.', mbError, MB_OK);
end;
function InitializeUninstall(): Boolean;
begin
  Result := RunHook('remove', False);
  if not Result then MsgBox('Deskling could not verify ownership of its startup task. Uninstall was stopped to preserve the existing service.', mbError, MB_OK);
end;
