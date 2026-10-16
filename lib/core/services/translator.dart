import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'app_settings.dart';

/// One translation.
class Translation {
  const Translation({required this.text, required this.from, required this.to});
  final String text;

  /// Language it was written in ('' = not known).
  final String from;
  final String to;

  /// Already in your language (nothing to translate).
  bool get same => from.isNotEmpty && from == to;
}

/// v0.19 Hyper Intelligence: "See translation" for captions, comments and
/// bios. Translates into your app language (Settings -> Language).
/// Our server asks Google (free, no key); if the server can't (or takes
/// longer than 12 s), the phone asks Google directly.
///
/// v0.20: only the words go to Google - emojis, #tags, @names, links and
/// line breaks stay exactly as written; better "is this another
/// language?" check (Hinglish, Spanish, ... in English letters).
class Translator {
  Translator._();
  static final Translator instance = Translator._();

  /// Your language code ('en', 'hi', ...).
  String get target {
    final l = AppSettings.instance.language.value;
    return l.isEmpty ? 'en' : l;
  }

  final Map<String, Translation> _cache = {};

  /// Tests replace the server / phone calls.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  debugPost;
  @visibleForTesting
  static Future<Translation> Function(String text, String to)? debugDirect;

  /// Tests replace Google itself (phone path): url, headers, body.
  @visibleForTesting
  static Future<String> Function(
    String url,
    Map<String, String> headers,
    String body,
  )?
  debugHttp;

  @visibleForTesting
  void clearCache() => _cache.clear();

  static const Duration serverWait = Duration(seconds: 12);

  Future<Translation> translate(String text, {String? to}) async {
    final lang = to ?? target;
    final t = text.trim();
    final key = '$lang|$t';
    final hit = _cache[key];
    if (hit != null) return hit;
    Translation out;
    try {
      final r =
          await (debugPost ?? (b) => ApiClient.instance.post('/api/hi', b))({
            'action': 'translate',
            'text': t,
            'to': lang,
          }).timeout(serverWait);
      out = Translation(
        text: (r['text'] as String?) ?? '',
        from: (r['from'] as String?) ?? '',
        to: lang,
      );
      if (out.text.trim().isEmpty) throw const FormatException('empty');
    } catch (e) {
      // 400 = bad text / language: the phone won't do better
      if (e is ApiException && e.statusCode == 400) rethrow;
      out = await (debugDirect ?? direct)(t, lang);
    }
    // Google gave the same text back = nothing to translate
    if (out.from.isEmpty && out.text.trim() == t) {
      out = Translation(text: out.text, from: lang, to: lang);
    }
    if (_cache.length > 300) _cache.remove(_cache.keys.first);
    _cache[key] = out;
    return out;
  }

  static const _toGoogle = {'fil': 'tl', 'zh': 'zh-CN', 'he': 'iw'};
  static const _fromGoogle = {
    'tl': 'fil',
    'zh-cn': 'zh',
    'zh-tw': 'zh',
    'iw': 'he',
    'jw': 'jv',
  };

  static String _fromCode(String c) {
    final l = c.toLowerCase();
    return _fromGoogle[l] ?? l.split('-').first;
  }

  // ------------------------------------------------- parts (same as server)

  // Emojis, flags, skin tones, ♥ ✔ ★ ... as real characters (made by
  // Dart, not regex escapes: older analyzers reject some regex escapes).
  static const String _emoji =
      '\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2300}-\u{23FF}'
      '\u{2B00}-\u{2BFF}\u{2190}-\u{21FF}\u{25A0}-\u{25FF}'
      '\u{2900}-\u{297F}\u{3030}\u{303D}\u{3297}\u{3299}'
      '\u{00A9}\u{00AE}\u{203C}\u{2049}\u{2122}\u{2139}'
      '\u{200D}\u{FE0F}\u{20E3}\u{E0020}-\u{E007F}';
  static final RegExp _keep = RegExp(
    r'(https?://\S+|www\.\S+|[@#][\p{L}\p{M}\p{N}_.]+|(?:[' +
        _emoji +
        r'])+|\n+)',
    unicode: true,
  );
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _edges = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');

