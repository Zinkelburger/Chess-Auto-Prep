; Windows installer. Built by release.yml after `flutter build windows`:
;
;   ISCC.exe /DAppVersion=1.13.0 packaging\windows\installer.iss
;
; Per-user install under %LocalAppData%\Programs. The app files themselves need
; no elevation. On a machine without a sufficiently new Microsoft Visual C++
; x64 Runtime, Setup explains the prerequisite and launches Microsoft's own
; signed redistributable with one focused UAC prompt. The portable zip retains
; app-local runtime DLLs because it has no installer; this installer deliberately
; omits those loose copies and uses Microsoft's centrally serviced runtime.
;
; Adds a Start Menu entry, an uninstaller in Settings > Apps, and (on by
; default) the .pgn association. The association keys are the same ones the app
; writes for itself when run from the zip (windows/runner/desktop_integration.cpp);
; the choice recorded here is what stops the installed app from asking again.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Chess Auto Prep"
#define AppExe "chess_auto_prep.exe"
#define BundleDir "..\..\build\windows\x64\runner\Release"
#define VCRedistDir "prerequisites"

; These defaults are kept in step with tools/vc_redist.lock.json by
; tools/test_vc_redist.py. Release CI passes the same values explicitly.
#ifndef VCRedistVersion
  #define VCRedistVersion "14.44.35211.0"
#endif
#ifndef VCRedistMajor
  #define VCRedistMajor 14
#endif
#ifndef VCRedistMinor
  #define VCRedistMinor 44
#endif
#ifndef VCRedistBuild
  #define VCRedistBuild 35211
#endif

