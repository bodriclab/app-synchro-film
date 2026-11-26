import 'package:flutter_test/flutter_test.dart';
import 'package:app_synchro_film/core/subtitles.dart';
import 'package:app_synchro_film/core/protocol.dart';

void main() {
  test('Conversion JSON round-trip des sélections', () {
    final off = const SubtitleSelection.off();
    final embedded = const SubtitleSelection.embedded(
      3,
      title: 'Français',
      language: 'fre',
      codec: 'subrip',
    );
    final external = const SubtitleSelection.external('sous-titres.srt');

    final offJson = off.toJson();
    final embeddedJson = embedded.toJson();
    final externalJson = external.toJson();

    final offFromJson = SubtitleSelection.fromJson(offJson);
    final embeddedFromJson = SubtitleSelection.fromJson(embeddedJson);
    final externalFromJson = SubtitleSelection.fromJson(externalJson);

    expect(offFromJson, equals(off));
    expect(embeddedFromJson, equals(embedded));
    expect(externalFromJson, equals(external));
  });

  test('Libellé de la sélection', () {
    // Embedded avec titre et langue
    final sel1 = const SubtitleSelection.embedded(
      0,
      title: 'Français',
      language: 'fre',
    );
    expect(sel1.label, 'Français [fre]');

    // Embedded sans titre ni langue, index 1 -> Piste 2
    final sel2 = const SubtitleSelection.embedded(1);
    expect(sel2.label, 'Piste 2');

    // Codec bitmap
    final sel3 = const SubtitleSelection.embedded(
      0,
      codec: 'hdmv_pgs_subtitle',
    );
    expect(sel3.isBitmap, isTrue);
    expect(sel3.label, contains('(image)'));
  });

  test('Encodage et décodage du message SubsMsg', () {
    final selection = const SubtitleSelection.embedded(2, title: 'Anglais');
    const rev = 7;
    final msg = SubsMsg(selection, rev: rev);

    final raw = msg.encode();
    final decoded = SyncMessage.decode(raw) as SubsMsg;

    expect(decoded.selection, equals(selection));
    expect(decoded.rev, rev);
  });

  test('Arguments VTT pour piste intégrée', () {
    final args = embeddedVttArgs('in.mkv', 2);
    expect(args, contains('0:s:2'));
    expect(args, contains('webvtt'));
    expect(args.last, '{out}');
  });
}
