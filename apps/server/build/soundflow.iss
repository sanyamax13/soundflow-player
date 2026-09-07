; SoundFlow — установщик «сервера в одном приложении».
; Собирается через build\build.ps1 (кладёт всё нужное в build\dist\ и зовёт ISCC).
;
; Ставит в %LocalAppData%\Programs\SoundFlow (без прав администратора).
; База и логи создаются приложением в %LocalAppData%\SoundFlow.
; Тихо доустанавливает VC++ Redistributable x64 (нужен onnxruntime.dll) и
; WebView2 Runtime, если их нет.

#define AppName "SoundFlow"
#define AppVer "0.1.0"
#define AppPublisher "SoundFlow"
#define AppExe "SoundFlow.exe"

[Setup]
AppId={{9E5C4B10-7F2A-4E8B-9C3D-SOUNDFLOW0001}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=dist
OutputBaseFilename=SoundFlow-Setup-{#AppVer}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExe}
SetupLogging=yes

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Ярлык на рабочем столе"; GroupDescription: "Ярлыки:"

[Files]
Source: "dist\app\{#AppExe}";        DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\onnxruntime.dll";  DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\cnn14.onnx";       DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\cnn14.onnx.data";  DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\ffmpeg.exe";       DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\README.txt";       DestDir: "{app}"; Flags: ignoreversion isreadme
; soundflow.db в установщик не входит — приходит из soundflow-import и живёт
; в %LocalAppData%\SoundFlow. Пустую базу приложение создаёт само при первом запуске.

; редисты кладём во временную папку, ставим из [Run], потом удаляем
Source: "dist\redist\vc_redist.x64.exe";              DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist
Source: "dist\redist\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}";            Filename: "{app}\{#AppExe}"
Name: "{group}\Удалить {#AppName}";    Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";      Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Установка компонентов Visual C++…"; Check: NeedsVCRedist; Flags: waituntilterminated skipifdoesntexist
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; \
  StatusMsg: "Установка WebView2…"; Check: NeedsWebView2; Flags: waituntilterminated skipifdoesntexist
Filename: "{app}\{#AppExe}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent

[Code]
function NeedsVCRedist: Boolean;
var v: Cardinal;
begin
  Result := not RegQueryDWordValue(HKLM,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', v) or (v <> 1);
end;

function NeedsWebView2: Boolean;
var s: String;
begin
  Result :=
    not RegQueryStringValue(HKLM,
      'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', s)
    and not RegQueryStringValue(HKCU,
      'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', s);
end;
