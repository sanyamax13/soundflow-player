"""Убрать дубли, созданные сканом v17 (20.09.2026 16:50): вторая запись на тот же файл.

  python cleanup_dups.py <путь к soundflow.db> [--apply] [--covers <папка found_covers>]

Без --apply только показывает, что было бы сделано (dry-run). Трогает ТОЛЬКО базу (и картинки-обложки
этих записей в found_covers); музыкальные файлы не трогает. Дубль = запись source='scan', у которой файл
(без учёта регистра и слэшей) уже записан у ДРУГОЙ записи (её оставляем). Запускать при закрытой программе.
"""
import collections
import json
import os
import sqlite3
import sys

db = sys.argv[1]
apply_ = '--apply' in sys.argv
covers = sys.argv[sys.argv.index('--covers') + 1] if '--covers' in sys.argv else ''

c = sqlite3.connect(db)
c.execute('PRAGMA foreign_keys=ON')

by_path = collections.defaultdict(list)
for tid, fid, path, src, created in c.execute(
        "SELECT tf.track_id, tf.id, tf.file_path, tf.source, t.created_at "
        "FROM track_files tf JOIN tracks t ON t.id = tf.track_id"):
    by_path[path.replace('/', '\\').casefold()].append((tid, fid, path, src, created))

dups = []  # (дубль, оставляемая)
for key, rows in by_path.items():
    if len(rows) < 2:
        continue
    keepers = [r for r in rows if r[3] != 'scan']
    scans = [r for r in rows if r[3] == 'scan']
    if not keepers or not scans:
        print('ПРОПУСК (нет пары «скачанная + скан»):', [r[0] for r in rows], key[-60:])
        continue
    for s in scans:
        dups.append((s, keepers[0]))

print('найдено дублей:', len(dups))
for s, k in dups:
    a = c.execute('SELECT artist, title, cover_url FROM tracks WHERE id=?', (s[0],)).fetchone()
    b = c.execute('SELECT artist, title FROM tracks WHERE id=?', (k[0],)).fetchone()
    print('  дубль  %s  «%s — %s»  (создан %s, метка обложки %s)' % (s[0], a[0], a[1], s[4], a[2]))
    print('  оставим %s  «%s — %s»  файл: %s' % (k[0], b[0], b[1], k[2]))

if not dups:
    sys.exit(0)

ids = [s[0] for s, _ in dups]
ph = ','.join('?' * len(ids))
plan_hits = []
for dev, add, rem in c.execute('SELECT device_id, add_ids, remove_ids FROM sync_plans'):
    if any(i in json.loads(add or '[]') or i in json.loads(rem or '[]') for i in ids):
        plan_hits.append(dev)
print('в планах телефона встречаются:', plan_hits or 'нет')
for tbl, col in (('feedback_event', 'track_id'), ('sync_events', 'track_id')):
    n = c.execute('SELECT COUNT(*) FROM %s WHERE %s IN (%s)' % (tbl, col, ph), ids).fetchone()[0]
    print('  записей в %s про эти песни: %d' % (tbl, n))

if not apply_:
    print('\nDRY-RUN: ничего не изменено. Для применения добавь --apply')
    sys.exit(0)

before = c.execute('SELECT COUNT(*) FROM tracks').fetchone()[0]
with c:
    c.execute('DELETE FROM tracks WHERE id IN (%s)' % ph, ids)  # track_files уходят каскадом
    for dev, add, rem in c.execute('SELECT device_id, add_ids, remove_ids FROM sync_plans').fetchall():
        a2 = [x for x in json.loads(add or '[]') if x not in ids]
        r2 = [x for x in json.loads(rem or '[]') if x not in ids]
        c.execute('UPDATE sync_plans SET add_ids=?, remove_ids=? WHERE device_id=?',
                  (json.dumps(a2), json.dumps(r2), dev))
after = c.execute('SELECT COUNT(*) FROM tracks').fetchone()[0]
left = c.execute('SELECT COUNT(*) FROM track_files WHERE track_id IN (%s)' % ph, ids).fetchone()[0]
print('песен было %d, стало %d; записей файлов у убранных: %d' % (before, after, left))
if covers:
    for i in ids:
        p = os.path.join(covers, i + '.jpg')
        if os.path.exists(p):
            os.remove(p)
            print('убрана обложка-сирота', p)
print('ГОТОВО')
