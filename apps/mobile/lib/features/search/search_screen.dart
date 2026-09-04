import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';
import '../../data/api.dart';

/// «Найти музыку». Сверху — заказать новое: исполнитель + название, сервер
/// скачает песню на домашний компьютер и положит в каталог, телефон сразу
/// тянет файл себе. Снизу — поиск по тому, что на сервере уже есть
/// (тап по строке — скачать на телефон).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  final _artist = TextEditingController();
  final _title = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>>? _found;
  final Set<String> _downloading = {};
  final Set<String> _onPhone = {};

  bool _acquiring = false;
  String? _acquireError;
  String? _acquireOk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _artist.dispose();
    _title.dispose();
    super.dispose();
  }

  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v));
  }

  Future<void> _search(String v) async {
    try {
      final list = await AppScope.of(context).downloads.searchCatalog(v.trim());
      if (!mounted) return;
      setState(() => _found = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _found = const []);
    }
  }

  Future<void> _downloadToPhone(Map<String, dynamic> t) async {
    final id = '${t['id']}';
    setState(() => _downloading.add(id));
    try {
      await AppScope.of(context).downloads.download(t);
      if (!mounted) return;
      setState(() {
        _downloading.remove(id);
        _onPhone.add(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _downloading.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось скачать на телефон')),
      );
    }
  }

  Future<void> _acquire() async {
    final artist = _artist.text.trim();
    final title = _title.text.trim();
    if (artist.isEmpty || title.isEmpty) {
      setState(() => _acquireError = 'Заполни исполнителя и название');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _acquiring = true;
      _acquireError = null;
      _acquireOk = null;
    });
    final downloads = AppScope.of(context).downloads;
    try {
      final res = await downloads.acquireOnServer(artist: artist, title: title);
      final trackId = '${res['track_id'] ?? ''}';
      if (trackId.isEmpty) throw AcquireException('Сервер вернул пустой ответ');

      var note = res['created'] == true ? 'Добавлено на сервер' : 'Уже было на сервере';
      try {
        await downloads.download({
          'id': trackId,
          'artist': artist,
          'title': title,
          'favorite': res['favorite'] == true,
        });
        note = '$note, скачано на телефон';
        if (res['favorite'] == true) note = '$note, в избранном';
      } catch (_) {
        note = '$note. На телефон не скачалось — попробуй позже';
      }
      if (!mounted) return;
      setState(() {
        _acquiring = false;
        _acquireOk = note;
        _artist.clear();
        _title.clear();
      });
      await _search(_q.text);
    } on AcquireException catch (e) {
      if (!mounted) return;
      setState(() {
        _acquiring = false;
        _acquireError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _acquiring = false;
        _acquireError = 'Не получилось: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: const Text('Найти музыку')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text('ЗАКАЗАТЬ НОВОЕ', style: _label),
          const SizedBox(height: 10),
          TextField(
            controller: _artist,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Исполнитель',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _acquire(),
            decoration: const InputDecoration(
              labelText: 'Название песни',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _acquiring ? null : _acquire,
              child: _acquiring
                  ? const _Busy(text: 'Ищу и качаю… это до минуты')
                  : const Text('Найти и скачать'),
            ),
          ),
          if (_acquireError != null) ...[
            const SizedBox(height: 12),
            _Note(text: _acquireError!, color: Afisha.inkDim, icon: Icons.error_outline),
          ],
          if (_acquireOk != null) ...[
            const SizedBox(height: 12),
            _Note(text: _acquireOk!, color: Afisha.lime, icon: Icons.check_circle_outline),
          ],
          const SizedBox(height: 28),
          const Divider(height: 1, color: Afisha.line),
          const SizedBox(height: 16),
          const Text('УЖЕ НА СЕРВЕРЕ', style: _label),
          const SizedBox(height: 10),
          TextField(
            controller: _q,
            onChanged: _onQueryChanged,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск по каталогу',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (found == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (found.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  _q.text.trim().isEmpty ? 'В каталоге пока пусто' : 'Ничего не найдено',
                  style: const TextStyle(color: Afisha.inkDim),
                ),
              ),
            )
          else
            for (final t in found) _row(t),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> t) {
    final id = '${t['id']}';
    final busy = _downloading.contains(id);
    final onPhone = _onPhone.contains(id);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${t['title']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${t['artist']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: onPhone
          ? const Icon(Icons.check, color: Afisha.lime)
          : busy
              ? const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.download, color: Afisha.lime),
                  onPressed: () => _downloadToPhone(t),
                ),
    );
  }

  static const _label = TextStyle(
    color: Afisha.lime,
    fontSize: 12,
    letterSpacing: 1.5,
    fontWeight: FontWeight.w600,
  );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
          ),
          const SizedBox(width: 10),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
        ],
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, required this.icon});
  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Afisha.surfaceHi,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: color))),
          ],
        ),
      );
}
