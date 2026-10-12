import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/features/post/data/post_repository.dart';

void main() {
  test('hashtags are found, lowercased and unique', () {
    expect(
      PostRepository.extractTags('Sunset at #Goa with #friends_2 #goa!'),
      ['goa', 'friends_2'],
    );
  });

  test('hindi and other languages work', () {
    expect(PostRepository.extractTags('#होली मुबारक'), ['होली']);
  });

  test('no tags -> empty list, max 30', () {
    expect(PostRepository.extractTags('no tags here'), isEmpty);
    final many = List.generate(40, (i) => '#t$i').join(' ');
    expect(PostRepository.extractTags(many).length, 30);
  });
}
