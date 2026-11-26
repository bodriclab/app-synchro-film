library;

import 'dart:convert';
import 'dart:typed_data';

/// Décode les octets d'un sous-titre en gérant les BOM et les encodages courants.
String decodeSubtitleBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    bytes = bytes.sublist(3);
  } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final codeUnits = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codeUnits).replaceAll(RegExp(r'\r\n?'), '\n');
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final codeUnits = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(codeUnits).replaceAll(RegExp(r'\r\n?'), '\n');
  }

  String decoded;
  try {
    decoded = utf8.decode(bytes);
  } catch (_) {
    decoded = latin1.decode(bytes);
  }
  return decoded.replaceAll(RegExp(r'\r\n?'), '\n');
}

/// Convertit un contenu SubRip (SRT) en WebVTT.
String srtToVtt(String srt) {
  final normalized = srt.replaceAll(RegExp(r'\r\n?'), '\n');
  final blocks = normalized.split(RegExp(r'\n\s*\n'));
  final vttCues = <String>[];

  final timeRegExp = RegExp(
    r'^(\d{1,2}:\d{2}:\d{2})[,.](\d{1,3})\s*(?:-->|->)\s*(\d{1,2}:\d{2}:\d{2})[,.](\d{1,3})(?:\s+.*)?$',
  );

  for (var block in blocks) {
    block = block.trim();
    if (block.isEmpty) continue;

    final lines = block.split('\n');
    int timeLineIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (timeRegExp.hasMatch(lines[i].trim())) {
        timeLineIndex = i;
        break;
      }
    }

    if (timeLineIndex == -1) continue;

    String? idLine = timeLineIndex > 0 ? lines[timeLineIndex - 1].trim() : null;
    final timeLine = lines[timeLineIndex].trim();
    final textLines = lines.sublist(timeLineIndex + 1);

    final match = timeRegExp.firstMatch(timeLine);
    if (match == null) continue;

    final startHms = match.group(1)!;
    final startMs = match.group(2)!.padRight(3, '0');
    final endHms = match.group(3)!;
    final endMs = match.group(4)!.padRight(3, '0');

    // Les coordonnées SRT (X1:… Y2:…) n'ont pas d'équivalent : ignorées.
    final newTimeLine =
        '${startHms.padLeft(8, '0')}.$startMs --> ${endHms.padLeft(8, '0')}.$endMs';

    final cleanedTextLines = <String>[];
    for (var line in textLines) {
      var cleaned = line
          .replaceAll(RegExp(r'</?(?:font\b[^>]*)?>', caseSensitive: false), '')
          .replaceAll(RegExp(r'\{\\[^}]*\}'), '');

      if (cleaned.contains('-->')) {
        cleaned = cleaned.replaceAll('-->', '->');
      }
      cleanedTextLines.add(cleaned);
    }

    final cueBuffer = StringBuffer();
    if (idLine != null && idLine.isNotEmpty) {
      cueBuffer.writeln(idLine);
    }
    cueBuffer.writeln(newTimeLine);
    for (var tl in cleanedTextLines) {
      cueBuffer.writeln(tl);
    }

    final cueStr = cueBuffer.toString().trim();
    if (cueStr.isNotEmpty) {
      vttCues.add(cueStr);
    }
  }

  return 'WEBVTT\n\n${vttCues.join('\n\n')}\n';
}

/// Vérifie si le texte ressemble à du WebVTT.
bool looksLikeVtt(String text) {
  final clean = text.replaceFirst(RegExp(r'^\uFEFF'), '').trimLeft();
  return clean.startsWith('WEBVTT');
}

/// "MM:SS.mmm" ou "H:MM:SS,mmm" → millisecondes.
int _timeToMs(String t) {
  final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})$')
      .firstMatch(t);
  if (m == null) throw FormatException('horodatage invalide : $t');
  final h = int.parse(m.group(1) ?? '0');
  final min = int.parse(m.group(2)!);
  final sec = int.parse(m.group(3)!);
  final ms = int.parse(m.group(4)!.padRight(3, '0'));
  return ((h * 60 + min) * 60 + sec) * 1000 + ms;
}

/// Millisecondes → "HH:MM:SS.mmm" (négatif ramené à 0).
String _msToTime(int ms) {
  if (ms < 0) ms = 0;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:'
      '${two(ms ~/ 1000 % 60)}.${(ms % 1000).toString().padLeft(3, '0')}';
}

final RegExp _vttTiming = RegExp(
  r'^\s*((?:\d+:)?\d{1,2}:\d{1,2}[.,]\d{1,3})\s*-->\s*'
  r'((?:\d+:)?\d{1,2}:\d{1,2}[.,]\d{1,3})(.*)$',
);

/// Décale les minutages d'un WebVTT de [shiftMs] ms. Les cues qui finissent
/// avant 0 sont supprimés ; un début négatif est ramené à 0. L'en-tête
/// (WEBVTT, NOTE, STYLE avant le premier cue) est conservé tel quel.
String shiftVtt(String vtt, int shiftMs) {
  if (shiftMs == 0) return vtt;
  final blocks = vtt
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .split(RegExp(r'\n[ \t]*\n'));
  final out = <String>[];
  for (final block in blocks) {
    if (block.trim().isEmpty) continue;
    final lines = block.split('\n');
    final ti = lines.indexWhere(_vttTiming.hasMatch);
    if (ti < 0) {
      out.add(block); // en-tête, NOTE, STYLE, REGION
      continue;
    }
    final m = _vttTiming.firstMatch(lines[ti])!;
    final start = _timeToMs(m.group(1)!) + shiftMs;
    final end = _timeToMs(m.group(2)!) + shiftMs;
    if (end <= 0) continue;
    lines[ti] = '${_msToTime(start)} --> ${_msToTime(end)}${m.group(3)}';
    out.add(lines.join('\n'));
  }
  return '${out.join('\n\n')}\n';
}

/// Convertit un sous-titre générique en VTT si nécessaire.
String subtitleToVtt(String text, String fileName) {
  if (looksLikeVtt(text)) {
    return text;
  }
  final lowerName = fileName.toLowerCase();
  final hasSrtExt = lowerName.endsWith('.srt');
  final hasSrtTiming = RegExp(r'\d{1,2}:\d{2}:\d{2},\d{3}\s*-->')
      .hasMatch(text);

  if (hasSrtExt || hasSrtTiming) {
    return srtToVtt(text);
  }

  throw FormatException('format non pris en charge');
}
