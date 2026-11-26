import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/media_source.dart';
import '../net/network_info.dart';
import '../platform/media_access.dart';
import '../transfer/downloader.dart';
import '../transfer/sink_factory.dart';
import '../transfer/transfer_format.dart';
import '../transfer/transfer_server.dart';
import 'qr_scan_screen.dart';

class SendFileScreen extends StatefulWidget {
  const SendFileScreen({super.key});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  MediaRef? _mediaRef;
  TransferServer? _server;
  List<String> _ips = [];
  String? _selectedIp;
  String? _error;
  Timer? _timer;
  int _lastBytesSent = 0;
  double _currentSpeed = 0.0;
  int _displayBytesSent = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _server?.stop();
    super.dispose();
  }

  Future<void> _pickAndStart() async {
    setState(() {
      _error = null;
    });
    final ref = await pickMedia();
    if (ref == null) return;
    if (!mounted) return;

    try {
      final server = TransferServer(media: ref);
      await server.start();
      final ips = await localIPv4Addresses();
      if (!mounted) {
        await server.stop();
        return;
      }
      setState(() {
        _mediaRef = ref;
        _server = server;
        _ips = ips;
        _selectedIp = ips.isNotEmpty ? ips.first : null;
        _lastBytesSent = 0;
        _displayBytesSent = 0;
        _currentSpeed = 0.0;
      });

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_server == null) return;
        final currentBytes = _server!.bytesSent;
        final delta = currentBytes - _lastBytesSent;
        _lastBytesSent = currentBytes;
        setState(() {
          _displayBytesSent = currentBytes;
          _currentSpeed = delta.toDouble();
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Impossible de démarrer le serveur : $e';
      });
    }
  }

  Future<void> _changeFile() async {
    _timer?.cancel();
    await _server?.stop();
    setState(() {
      _server = null;
      _mediaRef = null;
      _ips = [];
      _selectedIp = null;
    });
    await _pickAndStart();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Envoyer un film')),
      body: SafeArea(
        child: Center(
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              if (_server == null || _mediaRef == null) ...[
                const Text(
                  'Sélectionnez un film à partager avec un autre appareil situé sur le même réseau.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _pickAndStart,
                  icon: const Icon(Icons.video_file),
                  label: const Text('Choisir le film'),
                ),
              ] else ...[
                Text(
                  _mediaRef!.name,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (_mediaRef!.size != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    formatBytes(_mediaRef!.size!),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                if (_ips.isEmpty) ...[
                  const Text(
                    'Aucune adresse Wi-Fi locale trouvée. Activez le Wi-Fi ou le partage de connexion.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.orange),
                  ),
                ] else ...[
                  if (_ips.length > 1) ...[
                    DropdownButton<String>(
                      value: _selectedIp,
                      isExpanded: true,
                      items: _ips
                          .map(
                            (ip) =>
                                DropdownMenuItem(value: ip, child: Text(ip)),
                          )
                          .toList(),
                      onChanged: (ip) {
                        if (ip != null) {
                          setState(() {
                            _selectedIp = ip;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_selectedIp != null) ...[
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        color: Colors.white,
                        child: QrImageView(
                          data: _server!.linkFor(_selectedIp!).toString(),
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      _server!.linkFor(_selectedIp!).toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                Text(
                  'Envoyé : ${formatBytes(_displayBytesSent)} · ${formatSpeed(_currentSpeed)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Sur l\'autre appareil : « Recevoir un film » dans l\'app, ou scannez le QR code avec l\'appareil photo pour télécharger depuis le navigateur. Les deux appareils doivent être sur le même Wi-Fi (ou le partage de connexion de l\'un d\'eux) ; aucune connexion Internet n\'est utilisée.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: _changeFile,
                  child: const Text('Changer de fichier'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ReceiveFileScreen extends StatefulWidget {
  const ReceiveFileScreen({
    super.key,
    this.link,
    this.directUrl,
    this.fileName,
  });

  final TransferLink? link;
  final Uri? directUrl;
  final String? fileName;

  @override
  State<ReceiveFileScreen> createState() => _ReceiveFileScreenState();
}

class _ReceiveFileScreenState extends State<ReceiveFileScreen> {
  TransferLink? _link;
  Uri? _directUrl;
  String? _fileName;
  int? _fileSize;

  bool _fetchingInfo = false;
  String? _error;

  Downloader? _downloader;
  StreamSubscription<TransferProgress>? _sub;
  TransferProgress? _progress;
  bool _downloading = false;
  bool _paused = false;
  bool _success = false;
  String? _savedLocation;
  String? _cancelMessage;

  final TextEditingController _linkController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _link = widget.link;
    _directUrl = widget.directUrl;
    _fileName = widget.fileName;

    if (_link != null) {
      _fetchInfo();
    } else if (_directUrl != null && _fileName != null) {
      _fileSize = null;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _downloader?.cancel();
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _fetchInfo() async {
    if (_link == null) return;
    setState(() {
      _fetchingInfo = true;
      _error = null;
    });
    try {
      final info = await _link!.fetchInfo();
      if (!mounted) return;
      setState(() {
        _fileName = info.name;
        _fileSize = info.size;
        _fetchingInfo = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            'Appareil injoignable : $e. Vérifiez que les deux appareils sont sur le même Wi-Fi.';
        _fetchingInfo = false;
      });
    }
  }

  void _validateManualLink() {
    final text = _linkController.text.trim();
    final parsed = TransferLink.tryParse(text);
    if (parsed == null) {
      setState(() {
        _error = 'Lien non reconnu.';
      });
      return;
    }
    setState(() {
      _error = null;
      _link = parsed;
    });
    _fetchInfo();
  }

  Future<void> _startDownload() async {
    final url = _link?.fileUri ?? _directUrl;
    final name = _fileName;
    if (url == null || name == null) return;

    setState(() {
      _downloading = true;
      _paused = false;
      _success = false;
      _error = null;
      _cancelMessage = null;
    });

    try {
      final sink = await downloadSinkFor(name);
      if (!mounted) return;
      final downloader = Downloader(url: url, sink: sink);
      _downloader = downloader;
      await _sub?.cancel();
      _sub = downloader.progress.listen((p) {
        if (!mounted) return;
        setState(() {
          _progress = p;
        });
      });

      final location = await downloader.run();
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _success = true;
        _savedLocation = location;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is TransferCancelled) {
        setState(() {
          _downloading = false;
          _paused = true;
          _cancelMessage =
              'Transfert interrompu : il reprendra là où il s\'est arrêté.';
        });
      } else if (e is TransferFailed) {
        setState(() {
          _downloading = false;
          _error = 'Échec du transfert : ${e.message}';
        });
      } else {
        setState(() {
          _downloading = false;
          _error = 'Échec du transfert : $e';
        });
      }
    }
  }

  void _cancelDownload() {
    _downloader?.cancel();
    _sub?.cancel();
    setState(() {
      _downloading = false;
      _paused = true;
      _cancelMessage =
          'Transfert interrompu : il reprendra là où il s\'est arrêté.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final showScanner = Platform.isAndroid || Platform.isIOS;
    final urlReady = _link != null || (_directUrl != null && _fileName != null);

    return Scaffold(
      appBar: AppBar(title: const Text('Recevoir un film')),
      body: SafeArea(
        child: Center(
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              if (!urlReady) ...[
                const Text(
                  'Sur l\'appareil qui envoie, ouvrez « Envoyer un film » puis scannez son QR code, ou collez le lien affiché.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (showScanner) ...[
                  FilledButton.icon(
                    onPressed: () async {
                      final scanned = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QrScanScreen(
                            accept: (v) => TransferLink.tryParse(v) != null,
                            title: 'Scanner le QR code d\'envoi',
                          ),
                        ),
                      );
                      if (scanned != null && mounted) {
                        final parsed = TransferLink.tryParse(scanned);
                        if (parsed != null) {
                          setState(() {
                            _link = parsed;
                            _error = null;
                          });
                          _fetchInfo();
                        } else {
                          setState(() {
                            _error = 'Lien non reconnu.';
                          });
                        }
                      }
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scanner le QR code'),
                  ),
                  const SizedBox(height: 24),
                ],
                TextField(
                  controller: _linkController,
                  decoration: const InputDecoration(
                    labelText: 'Lien (http://…)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _validateManualLink,
                  child: const Text('Valider'),
                ),
              ] else if (_fetchingInfo) ...[
                const Center(child: CircularProgressIndicator()),
              ] else if (_success) ...[
                const Center(
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 64,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Film reçu :',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _savedLocation ?? _fileName ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ] else ...[
                Text(
                  _fileName ?? 'Fichier inconnu',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (_fileSize != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    formatBytes(_fileSize!),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                if (_downloading || _paused) ...[
                  LinearProgressIndicator(value: _progress?.fraction),
                  const SizedBox(height: 16),
                  Text(
                    '${formatBytes(_progress?.received ?? 0)} / ${formatBytes(_progress?.total ?? _fileSize ?? 0)} · ${formatSpeed(_progress?.bytesPerSecond ?? 0.0)} · reste ${formatEta(_progress?.eta)}',
                    textAlign: TextAlign.center,
                  ),
                  if ((_progress?.resumedFrom ?? 0) > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Reprise à ${formatBytes(_progress!.resumedFrom)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.blue),
                    ),
                  ],
                  if (_progress?.retrying == true) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Connexion perdue, nouvelle tentative…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.orange),
                    ),
                  ],
                  if (_cancelMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _cancelMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_downloading)
                    OutlinedButton(
                      onPressed: _cancelDownload,
                      child: const Text('Interrompre'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _startDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Reprendre'),
                    ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: _startDownload,
                    icon: const Icon(Icons.download),
                    label: const Text('Télécharger'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
