; Windows installer. Built by release.yml after `flutter build windows`:
;
;   ISCC.exe /DAppVersion=1.13.0 packaging\windows\installer.iss
;
; Per-user install under %LocalAppData%\Programs, so there is no UAC prompt
; and no admin account needed. Adds a Start Menu entry, an uninstaller in
; Settings > Apps, and (on by default) the .pgn association. The association
; keys are the same ones the app writes for itself when run from the zip
; (windows/runner/desktop_integration.cpp); the choice recorded here is what
; stops the installed app from asking again.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Chess Auto Prep"
#define AppExe "chess_auto_prep.exe"
#define BundleDir "..\..\build\windows\x64\runner\Release"

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
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

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
function PgnIsUnclaimed: Boolean;
var
  Current: String;
begin
  Result := (not RegQueryStringValue(HKEY_CLASSES_ROOT, '.pgn', '', Current)) or (Current = '');
end;
