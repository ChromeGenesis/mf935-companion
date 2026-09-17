library;

/// M-Lab ndt7 speed-test client (SSOT for accurate throughput).
///
/// Why this replaces fixed-size HTTP fetches: a fixed ~8 MB download
/// finishes inside TCP slow-start on a fast link and reads 2-3x low,
/// while on a slow link the same bytes take forever. ndt7 — the same
/// protocol behind Google's "internet speed test" — measures
/// *sustained* throughput instead: the server streams as fast as the
/// path allows for ~10 s (download), then the client does the same in
/// reverse (upload). The number is bytes-on-the-wire over wall-clock,
/// with server-side TCP_INFO cross-checking the upload. No API key,
/// no account: server discovery goes through M-Lab's public Locate
/// API, which hands out access-token URLs.
///
/// Data cost is honest: ~10 s at line rate each way. A 50 Mbps link
/// moves ~60 MB down. The consent dialog says so.
///
/// Protocol reference: m-lab/ndt-server `spec/ndt7-protocol.md`
/// (subprotocol `net.measurementlab.ndt.v7`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// WebSocket subprotocol the ndt7 server requires.
const ndt7Subprotocol = 'net.measurementlab.ndt.v7';

/// How long each direction runs. Download is server-driven (~10 s);
/// upload is client-driven and we stop here.
const ndt7TestDuration = Duration(seconds: 10);

/// Hard ceiling per direction so a hung socket can never hang the UI.
const ndt7PhaseTimeout = Duration(seconds: 25);

/// Upload message size. 8 KiB keeps each `add` cheap while the send
/// loop yields often enough to process server measurements.
const ndt7UploadMessageBytes = 8 * 1024;

/// One Locate API result: complete, token-bearing test URLs.
class Ndt7Server {
  final String machine;
  final String city;
  final String country;
  final String downloadUrl;
  final String uploadUrl;

  const Ndt7Server({
    required this.machine,
    required this.city,
    required this.country,
    required this.downloadUrl,
    required this.uploadUrl,
  });

  String get label => city.isEmpty ? machine : '$city, $country';
}

/// Pick usable test servers from a Locate v2 response. Pure + tested:
/// prefers `wss` URLs, skips results missing either direction, never
/// throws on malformed JSON (returns empty).
List<Ndt7Server> selectNdt7Servers(dynamic locateJson) {
  final out = <Ndt7Server>[];
  final results = locateJson is Map ? locateJson['results'] : null;
  if (results is! List) return out;
  for (final r in results) {
    if (r is! Map) continue;
    final urls = r['urls'];
    if (urls is! Map) continue;
    final down =
        '${urls['wss:///ndt/v7/download'] ?? urls['ws:///ndt/v7/download'] ?? ''}';
    final up =
        '${urls['wss:///ndt/v7/upload'] ?? urls['ws:///ndt/v7/upload'] ?? ''}';
    if (down.isEmpty || up.isEmpty) continue;
    final loc = r['location'];
    out.add(
      Ndt7Server(
        machine: '${r['machine'] ?? ''}',
        city: loc is Map ? '${loc['city'] ?? ''}' : '',
        country: loc is Map ? '${loc['country'] ?? ''}' : '',
        downloadUrl: down,
        uploadUrl: up,
      ),
    );
  }
  return out;
}

/// One server-side measurement: TCP_INFO snapshot carried in a text
/// message during either direction.
class Ndt7ServerMeasurement {
  /// Total bytes the server's TCP stack has received (upload) or sent.
  final int tcpBytes;
  /// Socket lifetime in microseconds at measurement time.
  final int tcpElapsedUs;
  /// Minimum RTT seen, microseconds. -1/null when unknown.
  final int? minRttUs;

  const Ndt7ServerMeasurement({
    required this.tcpBytes,
    required this.tcpElapsedUs,
    this.minRttUs,
  });
}

