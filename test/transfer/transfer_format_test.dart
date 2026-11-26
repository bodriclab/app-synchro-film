import 'package:flutter_test/flutter_test.dart';
import 'package:app_synchro_film/transfer/transfer_format.dart';

void main() {
  group('formatBytes', () {
    test('formate les octets bruts', () {
      expect(formatBytes(0), '0 o');
      expect(formatBytes(512), '512 o');
    });

    test('formate les kilo-octets', () {
      expect(formatBytes(1536), '1,5 Ko');
    });

    test('formate les méga-octets', () {
      expect(formatBytes(1288490), '1,2 Mo');
    });

    test('formate les giga-octets', () {
      expect(formatBytes(4692251279), '4,37 Go');
    });
  });

  group('formatSpeed', () {
    test('formate la vitesse correctement', () {
      expect(formatSpeed(12900000.0), '12,3 Mo/s');
    });

    test('gère les valeurs invalides ou négatives', () {
      expect(formatSpeed(-1.0), '—');
      expect(formatSpeed(double.nan), '—');
    });
  });

  group('formatEta', () {
    test('gère les valeurs nulles et courtes', () {
      expect(formatEta(null), '');
      expect(formatEta(const Duration(seconds: 45)), '45 s');
    });

    test('formate les durées en minutes et secondes', () {
      expect(formatEta(const Duration(seconds: 185)), '3 min 05 s');
    });

    test('formate les durées en heures et minutes', () {
      expect(formatEta(const Duration(seconds: 3720)), '1 h 02 min');
    });
  });

  group('transferPageHtml', () {
    test('échappe les caractères spéciaux du nom et intègre l\'url', () {
      const name = '<b>&.mkv';
      const size = 1536;
      const url = 'http://192.168.1.10:8080/file?id=1';

      final html = transferPageHtml(name: name, size: size, downloadUrl: url);

      // Vérifie l'échappement HTML du nom dans l'élément
      expect(html, contains('&lt;b&gt;&amp;.mkv'));
      // Vérifie l'attribut download et l'URL
      expect(html, contains('href="http://192.168.1.10:8080/file?id=1"'));
      expect(html, contains('download="&lt;b&gt;&amp;.mkv"'));
      expect(html, contains('Télécharger'));
      // Vérifie l'absence totale de JavaScript
      expect(html.contains('<script'), isFalse);
    });
  });
}