  /// Text -> parts: kept as is (`keep`) or sent to Google (`core`, with
  /// the spaces around it in `lead` / `trail`).
  @visibleForTesting
  static List<({String? keep, String lead, String core, String trail})>
  splitText(String text) {
    final out = <({String? keep, String lead, String core, String trail})>[];
    void add(String piece) {
      if (piece.isEmpty) return;
      final m = _edges.firstMatch(piece)!;
      if (!_letter.hasMatch(m[2]!)) {
        out.add((keep: piece, lead: '', core: '', trail: ''));
      } else {
        out.add((keep: null, lead: m[1]!, core: m[2]!, trail: m[3]!));
      }
    }

    var at = 0;
    for (final m in _keep.allMatches(text)) {
      add(text.substring(at, m.start));
      out.add((keep: m[0]!, lead: '', core: '', trail: ''));
      at = m.end;
    }
    add(text.substring(at));
    return out;
  }

  @visibleForTesting
  static String joinText(
    List<({String? keep, String lead, String core, String trail})> parts,
    List<String> cores,
  ) {
    var i = 0;
    final b = StringBuffer();
    for (final p in parts) {
      if (p.keep != null) {
        b.write(p.keep);
      } else {
        final t = i < cores.length ? cores[i] : p.core;
        i++;
        b
          ..write(p.lead)
          ..write(keepCapital(p.core, t))
          ..write(p.trail);
      }
    }
    return b.toString();
  }

  /// "Bahut ..." -> "This ..." (Google sometimes starts small).
  static String keepCapital(String orig, String out) {
    if (orig.isEmpty || out.isEmpty) return out;
    final a = orig[0], b = out[0];
    if (a != a.toLowerCase() &&
        b == b.toLowerCase() &&
        b != b.toUpperCase()) {
      return b.toUpperCase() + out.substring(1);
    }
    return out;
  }

  static String _mainFrom(List<String> cores, List<String> froms) {
    final w = <String, int>{};
    for (var i = 0; i < cores.length && i < froms.length; i++) {
      if (froms[i].isEmpty) continue;
      w[froms[i]] = (w[froms[i]] ?? 0) + cores[i].length;
    }
    if (w.isEmpty) return '';
    return (w.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  static Future<String> _send(
    String url,
    Map<String, String> headers,
    String body,
  ) async {
    final h = debugHttp;
    if (h != null) return h(url, headers, body);
    final r = await http
        .post(Uri.parse(url), headers: headers, body: body)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return utf8.decode(r.bodyBytes);
  }

  static const _paKey = 'AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520';

  /// Straight from the phone (the same free Google links as the server):
  /// clients5, then Google's website translator.
  static Future<Translation> direct(String text, String to) async {
    final gl = _toGoogle[to] ?? to;
    var parts = splitText(text);
    var cores = [
      for (final p in parts)
        if (p.keep == null) p.core,
    ];
    if (cores.isEmpty) return Translation(text: text, from: '', to: to);
    if (cores.length > 60) {
      parts = [(keep: null, lead: '', core: text, trail: '')];
      cores = [text];
    }
    Object? last;
    // 1) clients5 (one q per part)
    try {
      final body = cores
          .map((c) => 'q=${Uri.encodeQueryComponent(c)}')
          .join('&');
      final raw = await _send(
        'https://clients5.google.com/translate_a/t'
        '?client=dict-chrome-ex&sl=auto&tl=${Uri.encodeQueryComponent(gl)}',
        {'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'},
        body,
      );
      final list = parseClients5Many(raw, cores.length, to);
      return Translation(
        text: joinText(parts, [for (final t in list) t.text]),
        from: _mainFrom(cores, [for (final t in list) t.from]),
        to: to,
      );
    } catch (e) {
      last = e;
    }
    // 2) Google's website translator
    try {
      final raw = await _send(
        'https://translate-pa.googleapis.com/v1/translateHtml',
        {
          'Content-Type': 'application/json+protobuf',
          'X-Goog-API-Key': _paKey,
        },
        jsonEncode([
          [cores.map(_escapeHtml).toList(), 'auto', gl],
          'wt_lib',
        ]),
      );
      final list = parsePa(raw, cores.length, to);
      return Translation(
        text: joinText(parts, [for (final t in list) t.text]),
        from: _mainFrom(cores, [for (final t in list) t.from]),
        to: to,
      );
    } catch (e) {
      last = e;
    }
    throw Exception('Translation is not available ($last)');
  }

  static String _escapeHtml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static const _entities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };

  @visibleForTesting
  static String unescapeHtml(String s) => s.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'),
    (m) {
      final e = m[1]!;
      if (e.startsWith('#')) {
        final n = e[1] == 'x' || e[1] == 'X'
            ? int.tryParse(e.substring(2), radix: 16)
            : int.tryParse(e.substring(1));
        return n == null ? m[0]! : String.fromCharCode(n);
      }
      return _entities[e.toLowerCase()] ?? m[0]!;
    },
  );

