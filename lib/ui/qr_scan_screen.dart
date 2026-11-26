import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/constants.dart';

/// Scan du QR code de l'hôte (Android). Retourne la chaîne lue.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({
    super.key,
    this.accept,
    this.title = 'Scanner le QR code de l\'hôte',
  });

  /// Contenu accepté (par défaut : lien de session `synchrofilm://`).
  final bool Function(String value)? accept;
  final String title;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final value = b.rawValue;
      final ok =
          value != null &&
          (widget.accept?.call(value) ?? value.startsWith('$kUriScheme://'));
      if (ok) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
