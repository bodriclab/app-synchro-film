import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:app_synchro_film/core/subtitle_text.dart';

void main() {
  test('Décodage BOM UTF-8', () {
    final bytes = Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      0x48,
      0x65,
      0x6C,
      0x6C,
      0x6F,
    ]);
    expect(decodeSubtitleBytes(bytes), equals('Hello'));
  });

  test('Décodage UTF-16 LE avec BOM', () {
    final bytes = Uint8List.fromList([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00]);
    expect(decodeSubtitleBytes(bytes), equals('Hi'));
  });

  test('Repli latin1 pour caractères accentués', () {
    final bytes = Uint8List.fromList([0xE9, 0x74, 0x65]); // éte
    expect(decodeSubtitleBytes(bytes), equals('éte'));
  });

  test('Normalisation CRLF et CR en LF', () {
    final bytes = Uint8List.fromList([0x41, 0x0D, 0x0A, 0x42, 0x0D, 0x43]);
    expect(decodeSubtitleBytes(bytes), equals('A\nB\nC'));
  });

  test('Conversion SRT vers VTT basique', () {
    const srt =
        '1\n00:00:01,000 --> 00:00:04,000\nBonjour\n\n2\n00:00:05,000 --> 00:00:08,000\nMonde';
    final vtt = srtToVtt(srt);
    expect(
      vtt,
      equals(
        'WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.000\nBonjour\n\n2\n00:00:05.000 --> 00:00:08.000\nMonde\n',
      ),
    );
  });

  test('Horodatages tolérants SRT (,5 ms et heure sur 1 chiffre)', () {
    const srt = '1\n0:01:02,5 --> 0:01:05,12\nTest';
    final vtt = srtToVtt(srt);
    expect(vtt, contains('00:01:02.500 --> 00:01:05.120'));
  });

  test('Suppression balises font et blocs ASS', () {
    const srt =
        '1\n00:00:01,000 --> 00:00:02,000\n{\\an8}{\\i1}Texte <font color="red">Rouge</font>';
    final vtt = srtToVtt(srt);
    expect(vtt, contains('Texte Rouge'));
  });

  test('Décalage positif shiftVtt', () {
    const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nTest';
    final shifted = shiftVtt(vtt, 2000);
    expect(shifted, contains('00:00:03.000 --> 00:00:05.000'));
  });

  test('Décalage négatif supprimant un cue et clamping le début', () {
    const vtt =
        'WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nSupprimé\n\n2\n00:00:03.000 --> 00:00:06.000\nClampé';
    final shifted = shiftVtt(vtt, -2500);
    expect(shifted, isNot(contains('Supprimé')));
    expect(shifted, contains('00:00:00.500 --> 00:00:03.500'));
    expect(shifted, startsWith('WEBVTT\n\n2\n'));
    // Début négatif ramené à 0.
    expect(shiftVtt(vtt, -3500), contains('00:00:00.000 --> 00:00:02.500'));
  });

  test('Dispatch subtitleToVtt et exception FormatException', () {
    expect(
      subtitleToVtt('WEBVTT\n\nTest', 'file.vtt'),
      equals('WEBVTT\n\nTest'),
    );
    expect(
      subtitleToVtt('1\n00:00:01,000 --> 00:00:02,000\nTest', 'file.srt'),
      startsWith('WEBVTT'),
    );
    expect(
      () => subtitleToVtt('Texte invalide', 'file.txt'),
      throwsFormatException,
    );
  });
}