  static Translation _entry(Object? e, String to) {
    if (e is String) return Translation(text: e, from: '', to: to);
    if (e is List && e.isNotEmpty && e.first is String) {
      return Translation(
        text: e.first as String,
        from: e.length > 1 ? _fromCode('${e[1]}') : '',
        to: to,
      );
    }
    throw const FormatException('Unknown answer');
  }

  /// `[["text","src"]]`, `["text"]` or `[["text"]]`.
  @visibleForTesting
  static Translation parseClients5(String body, String to) {
    final d = jsonDecode(body);
    return _entry(d is List && d.isNotEmpty ? d.first : null, to);
  }

  /// Many parts: `[["t1","hi"],["t2","hi"]]`.
  @visibleForTesting
  static List<Translation> parseClients5Many(String body, int n, String to) {
    if (n == 1) return [parseClients5(body, to)];
    final d = jsonDecode(body);
    if (d is! List || d.length != n) {
      throw const FormatException('Wrong answer size');
    }
    return [for (final e in d) _entry(e, to)];
  }

  /// translate-pa: `[["t1","t2"],["hi","hi"]]` (HTML escaped).
  @visibleForTesting
  static List<Translation> parsePa(String body, int n, String to) {
    final d = jsonDecode(body);
    if (d is! List || d.isEmpty || d.first is! List) {
      throw const FormatException('Unknown answer');
    }
    final texts = d.first as List;
    if (texts.length != n) throw const FormatException('Wrong answer size');
    final froms = d.length > 1 && d[1] is List ? d[1] as List : const [];
    return [
      for (var i = 0; i < n; i++)
        Translation(
          text: unescapeHtml('${texts[i]}'),
          from: i < froms.length ? _fromCode('${froms[i]}') : '',
          to: to,
        ),
    ];
  }

  // ------------------------------------------------- when to offer it

  static final Map<String, RegExp> _scripts = {
    'latin': RegExp(r'\p{Script=Latin}', unicode: true),
    'deva': RegExp(r'\p{Script=Devanagari}', unicode: true),
    'beng': RegExp(r'\p{Script=Bengali}', unicode: true),
    'telu': RegExp(r'\p{Script=Telugu}', unicode: true),
    'taml': RegExp(r'\p{Script=Tamil}', unicode: true),
    'gujr': RegExp(r'\p{Script=Gujarati}', unicode: true),
    'knda': RegExp(r'\p{Script=Kannada}', unicode: true),
    'mlym': RegExp(r'\p{Script=Malayalam}', unicode: true),
    'guru': RegExp(r'\p{Script=Gurmukhi}', unicode: true),
    'orya': RegExp(r'\p{Script=Oriya}', unicode: true),
    'sinh': RegExp(r'\p{Script=Sinhala}', unicode: true),
    'arab': RegExp(r'\p{Script=Arabic}', unicode: true),
    'hebr': RegExp(r'\p{Script=Hebrew}', unicode: true),
    'cyrl': RegExp(r'\p{Script=Cyrillic}', unicode: true),
    'grek': RegExp(r'\p{Script=Greek}', unicode: true),
    'hani': RegExp(r'\p{Script=Han}', unicode: true),
    'kana': RegExp(r'\p{Script=Hiragana}|\p{Script=Katakana}', unicode: true),
    'hang': RegExp(r'\p{Script=Hangul}', unicode: true),
    'thai': RegExp(r'\p{Script=Thai}', unicode: true),
  };

