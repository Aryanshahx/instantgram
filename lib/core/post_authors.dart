/// Who posted what (filled while posts load), so a like or a save can also tell the
/// For you feed which account it was about.
final Map<String, String> _authors = {};

void rememberAuthor(String postId, String authorId) {
  if (postId.isEmpty || authorId.isEmpty) return;
  if (_authors.length > 2000) _authors.clear();
  _authors[postId] = authorId;
}

String authorOf(String postId) => _authors[postId] ?? '';
