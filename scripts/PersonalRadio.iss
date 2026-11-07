#ifndef PackageDir
  #error "Pass /DPackageDir with the staged Windows bundle."
#endif
#ifndef AppVersion
  #error "Pass /DAppVersion with the player version."
#endif

[Setup]
AppId={{96D7A73D-0727-433A-84CD-6A5B6DF3263A}
AppName=Personal Radio
AppVersion={#AppVersion}
AppPublisher=Personal Radio
AppPublisherURL=https://github.com/0withoutface0/personal-radio
DefaultDirName={localappdata}\Programs\Personal Radio
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\personal_radio.exe
CloseApplications=yes
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputBaseFilename=PersonalRadio-Windows-x64-Setup

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Personal Radio"; Filename: "{app}\personal_radio.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\personal_radio.exe"; Description: "Launch Personal Radio"; Flags: nowait postinstall skipifsilent