/// Parse one ndt7 text message into a measurement. Returns null for
/// AppInfo messages and anything malformed. Pure + tested.
Ndt7ServerMeasurement? parseNdt7Measurement(String text) {
  dynamic j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (j is! Map) return null;
  final tcp = j['TCPInfo'];
  if (tcp is! Map) return null;
  final bytes = (tcp['BytesReceived'] as num?)?.toInt();
  final elapsed = (tcp['ElapsedTime'] as num?)?.toInt();
  if (bytes == null || elapsed == null) return null;
  final rtt = (tcp['MinRTT'] as num?)?.toInt();
  return Ndt7ServerMeasurement(
    tcpBytes: bytes,
    tcpElapsedUs: elapsed,
    minRttUs: (rtt == null || rtt < 0) ? null : rtt,
  );
}

/// Upload throughput from the server's authoritative counters: delta
/// of bytes received over delta of socket time. Falls back to 0 when
/// the server sent fewer than two usable snapshots. Pure + tested.
double ndt7UploadThroughputBps(
  List<Ndt7ServerMeasurement> snapshots,
) {
  if (snapshots.length < 2) return 0;
  final first = snapshots.first;
  final last = snapshots.last;
  final dBytes = last.tcpBytes - first.tcpBytes;
  final dUs = last.tcpElapsedUs - first.tcpElapsedUs;
  if (dBytes <= 0 || dUs <= 0) return 0;
  return dBytes / (dUs / 1e6);
}

/// Client-side goodput: bytes observed over first-to-last-message
/// window. Pure + tested.
double ndt7ClientThroughputBps(int bytes, int firstUs, int lastUs) {
  final dUs = lastUs - firstUs;
  if (bytes <= 0 || dUs <= 0) return 0;
  return bytes / (dUs / 1e6);
}

/// Outcome of one direction of an ndt7 test.
class Ndt7DirectionResult {
  /// Client-measured goodput, bytes/sec.
  final double clientBps;

  /// Server-cross-checked throughput (upload only, 0 when unavailable).
  final double serverBps;
  final List<int> minRttUsSamples;

  const Ndt7DirectionResult({
    required this.clientBps,
    this.serverBps = 0,
    this.minRttUsSamples = const [],
  });
}

