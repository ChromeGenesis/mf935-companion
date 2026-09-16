/// Speed test engine (SSOT): latency, download, upload — cancellable,
/// no cloud SDKs, plain HTTP against Cloudflare's public speedtest
/// endpoints (the same ones speed.cloudflare.com uses).
///
/// Why these endpoints and not the router: the phone routes through
/// the MiFi, so fetching WAN content measures the *carrier* path, not
/// the Wi-Fi link. Probing the gateway IP itself would only time the
/// living-room hop — that number would look great and mean nothing.
///
/// Why parallel streams (fast.com parity): one TCP stream on a
/// high-latency mobile link cannot fill the pipe — the
/// bandwidth-delay product caps it — and slow-start eats short
/// transfers whole. fast.com opens many concurrent streams for many
/// seconds for exactly this reason; a single 512 KiB fetch will
/// always read ~2-3× low. So throughput runs N parallel streams and
/// reports the peak sustained batch, while latency (where parallelism
/// would lie) stays a median of sequential probes.
///
/// Methodology:
/// - latency: one warmup probe (TLS + handshake, discarded), then the
///   median of 4 sequential RTTs.
/// - download: 256 KiB warmup (discarded), then 2 batches of
///   4× 1 MiB parallel streams; peak batch reported.
/// - upload: 128 KiB warmup, then 2 batches of 2× 256 KiB parallel
///   POSTs with explicit Content-Length; peak batch reported.
/// Every request carries the run's [CancelToken] — cancel actually
/// aborts mid-transfer, not just at phase boundaries.
library;

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

/// Progress phases of a test run.
enum SpeedPhase { idle, latency, download, upload, done, failed, cancelled }

/// One finished (or failed/cancelled) speed test result.
class SpeedTestResult {
  final DateTime at;
  final double? latencyMs;
  final double? downloadBps;
  final double? uploadBps;
  final String? error;

  const SpeedTestResult({
    required this.at,
    this.latencyMs,
    this.downloadBps,
    this.uploadBps,
    this.error,
  });
}

/// Payload sizes for the throughput probes. Totals per run:
/// ~8.5 MB down (256 KiB warmup + 2 batches of 4× 1 MiB),
/// ~1.1 MB up (128 KiB warmup + 2 batches of 2× 256 KiB).
/// A fast.com-class number costs fast.com-class bytes — the consent
/// dialog states this plainly before the first run.
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

/// Runs a compact speed test in phases with progress callbacks.
/// Cancel at any point via [cancel] — probes stop at phase boundaries
/// and within long transfers via [Dio] request cancellation.
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

  /// Run the full test. Reports every phase transition, re-reports
  /// download/upload progress as 0..1, and streams the live aggregate
  /// rate (bytes/sec across streams, null outside transfers) so the UI
  /// meter can sweep in real time. Throws nothing: errors come back as
  /// a failed [SpeedTestResult] with whatever phases completed.
  Future<SpeedTestResult> run(
    void Function(SpeedPhase phase, double progress, double? liveBps) onPhase,
  ) async {
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
        error: 'Network error: ${e.message ?? e.type.name}',
      );
    } catch (e) {
      onPhase(SpeedPhase.failed, 0, null);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        uploadBps: upBps,
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
  }

  void dispose() {
    cancel();
    _dio.close();
  }
}
