/// Speed test engine (SSOT): latency, download, upload — cancellable.
/// Primary path is M-Lab ndt7 (see `ndt7_client.dart`): sustained ~10 s
/// transfers in each direction, the same standardized test behind
/// Google's "internet speed test". Fixed-size HTTP fetches against
/// Cloudflare remain only as the Quick mode / offline fallback — a
/// fixed byte count finishes inside TCP slow-start on fast links and
/// reads low, which is why the old default numbers couldn't be
/// trusted.
///
/// Why measure the WAN path and not the router: the phone routes
/// through the MiFi, so fetching internet content measures the
/// *carrier* path, not the Wi-Fi link. Probing the gateway IP itself
/// would only time the living-room hop — that number would look
/// great and mean nothing.
///
/// Methodology (Full / ndt7):
/// - server discovery via the public M-Lab Locate API (nearest
///   healthy server, first reachable result wins);
/// - download: server streams at line rate ~10 s, client goodput;
/// - upload: client streams 8 KiB messages ~10 s, server TCP_INFO
///   counters cross-check when available, client goodput otherwise;
/// - latency: minimum RTT across both phases' TCP_INFO (BBR MinRTT),
///   with HTTP-probe fallback when the server sends none.
/// Every request/socket carries cancellation — cancel aborts
/// mid-transfer, not just at phase boundaries.
library;

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import 'ndt7_client.dart';

/// Progress phases of a test run.
enum SpeedPhase { idle, latency, download, upload, done, failed, cancelled }

/// Which backend a run uses.
enum SpeedTestMode {
  /// M-Lab ndt7 sustained test (~10 s each way, most truthful).
  full,

  /// Fixed-size Cloudflare fetches (~10 MB, quick sanity check).
  quick,

  /// Latency only: 12 RTT probes + jitter, no bulk transfer.
  latency,
}

/// One finished (or failed/cancelled) speed test result.
class SpeedTestResult {
  final DateTime at;
  final double? latencyMs;

  /// Mean absolute deviation of the latency probes, ms. Set by
  /// latency-mode runs; null otherwise.
  final double? jitterMs;
  final double? downloadBps;
  final double? uploadBps;

  /// Where the number came from: e.g. `M-Lab · Lagos, NG` or
  /// `Cloudflare fallback`. Shown under the results — a speed number
  /// without a named server is not a measurement.
  final String server;

  /// `ndt7` or `cloudflare`.
  final String provenance;
  final String? error;

  const SpeedTestResult({
    required this.at,
    this.latencyMs,
    this.jitterMs,
    this.downloadBps,
    this.uploadBps,
    this.server = '',
    this.provenance = 'ndt7',
    this.error,
  });
}

/// Payload sizes for the QUICK-engine throughput probes only (the
/// Full engine is time-based, not size-based). Totals per quick run:
/// ~8.5 MB down (256 KiB warmup + 2 batches of 4× 1 MiB),
/// ~1.1 MB up (128 KiB warmup + 2 batches of 2× 256 KiB).
const _warmupDownloadBytes = 256 * 1024;
const _batchConnsDown = 4;
const _batchBytesDown = 1024 * 1024; // 1 MiB per stream
const _warmupUploadBytes = 128 * 1024;
const _batchConnsUp = 2;
const _batchBytesUp = 256 * 1024;
const _batches = 2;