[Setup]
AppId={{B7E0C2A4-5D3F-4E6B-9C8A-1F2D3E4C5B6A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Chess Auto Prep
AppPublisherURL=https://github.com/Zinkelburger/Chess-Auto-Prep
AppSupportURL=https://github.com/Zinkelburger/Chess-Auto-Prep/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=chess-auto-prep-{#AppVersion}-windows-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes

[Tasks]
Name: "pgn"; Description: "Open .pgn files with {#AppName}"; GroupDescription: "File associations:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Keep this first: ExtractTemporaryFile can reach it cheaply even with solid
; compression. It is embedded in Setup but never left in the app directory.
Source: "{#VCRedistDir}\VC_redist.x64.exe"; Flags: dontcopy noencryption

; The setup build uses the centrally installed VC++ runtime. Excluding the
; loose copies prevents a stale app-local DLL from overriding the serviced one.
; The separately-produced portable zip still contains these files.
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "concrt140.dll,msvcp140*.dll,vcruntime140*.dll"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Runs only after PrepareToInstall has verified the central runtime. Remove
; precisely the app-local files deployed by older installers during upgrades.
Type: files; Name: "{app}\concrt140.dll"
Type: files; Name: "{app}\msvcp140.dll"
Type: files; Name: "{app}\msvcp140_1.dll"
Type: files; Name: "{app}\msvcp140_2.dll"
Type: files; Name: "{app}\msvcp140_atomic_wait.dll"
Type: files; Name: "{app}\msvcp140_codecvt_ids.dll"
Type: files; Name: "{app}\vcruntime140.dll"
Type: files; Name: "{app}\vcruntime140_1.dll"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; The app's own first-run offer reads this; the installer has already asked.
Root: HKCU; Subkey: "Software\ChessAutoPrep"; ValueType: string; ValueName: "FileAssociationChoice"; ValueData: "yes"; Tasks: pgn; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\ChessAutoPrep"; ValueType: string; ValueName: "FileAssociationChoice"; ValueData: "no"; Tasks: not pgn; Flags: uninsdeletekey

; ProgID for the type.
Root: HKCU; Subkey: "Software\Classes\ChessAutoPrep.pgn"; ValueType: string; ValueData: "PGN chess games"; Tasks: pgn; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ChessAutoPrep.pgn\DefaultIcon"; ValueType: string; ValueData: """{app}\{#AppExe}"",0"; Tasks: pgn
Root: HKCU; Subkey: "Software\Classes\ChessAutoPrep.pgn\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: pgn

; A place in the "Open with" list, and the default when nothing else owns
; .pgn. Windows keeps a default the user picked themselves ahead of both.
Root: HKCU; Subkey: "Software\Classes\.pgn\OpenWithProgids"; ValueType: string; ValueName: "ChessAutoPrep.pgn"; ValueData: ""; Tasks: pgn; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.pgn"; ValueType: string; ValueData: "ChessAutoPrep.pgn"; Tasks: pgn; Check: PgnIsUnclaimed; Flags: uninsdeletevalue

; Lets Windows list the app by name in "Open with" and Default apps.
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{#AppName}"; Tasks: pgn; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: pgn
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".pgn"; ValueData: ""; Tasks: pgn

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
const
  VCRuntimeKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
  RequiredVCRedistMajor = {#VCRedistMajor};
  RequiredVCRedistMinor = {#VCRedistMinor};
  RequiredVCRedistBuild = {#VCRedistBuild};

var
  VCRedistPage: TOutputMsgWizardPage;

function VCRedistIsCurrent: Boolean;
var
  Installed: Cardinal;
  Major: Cardinal;
  Minor: Cardinal;
  Build: Cardinal;
begin
  Result :=
    IsWin64 and
    RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Installed', Installed) and
    (Installed = 1) and
    RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Major', Major) and
    RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Minor', Minor) and
    RegQueryDWordValue(HKLM64, VCRuntimeKey, 'Bld', Build) and
    ((Major > RequiredVCRedistMajor) or
     ((Major = RequiredVCRedistMajor) and (Minor > RequiredVCRedistMinor)) or
     ((Major = RequiredVCRedistMajor) and
      (Minor = RequiredVCRedistMinor) and
      (Build >= RequiredVCRedistBuild)));
end;

procedure InitializeWizard;
begin
  VCRedistPage := CreateOutputMsgPage(
    wpSelectDir,
    'Required Microsoft component',
    'Microsoft Visual C++ 2015-2022 Runtime (x64)',
    'Chess Auto Prep and its analysis engines need Microsoft''s Visual C++ ' +
    'Runtime {#VCRedistVersion} or newer.' + #13#10 + #13#10 +
    'Setup did not find a sufficiently new copy. When you continue, Windows ' +
    'will ask for permission to install Microsoft''s signed runtime. Chess ' +
    'Auto Prep itself remains a per-user installation.' + #13#10 + #13#10 +
    'The runtime package is included in this installer, so this step also ' +
    'works offline. It will be maintained centrally by Windows rather than ' +
    'copied as loose DLL files into the application folder.' + #13#10 + #13#10 +
    'If you cannot approve this system component, cancel Setup and use the ' +
    'portable Windows ZIP instead; it carries the required runtime locally.');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = VCRedistPage.ID) and VCRedistIsCurrent;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  Prerequisite: String;
begin
  Result := '';
  if VCRedistIsCurrent then
    exit;

  ExtractTemporaryFile('VC_redist.x64.exe');
  Prerequisite := ExpandConstant('{tmp}\VC_redist.x64.exe');

  WizardForm.StatusLabel.Caption :=
    'Installing Microsoft Visual C++ Runtime {#VCRedistVersion}...';
  if not ShellExec(
    'runas',
    Prerequisite,
    '/install /quiet /norestart',
    '',
    SW_SHOW,
    ewWaitUntilTerminated,
    ExitCode) then
  begin
    Result :=
      'Windows did not allow the required Microsoft Visual C++ Runtime to ' +
      'start.' + #13#10 + #13#10 +
      SysErrorMessage(ExitCode) + #13#10 + #13#10 +
      'Choose Back and try again. Accept the Windows permission prompt; ' +
      'without this Microsoft component Chess Auto Prep cannot start. Or ' +
      'cancel Setup and use the portable Windows ZIP, which needs no admin ' +
      'permission.';
    exit;
  end;

  if ExitCode = 3010 then
  begin
    NeedsRestart := True;
  end
  else if (ExitCode <> 0) and (ExitCode <> 1638) then
  begin
    Result :=
      'Microsoft Visual C++ Runtime setup did not complete (exit code ' +
      IntToStr(ExitCode) + ').' + #13#10 + #13#10 +
      'Choose Back and try again. If it continues to fail, repair the ' +
      'Microsoft Visual C++ 2015-2022 Redistributable (x64) from Windows ' +
      'Settings, then run Chess Auto Prep Setup again.';
    exit;
  end;

  // Exit 1638 means another v14 runtime is already installed. Re-read the
  // registry in both successful cases so Setup never launches a broken app.
  if not VCRedistIsCurrent then
  begin
    Result :=
      'Microsoft Visual C++ Runtime setup finished, but Windows still does ' +
      'not report version {#VCRedistVersion} or newer.' + #13#10 + #13#10 +
      'Restart Windows if one was requested, then run Chess Auto Prep Setup ' +
      'again.';
  end;
end;

function PgnIsUnclaimed: Boolean;
var
  Current: String;
begin
  Result := (not RegQueryStringValue(HKEY_CLASSES_ROOT, '.pgn', '', Current)) or (Current = '');
end;