/// ndt7 protocol runner. One instance per test; cancel via [cancel].
class Ndt7Runner {
  final Dio _dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 8)),
  );
  final _rand = Random();
  bool _cancelled = false;
  WebSocket? _socket;

  void cancel() {
    _cancelled = true;
    _socket?.close();
    _socket = null;
  }

  void dispose() {
    cancel();
    _dio.close();
  }

  /// Discover nearby test servers via the public Locate API.
  Future<List<Ndt7Server>> locate() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      'https://locate.measurementlab.net/v2/nearest/ndt/ndt7',
      queryParameters: {
        'client_name': 'mifi-companion',
        'client_version': '1.0.0',
      },
    );
    return selectNdt7Servers(resp.data);
  }

  /// Full test against the first reachable server: download then
  /// upload, ~10 s each. Throws when no server answers.
  Future<({Ndt7DirectionResult down, Ndt7DirectionResult up, Ndt7Server server})>
  runFull({
    required void Function(double progress, double liveBps) onDownload,
    required void Function(double progress, double liveBps) onUpload,
  }) async {
    final servers = await locate();
    if (servers.isEmpty) {
      throw const FormatException('Locate returned no test servers');
    }
    Object? lastError;
    for (final s in servers) {
      if (_cancelled) throw _cancelledError();
      try {
        final down = await _download(s, onDownload);
        if (_cancelled) throw _cancelledError();
        final up = await _upload(s, onUpload);
        return (down: down, up: up, server: s);
      } catch (e) {
        lastError = e;
        if (_isCancel(e)) rethrow;
        // Try the next Locate result — one saturated machine must not
        // fail the whole test.
      }
    }
    throw lastError ?? const FormatException('No ndt7 server answered');
  }

  Future<Ndt7DirectionResult> _download(
    Ndt7Server server,
    void Function(double progress, double liveBps) onProgress,
  ) async {
    final ws = await _connect(server.downloadUrl);
    var bytes = 0;
    var firstUs = 0;
    var lastUs = 0;
    final rtts = <int>[];
    final sw = Stopwatch()..start();
    final sub = ws.listen((msg) {
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      if (msg is Uint8List) {
        if (firstUs == 0) firstUs = nowUs;
        lastUs = nowUs;
        bytes += msg.length;
      } else if (msg is String) {
        final m = parseNdt7Measurement(msg);
        if (m?.minRttUs != null) rtts.add(m!.minRttUs!);
      } else if (msg is List<int>) {
        if (firstUs == 0) firstUs = nowUs;
        lastUs = nowUs;
        bytes += msg.length;
      }
      final elapsed = sw.elapsedMicroseconds / 1e6;
      onProgress(
        (elapsed / ndt7TestDuration.inSeconds).clamp(0.0, 1.0),
        ndt7ClientThroughputBps(bytes, firstUs, nowUs),
      );
    });
    try {
      // The server streams for ~10 s, then closes: `done` IS the finish
      // line. The timeout only guards a hung socket.
      await ws.done.timeout(ndt7PhaseTimeout);
    } on TimeoutException {
      await ws.close();
    } finally {
      await sub.cancel();
    }
    sw.stop();
    return Ndt7DirectionResult(
      clientBps: ndt7ClientThroughputBps(bytes, firstUs, lastUs),
      minRttUsSamples: rtts,
    );
  }

  Future<Ndt7DirectionResult> _upload(
    Ndt7Server server,
    void Function(double progress, double liveBps) onProgress,
  ) async {
    final ws = await _connect(server.uploadUrl);
    final snapshots = <Ndt7ServerMeasurement>[];
    final sub = ws.listen((msg) {
      if (msg is String) {
        final m = parseNdt7Measurement(msg);
        if (m != null) snapshots.add(m);
      }
    });
    final payload = Uint8List.fromList(
      List<int>.generate(ndt7UploadMessageBytes, (_) => _rand.nextInt(256)),
    );
    var sent = 0;
    final firstUs = DateTime.now().microsecondsSinceEpoch;
    var lastUs = firstUs;
    final sw = Stopwatch()..start();
    try {
      while (sw.elapsed < ndt7TestDuration && !_cancelled) {
        // Burst, then yield so incoming server measurements are
        // processed instead of starving the event loop.
        for (var i = 0; i < 32; i++) {
          ws.add(payload);
          sent += payload.length;
        }
        lastUs = DateTime.now().microsecondsSinceEpoch;
        final elapsed = sw.elapsedMicroseconds / 1e6;
        onProgress(
          (elapsed / ndt7TestDuration.inSeconds).clamp(0.0, 1.0),
          ndt7ClientThroughputBps(sent, firstUs, lastUs),
        );
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await ws.close();
      try {
        await ws.done.timeout(const Duration(seconds: 5));
      } catch (_) {
        // Server may already be gone — snapshots are what matter.
      }
      await sub.cancel();
    }
    sw.stop();
    if (_cancelled) throw _cancelledError();
    final serverBps = ndt7UploadThroughputBps(snapshots);
    final rtts = [
      for (final s in snapshots)
        if (s.minRttUs != null) s.minRttUs!,
    ];
    return Ndt7DirectionResult(
      clientBps: ndt7ClientThroughputBps(sent, firstUs, lastUs),
      serverBps: serverBps,
      minRttUsSamples: rtts,
    );
  }

  Future<WebSocket> _connect(String url) async {
    final ws = await WebSocket.connect(
      url,
      protocols: [ndt7Subprotocol],
    ).timeout(const Duration(seconds: 10));
    _socket = ws;
    return ws;
  }

  Never _cancelledError() =>
      throw const FormatException('cancelled');

  bool _isCancel(Object e) =>
      e is FormatException && e.message == 'cancelled';
}
