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
/// Our server asks Google (free, no key); if the server can't, the phone
/// asks Google directly.
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

  @visibleForTesting
  void clearCache() => _cache.clear();

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
          });
      out = Translation(
        text: (r['text'] as String?) ?? '',
        from: (r['from'] as String?) ?? '',
        to: lang,
      );
      if (out.text.isEmpty) throw const FormatException('empty');
    } catch (e) {
      // 400 = bad text / language: the phone won't do better
      if (e is ApiException && e.statusCode == 400) rethrow;
      out = await (debugDirect ?? _direct)(t, lang);
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
  };

  static String _fromCode(String c) {
    final l = c.toLowerCase();
    return _fromGoogle[l] ?? l.split('-').first;
  }

  /// Straight from the phone (same free Google link as the server).
  static Future<Translation> _direct(String text, String to) async {
    final tl = Uri.encodeQueryComponent(_toGoogle[to] ?? to);
    final r = await http
        .post(
          Uri.parse(
            'https://clients5.google.com/translate_a/t'
            '?client=dict-chrome-ex&sl=auto&tl=$tl',
          ),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          },
          body: 'q=${Uri.encodeQueryComponent(text)}',
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return parseClients5(utf8.decode(r.bodyBytes), to);
  }

  /// `[["text","src"]]`, `["text"]` or `[["text"]]`.
  @visibleForTesting
  static Translation parseClients5(String body, String to) {
    final d = jsonDecode(body);
    final first = d is List && d.isNotEmpty ? d.first : null;
    if (first is String) return Translation(text: first, from: '', to: to);
    if (first is List && first.isNotEmpty && first.first is String) {
      return Translation(
        text: first.first as String,
        from: first.length > 1 ? _fromCode('${first[1]}') : '',
        to: to,
      );
    }
    throw const FormatException('Unknown answer');
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

  /// Very common English words (to tell English from other languages
  /// written in the same letters, like Hinglish).
  static const Set<String> _english = {
    'the',
    'a',
    'an',
    'and',
    'or',
    'but',
    'is',
    'are',
    'was',
    'were',
    'be',
    'been',
    'am',
    'i',
    'you',
    'he',
    'she',
    'it',
    'we',
    'they',
    'me',
    'my',
    'your',
    'his',
    'her',
    'its',
    'our',
    'their',
    'this',
    'that',
    'these',
    'those',
    'to',
    'of',
    'in',
    'on',
    'at',
    'for',
    'with',
    'from',
    'by',
    'about',
    'as',
    'so',
    'not',
    'no',
    'yes',
    'do',
    'does',
    'did',
    'have',
    'has',
    'had',
    'will',
    'would',
    'can',
    'could',
    'should',
    'just',
    'what',
    'who',
    'when',
    'where',
    'why',
    'how',
    'all',
    'some',
    'very',
    'too',
    'more',
    'most',
    'love',
    'like',
    'nice',
    'good',
    'great',
    'best',
    'beautiful',
    'cute',
    'wow',
    'happy',
    'day',
    'night',
    'time',
    'life',
    'today',
    'new',
    'now',
    'here',
    'there',
    'thanks',
    'thank',
    'please',
    'awesome',
    'amazing',
    'pic',
    'photo',
    'look',
    'looking',
    'one',
    'out',
    'up',
    'get',
    'got',
    'go',
    'going',
    'see',
    'if',
    'then',
    'than',
    'only',
    'really',
    'much',
    'many',
    'lol',
    'omg',
    'bro',
    'friend',
    'friends',
    'family',
    'birthday',
    'morning',
    'world',
    'always',
    'never',
    'again',
    'feel',
    'make',
    'made',
    'first',
    'last',
    'every',
    'way',
    'need',
    'want',
    "i'm",
    "it's",
    "don't",
    'im',
    'dont',
    'u',
    'ur',
    'him',
    'them',
    'us',
    'into',
    'over',
    'after',
    'before',
    'still',
    'well',
    'know',
    'think',
  };

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
    if (!mine.contains(main)) return true;
    if (main != 'latin') return false;
    // both in Latin letters: English or not?
    final words = _words
        .allMatches(clean.toLowerCase())
        .map((m) => m[0]!)
        .toList();
    if (words.isEmpty) return false;
    final en = words.where(_english.contains).length / words.length;
    if (to == 'en') {
      return words.length >= 2 ? en < 0.25 : false;
    }
    return en >= 0.3;
  }
}
