/// Hyper Intelligence: STRONG abuse / slurs in English, Hindi and
/// Hinglish. Checked on the phone BEFORE captions, comments, names, bios,
/// usernames, highlight names and editor texts are saved.
///
/// Mild words (shit, damn, bastard, saala, kamina, kutta, bc, mc...) are
/// allowed on purpose.
///
/// Whole words only (so "Scunthorpe", "class", "cut", "Niger" are fine);
/// a few very clear words also count inside other words ("fuckboy").
/// Tricks are undone:
///  * f.u.c.k / f u c k / fuuuck / FUCK / 5lut / f*ck / ph*ck
///  * Hinglish spellings: chootiya = chutiya, madharchod = madarchod,
///    bhenchod = behenchod, lawde = lavde
///  * Hindi: ड़ / ड़, गाँड / गांड, hidden joiner characters
/// v0.19: many more spellings; Hindi letters made the same first.
class BadWords {
  BadWords._();

  /// Whole words, as typed (lowercase).
  static const Set<String> _words = {
    // ---- English
    'fuck', 'fucks', 'fucker', 'fuckers', 'fucking', 'fuckin', 'fucked',
    'fuk', 'fuking', 'fukin', 'fck', 'fcking', 'fcker', 'fukc', 'fuq',
    'fuqing', 'phuck', 'phck', 'phuk', 'phucking', 'fvck', 'fvcking', 'fking',
    'fkin', 'fkn', 'mofo', 'motherfucker',
    'motherfuckers', 'motherfucking', 'cunt', 'cunts', 'bitch', 'bitches',
    'biatch', 'whore', 'whores', 'slut', 'sluts', 'slutty', 'nigger',
    'niggers',
    'nigga',
    'niggas',
    'nigg',
    'faggot',
    'faggots',
    'retard',
    'retards',
    'retarded',
    'tranny',
    'dickhead',
    'dickheads', 'cocksucker', 'cocksuckers', 'asshole', 'assholes',
    'pussy', 'pussies', 'twat', 'wanker', 'kys',
    // ---- Hinglish
    'madarchod', 'maderchod', 'madarchood', 'madharchod', 'madarchot',
    'maadarchod', 'madarjaat', 'mdrchod', 'mdrchd', 'behenchod',
    'bhenchod', 'behanchod', 'bahenchod', 'bahanchod', 'benchod',
    'bhanchod',
    'bhencho',
    'behencho',
    'bhenchodd',
    'bhnchd',
    'bkl',
    'bsdk',
    'bhosdike',
    'bhosadike',
    'bhosdika',
    'bhosdiki',
    'bhosdiwala', 'bhosdiwale', 'bhosda', 'bhosdi', 'bhosadi', 'bhosri',
    'bhosriwala', 'bhosriwale', 'bhosdk', 'chutiya', 'chutiye', 'chutiyo',
    'chutia', 'chutya', 'chootiya', 'chotiya', 'chutiyapa', 'chut',
    'choot', 'chuut', 'chutmarike', 'gaand', 'gaandu', 'gandu', 'gandfat',
    'gaandfat', 'randi', 'randiya', 'randibaaz', 'raand', 'randwa',
    'harami', 'haraami', 'haramkhor', 'haramzada', 'haramzade',
    'haramzadi', 'haraamzaada', 'lauda', 'laude', 'lavda', 'lavde',
    'lawda', 'lawde', 'loda', 'lodu', 'lundd', 'jhaatu',
    'jhatu', 'jhaant', 'jhant', 'bhadwa', 'bhadwe', 'bhadve',
    'bhadva',
    'bhadvi',
    'chinal',
    'chhinal',
    'kutiya',
    'chodu',
    'chudai',
    'chudwa',
    'chudwaya',
    'chudwale', 'chudaai',
    'mkc', 'tmkc', 'mkb', 'tmkb',
    // ---- Hindi
    'मादरचोद', 'मादरचौद', 'मादरजात', 'बहनचोद', 'बहनचौद', 'भेनचोद',
    'बहन्चोद', 'भोसड़ी', 'भोसड़ीके', 'भोसड़ीवाला', 'भोसड़ा', 'भोसडी',
    'भोसडीके', 'चूतिया', 'चुतिया', 'चूतिये', 'चुतिये', 'चूत', 'गांडू',
    'गाण्डू', 'गांड', 'गाण्ड', 'रंडी', 'रण्डी', 'रांड', 'हरामी',
    'हरामज़ादा', 'हरामजादा', 'हरामज़ादी', 'हरामजादी', 'हरामखोर', 'लौड़ा',
    'लौडा', 'लौड़े', 'लौडे', 'लवड़ा', 'लोड़ा', 'लोडा', 'लंड', 'लण्ड',
    'भड़वा', 'भडवा', 'भड़वे', 'भडवे', 'कुतिया', 'झाटू', 'झांटू', 'छिनाल',
    'चोदू', 'चोद', 'चुदाई', 'चुदवा', 'हिजड़ा', 'हिजडा',
  };

