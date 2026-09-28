import 'package:flutter/widgets.dart' show IconData;
import 'package:solar_icons/solar_icons.dart';

/// Названия жанров Яндекса по-русски (сервер хранит код Яндекса: rusrap, pop…,
/// cmd/soundflow/genrekeeper.go, 26.09.2026). Неизвестный код показываем как есть,
/// с большой буквы.
const _genreRu = <String, String>{
  'pop': 'Поп',
  'ruspop': 'Русская поп-музыка',
  'rusrap': 'Русский рэп',
  'rap': 'Рэп и хип-хоп',
  'foreignrap': 'Зарубежный рэп',
  'rock': 'Рок',
  'rusrock': 'Русский рок',
  'alternative': 'Альтернатива',
  'indie': 'Инди',
  'metal': 'Метал',
  'punk': 'Панк',
  'electronics': 'Электроника',
  'dance': 'Танцевальная',
  'house': 'Хаус',
  'techno': 'Техно',
  'trance': 'Транс',
  'dnb': 'Драм-н-бейс',
  'dubstep': 'Дабстеп',
  'disco': 'Диско',
  'rnb': 'R&B',
  'soul': 'Соул',
  'jazz': 'Джаз',
  'blues': 'Блюз',
  'classical': 'Классика',
  'soundtrack': 'Саундтреки',
  'films': 'Музыка из фильмов',
  'folk': 'Фолк',
  'country': 'Кантри',
  'reggae': 'Регги',
  'estrada': 'Эстрада',
  'shanson': 'Шансон',
  'bard': 'Авторская песня',
  'lounge': 'Лаунж',
  'ambient': 'Эмбиент',
  'relax': 'Для отдыха',
  'kpop': 'K-pop',
  'latin': 'Латино',
  'children': 'Детская',
  'local-indie': 'Русское инди',
  'posthardcore': 'Пост-хардкор',
  'hardrock': 'Хард-рок',
  'newage': 'Нью-эйдж',
  'videogame': 'Музыка из игр',
  'phonk': 'Фонк',
};

String genreLabel(String code) {
  final ru = _genreRu[code];
  if (ru != null) return ru;
  if (code.isEmpty) return code;
  return code[0].toUpperCase() + code.substring(1);
}

/// 12 больших групп вместо ~96 кодов Яндекса (12-я — «Альтернатива и инди», Alex 27.09.2026 «для симметрии») (27.09.2026, Alex: «жанров очень много, можно объединить»).
/// Тот же список, что на сервере (apps/server/cmd/soundflow/moodkeeper.go genreGroups) — сервер по нему
/// угадывает жанр песен, которых Яндекс не знает.
const genreGroupOrder = <(String, String, IconData)>[
  ('pop', 'Поп', SolarIconsBold.microphoneLarge),
  ('dance', 'Танцевальная и электроника', SolarIconsBold.headphonesRound),
  ('rock', 'Рок', SolarIconsBold.speaker),
  ('alt', 'Альтернатива и инди', SolarIconsBold.turntableMusicNote),
  ('rap', 'Рэп', SolarIconsBold.microphone),
  ('estrada', 'Эстрада и шансон', SolarIconsBold.musicNotes),
  ('calm', 'Спокойное и лаунж', SolarIconsBold.moonSleep),
  ('folk', 'Фолк, кантри, этника', SolarIconsBold.leaf),
  ('rnb', 'R&B, соул, регги', SolarIconsBold.musicNote3),
  ('metal', 'Метал', SolarIconsBold.flame),
  ('soundtrack', 'Саундтреки', SolarIconsBold.clapperboardPlay),
  ('jazz', 'Джаз и блюз', SolarIconsBold.cupMusic),
];

final Map<String, String> _groupOf = () {
  final m = <String, String>{};
  void add(String g, List<String> codes) {
    for (final c in codes) {
      m[c] = g;
    }
  }

  add('pop', ['pop', 'ruspop', 'kpop', 'turkishpop', 'disco', 'vocal', 'hyperpopgenre', 'levantpop', 'qazaqpop', 'arabicpop']);
  add('estrada', ['rusestrada', 'estrada', 'shanson', 'bard', 'foreignbard', 'kazestrada']);
  add('dance', ['dance', 'electronics', 'house', 'techno', 'trance', 'edmgenre', 'dnb', 'dubstep', 'breakbeatgenre', 'idmgenre', 'ukgaragegenre', 'experimental']);
  add('rap', ['rap', 'rusrap', 'foreignrap', 'phonkgenre']);
  add('rock', ['rock', 'rusrock', 'hardrock', 'punk', 'allrock', 'prog', 'folkrock', 'ukrrock', 'rnr', 'ska']);
  add('alt', ['alternative', 'indie', 'local-indie', 'postpunk', 'newwave', 'modern']);
  add('metal', ['numetal', 'classicmetal', 'metal', 'alternativemetal', 'metalcoregenre', 'thrashmetal', 'industrial', 'posthardcore', 'epicmetal', 'progmetal', 'hardcore']);
  add('rnb', ['rnb', 'soul', 'funk', 'reggae', 'reggaeton', 'dub']);
  add('calm', ['lounge', 'relax', 'ambientgenre', 'newage', 'triphopgenre', 'lullaby', 'classical', 'meditation']);
  add('jazz', ['jazz', 'vocaljazz', 'conjazz', 'bestofjazz', 'tradjazz', 'blues', 'smoothjazz', 'bebopgenre']);
  add('folk', ['folk', 'country', 'amerfolk', 'folkgenre', 'latinfolk', 'african', 'caucasian']);
  add('soundtrack', ['soundtrack', 'films', 'videogame', 'animated', 'children', 'sport', 'musical']);
  return m;
}();

/// Группа жанра по коду Яндекса; null — неизвестный код или жанра нет.
String? genreGroup(String? code) => code == null ? null : _groupOf[code];

/// Настроения по звуку (сервер, moodkeeper.go): код → подпись и значок (Solar, 28.09.2026 — вместо эмодзи).
const moodOrder = <(String, String, IconData)>[
  ('happy', 'Радостное', SolarIconsBold.smileCircle),
  ('energetic', 'Энергичное', SolarIconsBold.bolt),
  ('tender', 'Нежное', SolarIconsBold.handHeart),
  ('sad', 'Грустное', SolarIconsBold.cloudRain),
  ('aggressive', 'Жёсткое', SolarIconsBold.fire),
  ('dance', 'Танцевальное', SolarIconsBold.confetti), // 6-е, Alex 27.09.2026 «для симметрии» — класс AudioSet «Dance music»
];

/// Цвет полоски под плиткой настроения (разбор Алисы 27.09.2026). «Энергичное» оранжевое, а не
/// лаймовое: лайм в плеере значит «включено».
const moodColors = <String, int>{
  'happy': 0xFFFFD60A,
  'energetic': 0xFFFF9F0A,
  'tender': 0xFFFF6B9D,
  'sad': 0xFF5E9EFF,
  'aggressive': 0xFFFF3B30,
  'dance': 0xFFBF5AF2,
};
