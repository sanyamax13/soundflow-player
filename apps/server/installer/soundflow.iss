; SoundFlow — установщик для Windows (Inno Setup).
;
; Собирает чистую переносимую установку: программа сама создаёт свою базу в
; %LocalAppData%\SoundFlow при первом запуске (см. dataDir() в
; cmd/soundflow/service.go) — установщик НЕ несёт ни базы, ни музыки, ни
; настроек конкретного человека. Каталог пуст → окно само предлагает
; «Выбрать папку с музыкой» (frontend/index.html, emptyPick) — это и есть
; мастер первого запуска, отдельно ничего писать не пришлось (Alex TG
; 24.09.2026).
;
; Не ставит: качалку Яндекса/торрентов (SOUNDFLOW_DOWNLOADER не задан —
; функция сама тихо выключается, findDownloaderDir() ничего не находит) —
; по решению Alex 24.09.2026: на другом ПК музыку кладёт сам человек,
; Яндекс-аккаунт и куки — это отдельная, личная история, тут не нужна.
;
; Установка без прав администратора (LocalAppData\Programs) — Alex мог
; ставить куда угодно, без UAC.
;
; Сборка:
;   1) go build -tags "desktop,production" -ldflags "-H windowsgui -s -w" \
;        -o installer\build\SoundFlow.exe .\cmd\soundflow   (из apps\server)
;   2) Рядом с installer\build\SoundFlow.exe положить (копия с живого ПК,
;      C:\Users\<...>\Desktop\SoundFlow\): ffmpeg.exe, onnxruntime.dll,
;      libwinpthread-1.dll, cnn14.onnx, cnn14.onnx.data
;   3) "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\soundflow.iss

#define MyAppName "SoundFlow"
#define MyAppVersion "1.0"
#define MyAppPublisher "SoundFlow"
#define MyAppExeName "SoundFlow.exe"
#define BuildDir "build"

[Setup]
AppId={{6F2B7B7D-5C0B-4F5E-9B7B-2E6E9C9B6F31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=SoundFlow-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; GroupDescription: "Дополнительно:"

[Files]
Source: "{#BuildDir}\SoundFlow.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\onnxruntime.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\libwinpthread-1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\cnn14.onnx"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\cnn14.onnx.data"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Удалить {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить {#MyAppName}"; Flags: nowait postinstall skipifsilent
