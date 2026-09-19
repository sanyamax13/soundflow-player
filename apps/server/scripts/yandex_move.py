"""Перенос песен из Яндекса (source='yandex') в G:\\Музыка\\Яндекс\\<исполнитель>\\ (Alex TG 20060, 19.09.2026).

  python yandex_move.py --dry               только показать, что и куда переедет (ничего не меняет)
  python yandex_move.py --apply             сделать (программа SoundFlow должна быть закрыта)
  python yandex_move.py --undo <map.tsv>    вернуть всё обратно по файлу-карте, который пишет --apply

Порядок --apply: копия базы (VACUUM INTO) -> целые папки исполнителей переименовываются одним rename каждая
(тот же диск, мгновенно) -> ОДНА транзакция в базе, где меняется track_files.file_path -> проверка.
Любая ошибка до коммита — папки возвращаются на место, база не тронута.
"""
import os, sys, sqlite3, time, subprocess, shutil, collections

BS = chr(92)
DB = os.environ.get('YM_DB', 'E:' + BS + 'soundflow-data' + BS + 'soundflow.db')
BACKUP_DIR = os.environ.get('YM_BACKUP', 'E:' + BS + 'soundflow-data' + BS + '_backup')
ROOT = os.environ.get('YM_ROOT', 'G:' + BS + 'Музыка')            # так путь записан в базе (на диске папка называется «музыка» — Windows без разницы)
DEST = ROOT + BS + 'Яндекс'
EXE = os.environ.get('YM_EXE', 'C:' + BS + 'Users' + BS + 'brain' + BS + 'Desktop' + BS + 'SoundFlow' + BS + 'SoundFlow.exe')


def program_running():
    out = subprocess.run(['powershell', '-NoProfile', '-Command',
        "(Get-Process | Where-Object { $_.Path -eq '" + EXE + "' } | Measure-Object).Count"],
        capture_output=True, text=True).stdout.strip()
    return out not in ('', '0')


def plan(db):
    rows = db.execute("select id, file_path from track_files where rejected=0 and source='yandex' order by file_path").fetchall()
    folders = collections.OrderedDict()   # исполнитель -> список (id, старый путь, новый путь)
    for fid, p in rows:
        if not p.lower().startswith((ROOT + BS).lower()):
            raise SystemExit('файл вне ' + ROOT + ': ' + p)
        rest = p[len(ROOT) + 1:]
        art = rest.split(BS)[0]
        if BS not in rest:
            raise SystemExit('файл лежит прямо в корне, без папки исполнителя: ' + p)
        folders.setdefault(art, []).append((fid, p, DEST + BS + rest))
    return rows, folders


def check(folders):
    problems = []
    low = collections.Counter(a.lower() for a in folders)
    for a, n in low.items():
        if n > 1: problems.append('две папки различаются только регистром: ' + a)
    if os.path.exists(DEST): problems.append('папка уже существует: ' + DEST)
    for art, items in folders.items():
        src = ROOT + BS + art
        if not os.path.isdir(src): problems.append('нет папки ' + src); continue
        inbd = {p.lower() for _, p, _ in items}
        ondisk = set()
        for r, ds, fs in os.walk(src):
            for d in ds: problems.append('вложенная папка внутри ' + src + ': ' + d)
            for f in fs: ondisk.add(os.path.join(r, f).lower())
        for x in sorted(ondisk - inbd): problems.append('на диске есть файл, которого нет в базе: ' + x)
        for x in sorted(inbd - ondisk): problems.append('в базе есть файл, которого нет на диске: ' + x)
    return problems


def dry():
    db = sqlite3.connect('file:' + DB + '?mode=ro', uri=True)
    rows, folders = plan(db)
    problems = check(folders)
    print('песен из Яндекса:', len(rows), '| папок исполнителей:', len(folders))
    for art, items in folders.items():
        print('  %-52s %2d  ->  %s' % (art, len(items), DEST + BS + art))
    print('ПРОБЛЕМЫ:' if problems else 'проблем нет')
    for p in problems: print('  !', p)
    print('программа SoundFlow запущена:', program_running())
    return 1 if problems else 0


