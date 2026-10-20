; Inno Setup script for PulseEight Control (Windows). Built by installer\build-installer.ps1, which passes:
;   /DAppVersion=0.2.0-rc.1 the version people see (from the release tag; scripts/release/version.py)
;   /DAppBuild=0.2.0.201    what the update feed compares against; must be four numbers (it is the file version)
;   /DArch=x64|arm64        which processor this installer is for
;   /DSourceDir=...         the folder the app was built into (the .exe and everything beside it)
;   /DOutputDir=...         where the Setup .exe goes
;
; Per-user install: no administrator prompt, so an update can run silently as the signed-in user.

#ifndef AppVersion
  #error AppVersion is required (build-installer.ps1 passes it).
#endif
#ifndef AppBuild
  #error AppBuild is required (build-installer.ps1 passes it).
#endif
#ifndef Arch
  #error Arch is required: x64 or arm64.
#endif
#ifndef SourceDir
  #error SourceDir is required.
#endif
#ifndef OutputDir
  #define OutputDir "..\..\out\release"
#endif

[Setup]
; Never change this: it is how a new version finds and replaces the one already installed.
AppId={{A637F9EB-8428-4747-8E81-D8D91D7BA3F4}
AppName=PulseEight Control
AppVersion={#AppVersion}
VersionInfoVersion={#AppBuild}
DefaultDirName={autopf}\PulseEight Control
DefaultGroupName=PulseEight Control
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
UninstallDisplayName=PulseEight Control
UninstallDisplayIcon={app}\PulseEightControl.exe
; The installer's own icon (the app's .exe carries the same one for the shortcuts and Add/Remove Programs).
SetupIconFile=..\App\Assets\AppIcon.ico
OutputDir={#OutputDir}
OutputBaseFilename=PulseEightControl-Setup-{#AppVersion}-{#Arch}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
; Close the running app so its files can be replaced; the [Run] entry below starts it again.
CloseApplications=yes
RestartApplications=no
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\PulseEight Control"; Filename: "{app}\PulseEightControl.exe"
Name: "{autodesktop}\PulseEight Control"; Filename: "{app}\PulseEightControl.exe"; Tasks: desktopicon

[Run]
; After a normal install the wizard offers to start the app; after a silent one (an update) it just does.
Filename: "{app}\PulseEightControl.exe"; Description: "{cm:LaunchProgram,PulseEight Control}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\PulseEightControl.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent
