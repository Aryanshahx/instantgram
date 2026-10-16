/// v0.18 Hyper Intelligence: strong abuse / slurs in English, Hindi and
/// Hinglish. Checked on the phone BEFORE captions, comments, names, bios,
/// usernames and highlight names are saved.
///
/// Whole words only (so "Scunthorpe", "class", "Niger" are fine); a few
/// very clear words also count inside other words ("fuckboy").
/// Tricks are undone: f.u.c.k / fuuuck / FUCK / 5lut / sh!t.
class BadWords {
  BadWords._();

  /// Whole words (lowercase).
  static const Set<String> _words = {
    // English
    'fuck', 'fucker', 'fuckers', 'fucking', 'fucked', 'fuk', 'fuking',
    'fck', 'fcking', 'fukc', 'cunt', 'cunts', 'bitch', 'bitches',
    'whore', 'whores', 'slut', 'sluts', 'nigger', 'niggers', 'nigga',
    'niggas', 'faggot', 'faggots', 'retard', 'retards', 'dickhead',
    'asshole', 'assholes', 'motherfucker', 'kys',
    // Hinglish
    'madarchod', 'maderchod', 'madarchood', 'behenchod', 'bhenchod',
    'behanchod', 'bahenchod', 'bhosdike', 'bhosdika', 'bhosdiwala',
    'bhosdiwale', 'bhosda', 'bhosadi', 'bsdk', 'chutiya', 'chutiye',
    'chutia', 'chut', 'gaand', 'gandu', 'randi', 'randwa', 'harami',
    'haramkhor', 'haramzada', 'haramzadi', 'lauda', 'lavda',
    'lawda', 'lodu', 'jhaatu', 'jhatu', 'bhadwa', 'bhadwe',
    'bhadve', 'kutiya', 'chodu', 'mkc', 'tmkc',
    // Hindi
    'मादरचोद', 'मादरचौद', 'बहनचोद', 'बहनचौद', 'भेनचोद', 'भोसड़ी', 'भोसडी',
    'भोसड़ीके', 'भोसडीके', 'चूतिया', 'चुतिया', 'चूत', 'गांडू', 'गाण्डू',
    'गांड', 'रंडी', 'हरामी', 'हरामज़ादा', 'हरामजादा', 'हरामखोर', 'लौड़ा',
    'लौडा', 'लंड', 'लण्ड', 'भड़वा', 'भडवा', 'कुतिया', 'झाटू',
  };

  /// Also bad inside another word.
  static const List<String> _inside = [
    'fuck',
    'motherfuck',
    'madarchod',
    'behenchod',
    'bhenchod',
    'behanchod',
    'bhosdi',
    'chutiya',
    'nigger',
    'faggot',
    'मादरचोद',
    'बहनचोद',
    'भेनचोद',
    'भोसड़ी',
    'चूतिया',
  ];

  /// Bad together ("kill yourself").
  static const List<String> _phrases = [
    'kill yourself',
    'kill urself',
    'kill your self',
    'go die',
    'die bitch',
  ];

  static final RegExp _split = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
  static final RegExp _repeat = RegExp(r'(.)\1+', unicode: true);

  static const Map<String, String> _leet = {
    '0': 'o',
    '1': 'i',
    '3': 'e',
    '4': 'a',
    '5': 's',
    '7': 't',
    '@': 'a',
    r'$': 's',
    '!': 'i',
    '*': '',
  };

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static String _undoTricks(String s) {
    final chars = s.toLowerCase().split('');
    final b = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final to = _leet[ch];
      // ! @ $ only count inside a word ("sh!t"), not "wow!!"
      final inside = i + 1 < chars.length && _wordChar.hasMatch(chars[i + 1]);
      if (to == null || ('!@\$'.contains(ch) && !inside)) {
        b.write(ch);
      } else {
        b.write(to);
      }
    }
    return b.toString();
  }

  /// "fuuuuck" -> "fuck"
  static String _squash(String w) => w.replaceAllMapped(_repeat, (m) => m[1]!);

  static final Set<String> _squashed = {for (final w in _words) _squash(w)};

  /// The first bad word in [text], or null when it is fine.
  static String? find(String text) {
    if (text.trim().isEmpty) return null;
    final clean = _undoTricks(text);
    final tokens = clean.split(_split).where((t) => t.isNotEmpty).toList();
    // "f u c k" / "f.u.c.k": single letters in a row are joined
    final joined = <String>[];
    var run = StringBuffer();
    for (final t in tokens) {
      if (t.length == 1) {
        run.write(t);
      } else {
        if (run.length > 1) joined.add(run.toString());
        run = StringBuffer();
      }
    }
    if (run.length > 1) joined.add(run.toString());
    for (final t in [...tokens, ...joined]) {
      if (_words.contains(t)) return t;
      final sq = _squash(t);
      if (sq != t && _squashed.contains(sq)) return t;
      for (final w in _inside) {
        if (t.contains(w) || sq.contains(w)) return t;
      }
    }
    final line = ' ${tokens.join(' ')} ';
    for (final p in _phrases) {
      if (line.contains(' $p ')) return p;
    }
    return null;
  }

  /// "fuck" -> "f***" (to show in a message).
  static String mask(String w) {
    final chars = w.characters0;
    if (chars.length <= 1) return '*';
    return '${chars.first}${'*' * (chars.length - 1)}';
  }
}

extension on String {
  /// Unicode-safe letters (Hindi letters can be 2 code units).
  List<String> get characters0 => runes.map(String.fromCharCode).toList();
}