def apply():
    if program_running():
        raise SystemExit('SoundFlow запущен — сперва закрыть')
    db = sqlite3.connect(DB, timeout=30)
    db.execute('pragma busy_timeout=30000')
    rows, folders = plan(db)
    problems = check(folders)
    if problems:
        raise SystemExit('остановился, проблемы: ' + '; '.join(problems))
    ts = time.strftime('%Y%m%d-%H%M%S')
    os.makedirs(BACKUP_DIR, exist_ok=True)
    bak = BACKUP_DIR + BS + 'soundflow-' + ts + '-before-yandex-move.db'
    db.execute('VACUUM INTO ?', (bak,))
    chk = sqlite3.connect('file:' + bak + '?mode=ro', uri=True)
    assert chk.execute('pragma integrity_check').fetchone()[0] == 'ok', 'копия базы битая'
    assert chk.execute("select count(*) from track_files where source='yandex' and rejected=0").fetchone()[0] == len(rows)
    chk.close()
    print('копия базы:', bak, os.path.getsize(bak), 'байт, integrity ok')
    mapf = BACKUP_DIR + BS + 'yandex-move-' + ts + '.tsv'
    done = []
    try:
        os.makedirs(DEST)
        for art in folders:
            src, dst = ROOT + BS + art, DEST + BS + art
            os.rename(src, dst)
            done.append((src, dst))
        with open(mapf, 'w', encoding='utf-8', newline='') as f:
            for art, items in folders.items():
                f.write('DIR\t' + ROOT + BS + art + '\t' + DEST + BS + art + '\n')
                for fid, old, new in items: f.write('FILE\t' + fid + '\t' + old + '\t' + new + '\n')
        db.execute('begin immediate')
        n = 0
        for items in folders.values():
            for fid, old, new in items:
                cur = db.execute('update track_files set file_path=? where id=? and file_path=?', (new, fid, old))
                n += cur.rowcount
        if n != len(rows): raise RuntimeError('обновилось %d строк вместо %d' % (n, len(rows)))
        db.commit()
    except BaseException as e:
        try: db.rollback()
        except Exception: pass
        for src, dst in reversed(done):
            try: os.rename(dst, src)
            except Exception as e2: print('НЕ СМОГ вернуть', dst, '->', src, e2)
        try: os.rmdir(DEST)
        except Exception: pass
        raise SystemExit('ОТКАТ, ничего не изменено: ' + repr(e))
    # проверка
    bad = [new for items in folders.values() for _, _, new in items if not os.path.isfile(new)]
    left = [a for a in folders if os.path.exists(ROOT + BS + a)]
    cnt = db.execute("select count(*) from track_files where source='yandex' and rejected=0 and file_path like ?", (DEST + BS + '%',)).fetchone()[0]
    print('перенесено папок:', len(done), '| строк в базе:', cnt, '| нет файла по новому пути:', len(bad), '| старые папки остались:', len(left))
    print('карта для отката:', mapf)
    return 0 if not bad and not left and cnt == len(rows) else 2


def undo(mapf):
    if program_running():
        raise SystemExit('SoundFlow запущен — сперва закрыть')
    db = sqlite3.connect(DB, timeout=30)
    files, dirs = [], []
    for line in open(mapf, encoding='utf-8'):
        k, *a = line.rstrip('\n').split('\t')
        (files if k == 'FILE' else dirs).append(a)
    for old, new in dirs:
        os.rename(new, old)
    db.execute('begin immediate')
    for fid, old, new in files:
        db.execute('update track_files set file_path=? where id=? and file_path=?', (old, fid, new))
    db.commit()
    try: os.rmdir(DEST)
    except OSError: print('папку Яндекс оставил (не пустая)')
    print('откат готов: папок', len(dirs), ', строк', len(files))
    return 0


if __name__ == '__main__':
    m = sys.argv[1] if len(sys.argv) > 1 else ''
    sys.exit(dry() if m == '--dry' else apply() if m == '--apply' else undo(sys.argv[2]) if m == '--undo' else print(__doc__) or 1)
