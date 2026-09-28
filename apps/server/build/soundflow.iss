; SoundFlow — установщик «сервера в одном приложении».
; Собирается через build\build.ps1 (кладёт всё нужное в build\dist\ и зовёт ISCC).
;
; Ставит в %LocalAppData%\Programs\SoundFlow (без прав администратора).
; База и логи создаются приложением в %LocalAppData%\SoundFlow.
; Тихо доустанавливает VC++ Redistributable x64 (нужен onnxruntime.dll) и
; WebView2 Runtime, если их нет.
;
; Своя копия плеера у другого человека (28.09.2026): в установщике ещё качалка (Яндекс, торренты) с
; переносным Python и qBittorrent. Настройки человека — %LocalAppData%\SoundFlow\settings.json, база
; и ключ канала там же: установщик и обновления эту папку не трогают.

#define AppName "SoundFlow"
#ifndef AppVer
  #define AppVer "0.1.0"
#endif
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
; Без окна «для меня / для всех» (28.09.2026, проверка на чистой Windows): человеку без опыта оно
; непонятно, ставим всегда «для меня» — права администратора не нужны.
DisableDirPage=yes
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
Name: "autostart"; Description: "Запускать SoundFlow при входе в Windows (нужно, чтобы телефон всегда находил музыку)"; GroupDescription: "Запуск:"
Name: "qbittorrent"; Description: "Установить qBittorrent (скачивание альбомов с торрентов)"; GroupDescription: "Торренты:"; Check: NeedsQbt

[Files]
Source: "dist\app\{#AppExe}";        DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\onnxruntime.dll";  DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\cnn14.onnx";       DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\cnn14.onnx.data";  DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\ffmpeg.exe";       DestDir: "{app}"; Flags: ignoreversion
Source: "dist\app\README.txt";       DestDir: "{app}"; Flags: ignoreversion
; качалка целиком: исходники + переносной Python с библиотеками
Source: "dist\app\downloader\*";    DestDir: "{app}\downloader"; Flags: ignoreversion recursesubdirs createallsubdirs
; soundflow.db в установщик не входит — приходит из soundflow-import и живёт
; в %LocalAppData%\SoundFlow. Пустую базу приложение создаёт само при первом запуске.

; редисты кладём во временную папку, ставим из [Run], потом удаляем
Source: "dist\redist\vc_redist.x64.exe";              DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist
Source: "dist\redist\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist
Source: "dist\redist\qbittorrent_setup.exe";         DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist; Tasks: qbittorrent

[InstallDelete]
; старая копия качалки (кроме её журнала) заменяется целиком — без хвостов прошлых версий
Type: filesandordirs; Name: "{app}\downloader\src"
Type: filesandordirs; Name: "{app}\downloader\python"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "SoundFlow"; \
  ValueData: """{app}\{#AppExe}"""; Flags: uninsdeletevalue; Tasks: autostart

[Icons]
Name: "{group}\{#AppName}";            Filename: "{app}\{#AppExe}"
Name: "{group}\Удалить {#AppName}";    Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";      Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Установка компонентов Visual C++…"; Check: NeedsVCRedist; Flags: waituntilterminated skipifdoesntexist
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; \
  StatusMsg: "Установка WebView2…"; Check: NeedsWebView2; Flags: waituntilterminated skipifdoesntexist
; qBittorrent ставится в Program Files — Windows спросит разрешение (shellexec)
Filename: "{tmp}\qbittorrent_setup.exe"; Parameters: "/S"; StatusMsg: "Установка qBittorrent…"; \
  Tasks: qbittorrent; Flags: waituntilterminated skipifdoesntexist shellexec
Filename: "{app}\{#AppExe}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent
; обновление из программы идёт тихо (/SILENT, pcupdate.go) — после него программа запускается снова сама
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent

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

function NeedsQbt: Boolean;
begin
  Result := not FileExists(ExpandConstant('{commonpf64}\qBittorrent\qbittorrent.exe'));
end;

// Настройки qBittorrent для качалки: Web UI только для этого компьютера. Логин и пароль Web UI
// задаёт мастер первого запуска SoundFlow (и кладёт их в settings.json). Пишутся, только если
// своих настроек qBittorrent ещё нет — чужие не трогаем.
procedure WriteQbtConfig;
var ini: String;
begin
  ini := ExpandConstant('{userappdata}\qBittorrent\qBittorrent.ini');
  if FileExists(ini) then exit;
  ForceDirectories(ExtractFileDir(ini));
  SaveStringToFile(ini,
    '[LegalNotice]' + #13#10 + 'Accepted=true' + #13#10 + #13#10 +
    '[Preferences]' + #13#10 +
    'WebUI\Enabled=true' + #13#10 +
    'WebUI\Address=127.0.0.1' + #13#10 +
    'WebUI\Port=8080' + #13#10, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('qbittorrent') then
    WriteQbtConfig;
end;