/// Median of a non-empty sample (sorted middle / mean of two middles).
/// Pure + tested — every reported number in a run goes through this.
double medianOf(List<double> xs) {
  if (xs.isEmpty) throw ArgumentError('medianOf: empty sample');
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// Bytes transferred over elapsed seconds → bytes/sec. Zero/negative
/// elapsed (clock glitch) yields 0, never infinity. Pure + tested.
double throughputBps(int bytes, double elapsedSeconds) {
  if (elapsedSeconds <= 0) return 0;
  return bytes / elapsedSeconds;
}

/// Aggregate throughput of one parallel batch: summed stream bytes
/// over the shared wall-clock. Pure + tested.
double batchThroughputBps(List<int> connBytes, double wallSeconds) =>
    throughputBps(connBytes.fold<int>(0, (a, b) => a + b), wallSeconds);

/// Runs a speed test in phases with progress callbacks.
/// Cancel at any point via [cancel] — probes stop at phase boundaries
/// and within long transfers via request/socket cancellation.
class SpeedTestRunner {
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      // Parallel MiB-scale batches on slow links need room; the user
      // can always cancel, which aborts mid-transfer via the token.
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 60),
      responseType: ResponseType.bytes,
    ),
  );
  CancelToken? _cancel;
  Ndt7Runner? _ndt7;

  bool get running => _cancel != null && !_cancel!.isCancelled;

  /// Human-readable phase label for the UI.
  static String phaseLabel(SpeedPhase p) => switch (p) {
    SpeedPhase.idle => 'Ready',
    SpeedPhase.latency => 'Measuring latency…',
    SpeedPhase.download => 'Measuring download…',
    SpeedPhase.upload => 'Measuring upload…',
    SpeedPhase.done => 'Done',
    SpeedPhase.failed => 'Failed',
    SpeedPhase.cancelled => 'Cancelled',
  };

  /// Human-readable test-mode label for the mode selector.
  static String modeLabel(SpeedTestMode m) => switch (m) {
    SpeedTestMode.full => 'Full · M-Lab',
    SpeedTestMode.quick => 'Quick · ~10 MB',
    SpeedTestMode.latency => 'Latency only',
  };

  /// One-line explainer per mode, shown under the selector.
  static String modeHint(SpeedTestMode m) => switch (m) {
    SpeedTestMode.full =>
      'Sustained ~10 s each way on M-Lab servers — the truthful number. '
      'Uses real data: tens of MB on fast links.',
    SpeedTestMode.quick =>
      'Fixed-size fetches, ~10 MB total. Fast and cheap, reads low on '
      'fast links — a sanity check, not a measurement.',
    SpeedTestMode.latency =>
      'Twelve tiny probes, no bulk transfer. For gaming / jitter checks.',
  };

  /// Mean absolute deviation from the median, ms. Jitter for
  /// latency-mode runs. Pure + tested.
  static double jitterOf(List<double> rtts) {
    if (rtts.isEmpty) throw ArgumentError('jitterOf: empty sample');
    final med = medianOf(rtts);
    return rtts.fold<double>(0, (a, x) => a + (x - med).abs()) / rtts.length;
  }

  /// Run a test in [mode]. Reports every phase transition, re-reports
  /// download/upload progress as 0..1, and streams the live aggregate
  /// rate (bytes/sec, null outside transfers) so the UI meter can
  /// sweep in real time. Throws nothing: errors come back as a failed
  /// [SpeedTestResult] with whatever phases completed. Full mode falls
  /// back to the Cloudflare engine when no M-Lab server answers, and
  /// says so in [SpeedTestResult.provenance].
  Future<SpeedTestResult> run(
    void Function(SpeedPhase phase, double progress, double? liveBps) onPhase, {
    SpeedTestMode mode = SpeedTestMode.full,
  }) async {
    if (mode == SpeedTestMode.latency) return _runLatencyOnly(onPhase);
    if (mode == SpeedTestMode.quick) return _runCloudflare(onPhase);
    try {
      return await _runNdt7(onPhase);
    } catch (e) {
      if (_isCancel(e)) {
        onPhase(SpeedPhase.cancelled, 0, null);
        return SpeedTestResult(at: DateTime.now(), error: 'cancelled');
      }
      // M-Lab unreachable (carrier blocks websockets, no nearby
      // server…) — the quick engine still answers *something*.
      return await _runCloudflare(
        onPhase,
        note: 'M-Lab unreachable ($e) — Cloudflare fallback',
      );
    }
  }

  /// Latency-only run: warmup + 12 sequential RTT probes, median +
  /// jitter. No bulk transfer — the gaming-mode / "is it the link?"
  /// check. Pure HTTP so it works wherever the quick engine works.
  Future<SpeedTestResult> _runLatencyOnly(
    void Function(SpeedPhase phase, double progress, double? liveBps) onPhase,
  ) async {
    _cancel = CancelToken();
    try {
      onPhase(SpeedPhase.latency, 0, null);
      await _probeLatency();
      final rtts = <double>[];
      for (var i = 0; i < 12; i++) {
        rtts.add(await _probeLatency());
        onPhase(SpeedPhase.latency, (i + 1) / 12, null);
      }
      onPhase(SpeedPhase.done, 1, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: medianOf(rtts),
        jitterMs: jitterOf(rtts),
        server: 'Cloudflare edge',
        provenance: 'cloudflare',
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        onPhase(SpeedPhase.cancelled, 0, null);
        return SpeedTestResult(at: DateTime.now(), error: 'cancelled');
      }
      onPhase(SpeedPhase.failed, 0, null);
      return SpeedTestResult(
        at: DateTime.now(),
        error: 'Network error: ${e.message ?? e.type.name}',
      );
    } catch (e) {
      onPhase(SpeedPhase.failed, 0, null);
      return SpeedTestResult(at: DateTime.now(), error: '$e');
    } finally {
      _cancel = null;
    }
  }

  /// Full sustained test against the first reachable M-Lab server.
  Future<SpeedTestResult> _runNdt7(
    void Function(SpeedPhase phase, double progress, double? liveBps) onPhase,
  ) async {
    _ndt7 = Ndt7Runner();
    double? latencyMs;
    try {
      onPhase(SpeedPhase.latency, 0, null); // locating server
      final res = await _ndt7!.runFull(
        onDownload: (p, live) =>
            onPhase(SpeedPhase.download, p, live),
        onUpload: (p, live) =>
            onPhase(SpeedPhase.upload, p, live),
      );
      // Latency = best MinRTT across both phases' TCP_INFO.
      final rtts = <int>[
        ...res.down.minRttUsSamples,
        ...res.up.minRttUsSamples,
      ];
      if (rtts.isNotEmpty) {
        latencyMs = rtts.reduce(min) / 1000;
      } else {
        // Server sent no TCP_INFO: small HTTP probe fallback so the
        // result still carries a latency.
        _cancel = CancelToken();
        final probes = <double>[];
        await _probeLatency();
        for (var i = 0; i < 4; i++) {
          probes.add(await _probeLatency());
        }
        latencyMs = medianOf(probes);
        _cancel = null;
      }
      final upBps = res.up.serverBps > 0
          ? res.up.serverBps
          : res.up.clientBps;
      onPhase(SpeedPhase.done, 1, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: res.down.clientBps,
        uploadBps: upBps,
        server: 'M-Lab · ${res.server.label}',
        provenance: 'ndt7',
      );
    } finally {
      _ndt7?.dispose();
      _ndt7 = null;
      _cancel = null;
    }
  }

  bool _isCancel(Object e) =>
      e is FormatException && e.message == 'cancelled';

  /// Quick fixed-size engine (fallback + Quick mode): warmup, then
  /// peak-of-batches over parallel streams. Kept deliberately small
  /// (~10 MB) — reads low on fast links, which is exactly why it is
  /// no longer the default.
  Future<SpeedTestResult> _runCloudflare(
    void Function(SpeedPhase phase, double progress, double? liveBps) onPhase, {
    String note = '',
  }) async {
    _cancel = CancelToken();
    double? latencyMs;
    double? downBps;
    double? upBps;
    try {
      // ── Latency: warmup (handshake cost, discarded) + median of 4.
      onPhase(SpeedPhase.latency, 0, null);
      await _probeLatency();
      onPhase(SpeedPhase.latency, 1 / 5, null);
      final rtts = <double>[];
      for (var i = 0; i < 4; i++) {
        rtts.add(await _probeLatency());
        onPhase(SpeedPhase.latency, (i + 2) / 5, null);
      }
      latencyMs = medianOf(rtts);

      // ── Download: warmup (slow-start, discarded) + peak of 2
      // parallel batches.
      onPhase(SpeedPhase.download, 0, null);
      await _downloadConn(_warmupDownloadBytes, 0, (_, _) {});
      onPhase(SpeedPhase.download, 0.05, null);
      final downs = <double>[];
      for (var b = 0; b < _batches; b++) {
        downs.add(
          await _parallelDown(
            conns: _batchConnsDown,
            bytesEach: _batchBytesDown,
            salt: b,
            onProgress: (p, live) => onPhase(
              SpeedPhase.download,
              0.05 + ((b + p) / _batches) * 0.95,
              live,
            ),
          ),
        );
      }
      downBps = downs.reduce(max);

      // ── Upload: warmup + peak of 2 parallel batches, explicit
      // Content-Length on every POST.
      onPhase(SpeedPhase.upload, 0, null);
      final payload = List.filled(_batchBytesUp, 65); // 'A'
      await _uploadConn(List.filled(_warmupUploadBytes, 65), -1, (_, _) {});
      onPhase(SpeedPhase.upload, 0.05, null);
      final ups = <double>[];
      for (var b = 0; b < _batches; b++) {
        ups.add(
          await _parallelUp(
            conns: _batchConnsUp,
            payload: payload,
            salt: b,
            onProgress: (p, live) => onPhase(
              SpeedPhase.upload,
              0.05 + ((b + p) / _batches) * 0.95,
              live,
            ),
          ),
        );
      }
      upBps = ups.reduce(max);

      onPhase(SpeedPhase.done, 1, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        uploadBps: upBps,
        server: note.isEmpty ? 'Cloudflare edge' : 'Cloudflare edge · $note',
        provenance: 'cloudflare',
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        onPhase(SpeedPhase.cancelled, 0, null);
        return SpeedTestResult(at: DateTime.now(), error: 'cancelled');
      }
      onPhase(SpeedPhase.failed, 0, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        server: 'Cloudflare edge',
        provenance: 'cloudflare',
        error: 'Network error: ${e.message ?? e.type.name}',
      );
    } catch (e) {
      onPhase(SpeedPhase.failed, 0, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        uploadBps: upBps,
        server: 'Cloudflare edge',
        provenance: 'cloudflare',
        error: '$e',
      );
    } finally {
      _cancel = null;
    }
  }

  /// One latency probe: cache-busted 204 round-trip in ms.
  Future<double> _probeLatency() async {
    final sw = Stopwatch()..start();
    await _dio.get<String>(
      'https://cp.cloudflare.com/generate_204',
      options: Options(responseType: ResponseType.plain),
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
      cancelToken: _cancel,
    );
    sw.stop();
    return sw.elapsedMicroseconds / 1000;
  }

  /// One parallel download batch: [conns] concurrent streams of
  /// [bytesEach], returns summed bytes over shared wall-clock.
  /// Progress aggregates across streams and carries the live aggregate
  /// rate so the UI meter sweeps in real time.
  Future<double> _parallelDown({
    required int conns,
    required int bytesEach,
    required int salt,
    required void Function(double progress, double liveBps) onProgress,
  }) async {
    final done = List<int>.filled(conns, 0);
    final totals = List<int>.filled(conns, bytesEach);
    final sw = Stopwatch()..start();
    double elapsed() => sw.elapsedMicroseconds / 1e6;
    void report() {
      final t = totals.fold<int>(0, (a, b) => a + b);
      if (t > 0) {
        final d = done.fold<int>(0, (a, b) => a + b);
        onProgress(d / t, throughputBps(d, elapsed()));
      }
    }

    final results = await Future.wait<int>([
      for (var i = 0; i < conns; i++)
        _downloadConn(bytesEach, salt * 97 + i, (d, t) {
          done[i] = d;
          if (t > 0) totals[i] = t;
          report();
        }),
    ]);
    sw.stop();
    return batchThroughputBps(results, sw.elapsedMicroseconds / 1e6);
  }

  /// One download stream: cache-busted fetch of exactly [bytes].
  /// Throws on an empty body (proxy answered without content) so a
  /// bogus stream never reports.
  Future<int> _downloadConn(
    int bytes,
    int salt,
    void Function(int done, int total) onChunk,
  ) async {
    final resp = await _dio.get<List<int>>(
      'https://speed.cloudflare.com/__down',
      queryParameters: {
        'bytes': bytes,
        '_': '${DateTime.now().millisecondsSinceEpoch}$salt',
      },
      cancelToken: _cancel,
      onReceiveProgress: (d, t) => onChunk(d, t),
    );
    final got = resp.data?.length ?? 0;
    if (got == 0) throw const FormatException('empty download body');
    return got;
  }

  /// One parallel upload batch: [conns] concurrent POSTs of [payload].
  Future<double> _parallelUp({
    required int conns,
    required List<int> payload,
    required int salt,
    required void Function(double progress, double liveBps) onProgress,
  }) async {
    final done = List<int>.filled(conns, 0);
    final sw = Stopwatch()..start();
    double elapsed() => sw.elapsedMicroseconds / 1e6;
    void report() {
      final t = payload.length * conns;
      final d = done.fold<int>(0, (a, b) => a + b);
      onProgress(d / t, throughputBps(d, elapsed()));
    }

    await Future.wait<void>([
      for (var i = 0; i < conns; i++)
        _uploadConn(payload, salt * 97 + i, (d, _) {
          done[i] = d;
          report();
        }),
    ]);
    sw.stop();
    return batchThroughputBps(
      List.filled(conns, payload.length),
      sw.elapsedMicroseconds / 1e6,
    );
  }

  /// One upload stream: POST [payload] with an explicit Content-Length
  /// (no chunked-transfer guessing). Returns bytes sent.
  Future<int> _uploadConn(
    List<int> payload,
    int salt,
    void Function(int done, int total) onChunk,
  ) async {
    await _dio.post<void>(
      'https://speed.cloudflare.com/__up',
      data: payload,
      queryParameters: {'_': '${DateTime.now().millisecondsSinceEpoch}$salt'},
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': '${payload.length}',
        },
      ),
      cancelToken: _cancel,
      onSendProgress: (d, t) => onChunk(d, t),
    );
    return payload.length;
  }

  /// Cancel the in-flight test (no-op when idle).
  void cancel() {
    _cancel?.cancel();
    _cancel = null;
    _ndt7?.cancel();
  }

  void dispose() {
    cancel();
    _dio.close();
  }
}
