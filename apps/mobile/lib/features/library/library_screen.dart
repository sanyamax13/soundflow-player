import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';

/// На каркасе Библиотека = проверка связи: тянет список тестовых треков
/// с сервера и умеет скачать один файл в папку приложения.
/// Настоящая библиотека (Скачано/Любимое/Альбомы/…) — своим шагом.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Map<String, dynamic>>? _tracks;
  String? _error;
  String? _status;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _tracks = null;
    });
    try {
      final t = await AppScope.of(context).api.tracks();
      if (mounted) setState(() => _tracks = t);
    } catch (_) {
      if (mounted) setState(() => _error = 'Сервер не ответил. Запущен ли он?');
    }
  }

  Future<void> _download(String id) async {
    final api = AppScope.of(context).api;
    setState(() => _status = 'Скачиваю $id…');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/$id';
      await api.downloadTrack(id, path);
      final size = await File(path).length();
      if (mounted) {
        setState(() => _status = 'Скачано $id — ${(size / 1024).toStringAsFixed(1)} КБ');
      }
    } catch (_) {
      if (mounted) setState(() => _status = 'Не скачалось $id');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Библиотека'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _center(_error!, action: TextButton(onPressed: _load, child: const Text('Ещё раз')));
    }
    if (_tracks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: _tracks!.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: Afisha.line),
            itemBuilder: (_, i) {
              final t = _tracks![i];
              return ListTile(
                title: Text('${t['title']}'),
                subtitle: Text('${t['artist']}'),
                trailing: TextButton(
                  onPressed: () => _download('${t['id']}'),
                  child: const Text('Скачать'),
                ),
              );
            },
          ),
        ),
        if (_status != null)
          Container(
            width: double.infinity,
            color: Afisha.surface,
            padding: const EdgeInsets.all(14),
            child: Text(_status!, style: const TextStyle(color: Afisha.inkDim)),
          ),
      ],
    );
  }

  Widget _center(String text, {Widget? action}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: const TextStyle(color: Afisha.inkDim)),
            ?action,
          ],
        ),
      );
}
