import 'package:app_synchro_film/core/http_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = 1000;

  ByteRange? partial(String? h) => switch (parseRange(h, size)) {
        PartialContent(:final range) => range,
        _ => null,
      };

  test('sans Range ou Range invalide : contenu complet', () {
    for (final h in [null, '', 'items=0-1', 'bytes=abc', 'bytes=5-2',
        'bytes=0-1,5-9', 'bytes=-x']) {
      expect(parseRange(h, size), isA<FullContent>(), reason: '$h');
    }
  });

  test('plages simples', () {
    expect(partial('bytes=0-99'), const ByteRange(0, 99));
    expect(partial('bytes=500-'), const ByteRange(500, 999));
    expect(partial('bytes=900-5000'), const ByteRange(900, 999));
    expect(partial('Bytes = 10-10'), null); // espaces avant '=' : ignoré
    expect(partial('bytes=10-10')!.length, 1);
  });

  test('suffixe', () {
    expect(partial('bytes=-100'), const ByteRange(900, 999));
    expect(partial('bytes=-5000'), const ByteRange(0, 999));
  });

  test('non satisfiable', () {
    expect(parseRange('bytes=1000-', size), isA<UnsatisfiableRange>());
    expect(parseRange('bytes=-0', size), isA<UnsatisfiableRange>());
    expect(parseRange('bytes=0-', 0), isA<UnsatisfiableRange>());
  });

  test('Content-Range et MIME', () {
    expect(const ByteRange(0, 99).contentRange(size), 'bytes 0-99/1000');
    expect(mimeTypeFor('Film.MKV'), 'video/x-matroska');
    expect(mimeTypeFor('a.mp4'), 'video/mp4');
    expect(mimeTypeFor('sans_extension'), 'application/octet-stream');
  });
}
