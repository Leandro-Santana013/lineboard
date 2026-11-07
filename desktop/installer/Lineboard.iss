#ifndef AppVersion
#define AppVersion "0.1.0"
#endif
#ifndef StageRoot
#define StageRoot "..\\bin"
#endif
#ifndef OutputDir
#define OutputDir "..\\..\\dist"
#endif

[Setup]
AppId={{B8AA1CB4-2E55-4F67-9C60-4E934E5E0B8D}
AppName=Lineboard
AppVersion={#AppVersion}
AppPublisher=Lineboard
DefaultDirName={autopf}\Lineboard
DefaultGroupName=Lineboard
OutputDir={#OutputDir}
OutputBaseFilename=Lineboard-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\Lineboard.exe
CloseApplications=yes
RestartApplications=yes

[Files]
Source: "{#StageRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "config.json,MicrosoftEdgeWebView2Setup.exe"
Source: "{#StageRoot}\config.json"; DestDir: "{commonappdata}\Lineboard"; DestName: "config.json"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#StageRoot}\MicrosoftEdgeWebView2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Dirs]
Name: "{commonappdata}\Lineboard"

[Icons]
Name: "{autoprograms}\Lineboard"; Filename: "{app}\Lineboard.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Lineboard"; Filename: "{app}\Lineboard.exe"; WorkingDir: "{app}"

[Run]
Filename: "{tmp}\MicrosoftEdgeWebView2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Instalando o Microsoft Edge WebView2..."; Flags: waituntilterminated skipifdoesntexist
Filename: "{app}\Lineboard.exe"; Description: "Abrir o Lineboard"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
Type: files; Name: "{commonappdata}\Lineboard\config.json"
Type: dirifempty; Name: "{commonappdata}\Lineboard"
