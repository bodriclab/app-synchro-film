; Inno Setup script for Synchro Film (per-user install, no admin rights needed)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6E2B7C1A-5F3D-4B8E-9A21-53C0F1D7A9B4}
AppName=Synchro Film
AppVersion={#AppVersion}
AppPublisher=bodriclab
AppPublisherURL=https://github.com/bodriclab/app-synchro-film
DefaultDirName={localappdata}\Programs\Synchro Film
DefaultGroupName=Synchro Film
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=SynchroFilm-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\app_synchro_film.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Synchro Film"; Filename: "{app}\app_synchro_film.exe"
Name: "{autodesktop}\Synchro Film"; Filename: "{app}\app_synchro_film.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\app_synchro_film.exe"; Description: "{cm:LaunchProgram,Synchro Film}"; Flags: nowait postinstall skipifsilent