  /// Also bad inside another word ("fuckboy", "bhenchodd99").
  static const List<String> _inside = [
    'fuck',
    'motherfuck',
    'cocksuck',
    'nigger',
    'faggot',
    'madarchod',
    'maderchod',
    'madharchod',
    'behenchod',
    'bhenchod',
    'behanchod',
    'bahenchod',
    'benchod',
    'bhosdi',
    'bhosad',
    'bhosri',
    'chutiya',
    'chootiya',
    'chutiye',
    'randibaaz',
    'haramzad',
    'haramkhor',
    'मादरचोद',
    'बहनचोद',
    'भेनचोद',
    'भोसड़ी',
    'भोसडी',
    'चूतिया',
    'चुतिया',
    'हरामज़ाद',
    'हरामजाद',
  ];

  /// Bad together ("kill yourself", "teri maa ki chut").
  static const List<String> _phrases = [
    'kill yourself',
    'kill urself',
    'kill your self',
    'go kill yourself',
    'go die',
    'die bitch',
    'i will rape you',
    'ill rape you',
    'rape you',
    'maa ki chut',
    'maa ki choot',
    'behen ki chut',
    'bahen ki chut',
    'bhen ki chut',
    'behen ke lode',
    'bhen ke lode',
    'bahen ke lode',
    'behen ke lund',
    // "Lund" alone is also a city / name -> only in bad phrases
    'mera lund',
    'lund le',
    'lund lele',
    'lund chus',
    'lund pe',
    'lund ke baal',
    'maa chod',
    'maa chuda',
    'maa ka bhosda',
    'teri maa ki',
    'teri ma ki',
    'teri behen ki',
    'son of a bitch',
    'मां की चूत',
    'माँ की चूत',
    'मां चोद',
    'माँ चोद',
    'बहन की चूत',
    'बहन के लौड़े',
    'तेरी मां की',
    'तेरी माँ की',
    'तेरी बहन की',
  ];

  static final RegExp _split = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
  static final RegExp _repeat = RegExp(r'(.)\1+', unicode: true);
  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _latin = RegExp(r'^[a-z0-9]+$');

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

  /// Hindi letters typed in different ways -> one way.
  static const Map<String, String> _hindi = {
    '\u0958': '\u0915', // क़ -> क
    '\u0959': '\u0916', // ख़ -> ख
    '\u095A': '\u0917', // ग़ -> ग
    '\u095B': '\u091C', // ज़ -> ज
    '\u095C': '\u0921', // ड़ -> ड
    '\u095D': '\u0922', // ढ़ -> ढ
    '\u095E': '\u092B', // फ़ -> फ
    '\u095F': '\u092F', // य़ -> य
    '\u093C': '', //       nukta (the dot)
    '\u0901': '\u0902', // chandrabindu -> anusvara (गाँड = गांड)
    '\u200B': '', '\u200C': '', '\u200D': '', '\u2060': '', '\uFEFF': '',
    '\u00AD': '', // invisible characters
  };

  /// ! @ $ only count inside a word ("sh!t", not "wow!!").
  static String _undoTricks(String s) {
    final chars = s.toLowerCase().split('');
    final b = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final h = _hindi[ch];
      if (h != null) {
        b.write(h);
        continue;
      }
      final to = _leet[ch];
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

  /// How a Hinglish word sounds, so different spellings match:
  /// chootiya / chutiya -> cutiya, madharchod -> madarcod.
  /// Only used for words of 5+ letters (short ones collide with English:
  /// "chut" would become "cut").
  static String _sound(String w) {
    if (!_latin.hasMatch(w)) return _squash(w);
    var s = w
        .replaceAll('ph', 'f')
        .replaceAll('ck', 'k')
        .replaceAll('q', 'k')
        .replaceAll('w', 'v')
        .replaceAll('z', 'j')
        .replaceAll('ee', 'i')
        .replaceAll('oo', 'u')
        .replaceAll('aa', 'a');
    // h after a letter is mostly silent in Hinglish (bh, ch, dh...)
    s = s.isEmpty ? s : s[0] + s.substring(1).replaceAll('h', '');
    return _squash(s);
  }

  static String _clean(String w) => _undoTricks(w);

  static final Set<String> _wordsClean = {for (final w in _words) _clean(w)};
  static final Set<String> _squashed = {
    for (final w in _wordsClean) _squash(w),
  };
  static final Set<String> _sounds = {
    for (final w in _wordsClean)
      if (_sound(w).length >= 5) _sound(w),
  };
  static final List<String> _insideClean = [for (final w in _inside) _clean(w)];
  static final List<String> _insideSounds = [
    for (final w in _insideClean)
      if (_sound(w).length >= 6) _sound(w),
  ];
  static final List<String> _phrasesClean = [
    for (final p in _phrases) _clean(p).split(_split).join(' '),
  ];

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
      if (_wordsClean.contains(t)) return t;
      final sq = _squash(t);
      if (sq != t && _squashed.contains(sq)) return t;
      final so = _sound(t);
      if (so != sq && so.length >= 5 && _sounds.contains(so)) return t;
      for (final w in _insideClean) {
        if (t.contains(w) || sq.contains(w)) return t;
      }
      if (so.length >= 6) {
        for (final w in _insideSounds) {
          if (so.contains(w)) return t;
        }
      }
    }
    final line = ' ${tokens.join(' ')} ';
    for (final p in _phrasesClean) {
      if (line.contains(' $p ')) return p;
    }
    return null;
  }

  /// "fuck" -> "f***" (to show in a message).
  static String mask(String w) {
    final chars = w.runes.map(String.fromCharCode).toList();
    if (chars.length <= 1) return '*';
    return '${chars.first}${'*' * (chars.length - 1)}';
  }
}
