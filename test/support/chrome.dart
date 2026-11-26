// Chrome headless piloté via le protocole DevTools (tests de bout en bout des
// pages web des modes 4 et 5).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String? findChrome() {
  for (final c in ['google-chrome', 'chromium', 'chromium-browser']) {
    try {
      if (Process.runSync('which', [c]).exitCode == 0) return c;
    } catch (_) {}
  }
  return null;
}

class ChromePage {
  ChromePage(this._ws) {
    _ws.listen((data) {
      final m = jsonDecode(data as String) as Map<String, dynamic>;
      final id = m['id'];
      if (id is int) _pending.remove(id)?.complete(m);
    });
  }
  final WebSocket _ws;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _id = 0;

  /// Évalue [expr] ; avec [awaitPromise], attend la promesse renvoyée.
  Future<dynamic> eval(String expr, {bool awaitPromise = false}) async {
    final id = ++_id;
    final c = _pending[id] = Completer();
    _ws.add(
      jsonEncode({
        'id': id,
        'method': 'Runtime.evaluate',
        'params': {
          'expression': expr,
          'returnByValue': true,
          if (awaitPromise) 'awaitPromise': true,
        },
      }),
    );
    final r = await c.future.timeout(Duration(seconds: awaitPromise ? 60 : 10));
    return (r['result'] as Map)['result']?['value'];
  }

  Future<void> close() => _ws.close();
}

class HeadlessChrome {
  HeadlessChrome._(this._process, this._dir, this._port);

  final Process _process;
  final Directory _dir;
  final int _port;

  static Future<HeadlessChrome> start(
    String chrome, {
    String? userAgent,
  }) async {
    final dir = await Directory.systemTemp.createTemp('chrome');
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final p = await Process.start(chrome, [
      '--headless=new',
      '--no-sandbox',
      '--disable-gpu',
      '--autoplay-policy=no-user-gesture-required',
      '--remote-debugging-port=$port',
      '--user-data-dir=${dir.path}/profile',
      if (userAgent != null) '--user-agent=$userAgent',
      'about:blank',
    ]);
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    return HeadlessChrome._(p, dir, port);
  }

  Future<ChromePage> open(String url) async {
    final client = HttpClient();
    for (var i = 0; i < 50; i++) {
      try {
        final req = await client.openUrl(
          'PUT',
          Uri.parse(
            'http://127.0.0.1:$_port/json/new?${Uri.encodeComponent(url)}',
          ),
        );
        final res = await req.close();
        final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
        return ChromePage(
          await WebSocket.connect(j['webSocketDebuggerUrl'] as String),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw StateError('Chrome DevTools injoignable');
  }

  Future<void> close() async {
    _process.kill();
    await _process.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _dir.delete(recursive: true).catchError((_) => _dir);
  }
}