  /// Scripts each app language is written in.
  static const Map<String, Set<String>> _langScripts = {
    'hi': {'deva'},
    'mr': {'deva'},
    'ne': {'deva'},
    'bn': {'beng'},
    'as': {'beng'},
    'te': {'telu'},
    'ta': {'taml'},
    'gu': {'gujr'},
    'kn': {'knda'},
    'ml': {'mlym'},
    'pa': {'guru'},
    'or': {'orya'},
    'si': {'sinh'},
    'ur': {'arab'},
    'ar': {'arab'},
    'fa': {'arab'},
    'he': {'hebr'},
    'uk': {'cyrl'},
    'ru': {'cyrl'},
    'el': {'grek'},
    'zh': {'hani'},
    'ja': {'hani', 'kana'},
    'ko': {'hang'},
    'th': {'thai'},
  };

  static final RegExp _noise = RegExp(
    r'https?://\S+|www\.\S+|[@#][\p{L}\p{M}\p{N}_.]+',
    unicode: true,
  );
  static final RegExp _words = RegExp(r"[\p{L}\p{M}']+", unicode: true);

  /// Common words of languages written in English letters. Words that
  /// are also English ("to", "me", "main", "die" ...) are left out.
  static const Map<String, Set<String>> _latinWords = {
    'en': {
      'the', 'a', 'an', 'and', 'or', 'but', 'is', 'are', 'was', 'were', //
      'be', 'been', 'am', 'i', 'you', 'he', 'she', 'it', 'we', 'they',
      'me', 'my', 'your', 'his', 'her', 'its', 'our', 'their', 'this',
      'that', 'these', 'those', 'to', 'of', 'in', 'on', 'at', 'for',
      'with', 'from', 'by', 'about', 'as', 'so', 'not', 'no', 'yes', 'do',
      'does', 'did', 'have', 'has', 'had', 'will', 'would', 'can',
      'could', 'should', 'just', 'what', 'who', 'when', 'where', 'why',
      'how', 'all', 'some', 'very', 'too', 'more', 'most', 'love', 'like',
      'nice', 'good', 'great', 'best', 'beautiful', 'cute', 'wow',
      'happy', 'day', 'night', 'time', 'life', 'today', 'new', 'now',
      'here', 'there', 'thanks', 'thank', 'please', 'awesome', 'amazing',
      'pic', 'photo', 'look', 'looking', 'one', 'out', 'up', 'get', 'got',
      'go', 'going', 'see', 'if', 'then', 'than', 'only', 'really',
      'much', 'many', 'lol', 'omg', 'bro', 'friend', 'friends', 'family',
      'birthday', 'morning', 'world', 'always', 'never', 'again', 'feel',
      'make', 'made', 'first', 'last', 'every', 'way', 'need', 'want',
      "i'm", "it's", "don't", 'im', 'dont', 'u', 'ur', 'him', 'them',
      'us', 'into', 'over', 'after', 'before', 'still', 'well', 'know',
      'think', 'enjoying', 'enjoy', 'weekend', 'vibes', 'beach',
      'sunset', 'trip', 'travel', 'food', 'home', 'work', 'week',
      'year', 'years', 'fun', 'cool', 'sweet', 'lovely', 'perfect',
      'congratulations', 'congrats', 'miss', 'missing', 'come', 'back',
      'little', 'big', 'old', 'man', 'girl', 'boy', 'people', 'say',
      'said', 'went', 'take', 'taken', 'let', "let's", 'lets', 'which',
      'because', 'being', 'something', 'everything', 'nothing',
    },
    'hinglish': {
      'hai', 'hain', 'ho', 'hu', 'hoon', 'hun', 'kya', 'kyu', 'kyun', //
      'kyon', 'nahi', 'nahin', 'nhi', 'bhai', 'bhaiya', 'bhaiyo', 'yaar',
      'yar', 'bahut', 'bohot', 'bohat', 'bht', 'accha', 'acha', 'achha',
      'achcha', 'mast', 'kaise', 'kaisa', 'kaisi', 'kaha', 'kahan', 'kab',
      'kaun', 'kon', 'kuch', 'sab', 'sabko', 'sabhi', 'mera', 'meri',
      'mere', 'tera', 'teri', 'tere', 'tum', 'tu', 'aap', 'hum', 'mujhe',
      'tujhe', 'humko', 'apna', 'apni', 'apne', 'ko', 'ki', 'ka', 'ke',
      'se', 'mein', 'aur', 'bhi', 'toh', 'ye', 'yeh', 'wo', 'woh', 'vo',
      'abhi', 'phir', 'fir', 'kal', 'aaj', 'raat', 'pyaar', 'pyar', 'dil',
      'dost', 'dosto', 'doston', 'ji', 'haan', 'sahi', 'galat', 'chalo',
      'karo', 'karna', 'kiya', 'gaya', 'gayi', 'raha', 'rahi', 'rahe',
      'hoga', 'hogi', 'tha', 'thi', 'sundar', 'khoobsurat', 'khubsurat',
      'badhiya', 'badiya', 'zabardast', 'jabardast', 'shandaar',
      'shandar', 'mazaa', 'maza', 'jaldi', 'bilkul', 'matlab', 'samajh',
      'pata', 'lagta', 'lagti', 'baat', 'baatein', 'logo', 'wala', 'wali',
      'wale', 'ekdum', 'shukriya', 'dhanyavad', 'dhanyawad', 'namaste',
      'bhagwan', 'jai', 'kitna', 'kitni', 'itna', 'itni', 'humara',
      'hamara', 'tumhara', 'unka', 'uska', 'iska', 'usko', 'isko',
      'zindagi', 'jaan', 'kaam', 'paisa', 'ghar', 'khana', 'achhe',
      'acche', 'bada', 'badi', 'chota', 'choti', 'naya', 'nayi', 'purana',
      'lekin', 'magar', 'kyunki', 'agar', 'jab', 'tab', 'yahan', 'wahan',
      'dekho', 'dekh', 'suno', 'bolo', 'bol', 'aaja', 'aao', 'jao',
    },
    'es': {
      'el', 'los', 'las', 'que', 'y', 'es', 'por', 'para', 'con', 'una', //
      'muy', 'pero', 'como', 'mi', 'gracias', 'hola', 'amigo', 'amigos',
      'bueno', 'buenos', 'buenas', 'dias', 'días', 'estoy', 'esta', 'está',
      'más', 'mas', 'yo', 'eres', 'hermosa', 'hermoso', 'feliz', 'te',
      'quiero', 'del', 'lo', 'su', 'nos', 'también', 'tambien', 'siempre',
    },
    'fr': {
      'le', 'les', 'des', 'est', 'et', 'je', 'vous', 'nous', 'avec', //
      'pour', 'dans', 'une', 'mais', 'très', 'tres', 'merci', 'bonjour',
      "c'est", 'pas', 'sur', 'du', 'au', 'aux', 'ce', 'cette', 'mon',
      'ma', 'mes', 'ton', 'tes', 'qui', 'belle', 'beau', 'trop', 'oui',
      'suis', 'bien', 'tout', 'toujours',
    },
    'de': {
      'der', 'das', 'und', 'ist', 'ich', 'nicht', 'mit', 'ein', 'eine', //
      'für', 'fur', 'auf', 'sehr', 'danke', 'schön', 'schon', 'wir', 'sie',
      'du', 'es', 'den', 'dem', 'zu', 'auch', 'noch', 'mein', 'meine',
      'dein', 'deine', 'heute', 'liebe', 'guten', 'tag', 'morgen', 'wie',
    },
    'pt': {
      'os', 'que', 'não', 'nao', 'com', 'uma', 'para', 'muito', 'obrigado', //
      'obrigada', 'você', 'voce', 'bom', 'dia', 'eu', 'meu', 'minha',
      'linda', 'lindo', 'tudo', 'bem', 'isso', 'aqui', 'está', 'são',
      'sao', 'também', 'tambem', 'amor', 'saudade', 'feliz', 'nós',
    },
    'it': {
      'il', 'che', 'non', 'sono', 'per', 'con', 'una', 'molto', 'grazie', //
      'ciao', 'bello', 'bella', 'questo', 'questa', 'anche', 'della',
      'nel', 'sempre', 'tutti', 'tutto', 'buongiorno', 'buonasera',
    },
    'id': {
      'dan', 'yang', 'di', 'ini', 'itu', 'aku', 'kamu', 'tidak', 'ada', //
      'dengan', 'untuk', 'sangat', 'terima', 'kasih', 'bagus', 'cantik',
      'apa', 'saya', 'sudah', 'belum', 'juga', 'kita', 'mereka', 'banget',
      'selamat', 'pagi', 'malam',
    },
    'tr': {
      've', 'bir', 'bu', 'çok', 'cok', 'için', 'icin', 'ile', 'ben', //
      'sen', 'güzel', 'guzel', 'teşekkürler', 'tesekkurler', 'merhaba',
      'var', 'yok', 'değil', 'degil', 'canım', 'canim', 'seni', 'seviyorum',
      'günaydın', 'gunaydin',
    },
  };

