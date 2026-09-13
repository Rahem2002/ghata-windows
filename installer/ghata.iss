#define MyAppName "Ghata"
#define MyAppVersion "1.0.1"
#define MyAppPublisher "MRS"
#define MyAppExeName "ghata.exe"

[Setup]
AppId={{8D02C2F6-29D8-4B68-9B57-47F4DA6C62A1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Ghata
DefaultGroupName=Ghata
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=Ghata-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Ghata"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Ghata"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Ghata"; Flags: nowait postinstall skipifsilent