  /// Language codes of the word lists ('hinglish' = Hindi in English
  /// letters).
  static String? _latinGuess(List<String> words) {
    final hits = <String, int>{};
    for (final w in words) {
      for (final e in _latinWords.entries) {
        if (e.value.contains(w)) hits[e.key] = (hits[e.key] ?? 0) + 1;
      }
    }
    if (hits.isEmpty) return null;
    final en = hits['en'] ?? 0;
    final other =
        (hits.entries.where((e) => e.key != 'en').toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .firstOrNull;
    // another language wins when it has at least as many words as English
    if (other != null && other.value >= en) return other.key;
    return 'en';
  }

  /// For tests: what the Latin-letter check thinks ('en', 'hinglish',
  /// 'es', ... or null = not sure).
  @visibleForTesting
  static String? guessLatin(String text) => _latinGuess(
    _words
        .allMatches(text.replaceAll(_noise, ' ').toLowerCase())
        .map((m) => m[0]!)
        .toList(),
  );

  static const Set<String> _latinLangs = {
    'en',
    'es',
    'fr',
    'de',
    'it',
    'pt',
    'nl',
    'pl',
    'tr',
    'sv',
    'ro',
    'sw',
    'id',
    'ms',
    'vi',
    'fil',
  };

  /// Show "See translation" under [text]? (for the language [to]).
  static bool shouldOffer(String text, String to) {
    final clean = text.replaceAll(_noise, ' ');
    final counts = <String, int>{};
    var total = 0;
    for (final r in clean.runes) {
      final ch = String.fromCharCode(r);
      for (final e in _scripts.entries) {
        if (e.value.hasMatch(ch)) {
          counts[e.key] = (counts[e.key] ?? 0) + 1;
          total++;
          break;
        }
      }
    }
    if (total < 3) return false;
    final main =
        (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .first
            .key;
    final mine =
        _langScripts[to] ??
        (_latinLangs.contains(to) ? {'latin'} : const <String>{});
    if (main != 'latin') return !mine.contains(main);

    // written in English letters: which language?
    final words = _words
        .allMatches(clean.toLowerCase())
        .map((m) => m[0]!)
        .toList();
    if (words.length < 2) return false;
    final guess = _latinGuess(words);
    // Hindi / Urdu readers can read Hinglish
    if (guess == 'hinglish' && (to == 'hi' || to == 'ur')) return false;
    if (guess == null) {
      // not sure: only for people who don't read English letters
      return !mine.contains('latin') && words.length >= 3;
    }
    if (guess == 'hinglish') return true;
    return guess != to;
  }
}
