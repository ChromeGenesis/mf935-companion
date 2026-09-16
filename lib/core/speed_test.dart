/// Speed test engine (SSOT): latency, download, upload — cancellable,
/// no cloud SDKs, plain HTTP against Cloudflare's public speedtest
/// endpoints (the same ones speed.cloudflare.com uses).
///
/// Why these endpoints and not the router: the phone routes through
/// the MiFi, so fetching WAN content measures the *carrier* path, not
/// the Wi-Fi link. Probing the gateway IP itself would only time the
/// living-room hop — that number would look great and mean nothing.
///
/// Methodology (distrust single shots):
/// - latency: one warmup probe (TLS + handshake, discarded), then the
///   median of 4 RTTs — not the min, which flatters.
/// - download: cache-busted 128 KiB warmup (discarded), then 2× 512 KiB
///   runs, median reported. Slow-start dominates any single small
///   transfer, so one run is noise.
/// - upload: 2× 128 KiB POSTs with an explicit Content-Length (no
///   chunked guessing), median reported.
/// Every request carries the run's [CancelToken] — cancel actually
/// aborts mid-transfer, not just at phase boundaries.
library;

import 'dart:async';

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
/// ~1.2 MB down (128 KiB warmup + 2× 512 KiB), ~0.25 MB up (2× 128 KiB).
const _warmupDownloadBytes = 128 * 1024;
const _downloadBytes = 512 * 1024; // 512 KiB per measured run
const _uploadBytes = 128 * 1024; // 128 KiB per measured run (mobile-friendly)

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

/// Runs a compact speed test in phases with progress callbacks.
/// Cancel at any point via [cancel] — probes stop at phase boundaries
/// and within long transfers via [Dio] request cancellation.
class SpeedTestRunner {
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
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

  /// Run the full test. Reports every phase transition (and re-reports
  /// download/upload progress as 0..1). Throws nothing: errors come
  /// back as a failed [SpeedTestResult] with whatever phases completed.
  Future<SpeedTestResult> run(
    void Function(SpeedPhase phase, double progress) onPhase,
  ) async {
    _cancel = CancelToken();
    double? latencyMs;
    double? downBps;
    double? upBps;
    try {
      // ── Latency: warmup (handshake cost, discarded) + median of 4.
      onPhase(SpeedPhase.latency, 0);
      await _probeLatency();
      onPhase(SpeedPhase.latency, 1 / 5);
      final rtts = <double>[];
      for (var i = 0; i < 4; i++) {
        rtts.add(await _probeLatency());
        onPhase(SpeedPhase.latency, (i + 2) / 5);
      }
      latencyMs = medianOf(rtts);

      // ── Download: warmup (slow-start, discarded) + median of 2.
      onPhase(SpeedPhase.download, 0);
      await _downloadRun(
        _warmupDownloadBytes,
        (p) => onPhase(SpeedPhase.download, p * 0.2),
      );
      final downs = <double>[];
      downs.add(
        await _downloadRun(
          _downloadBytes,
          (p) => onPhase(SpeedPhase.download, 0.2 + p * 0.4),
        ),
      );
      downs.add(
        await _downloadRun(
          _downloadBytes,
          (p) => onPhase(SpeedPhase.download, 0.6 + p * 0.4),
        ),
      );
      downBps = medianOf(downs);

      // ── Upload: median of 2 explicit-length POSTs.
      onPhase(SpeedPhase.upload, 0);
      final payload = List.filled(_uploadBytes, 65); // 'A'
      final ups = <double>[];
      ups.add(
        await _uploadRun(
          payload,
          (p) => onPhase(SpeedPhase.upload, p * 0.5),
        ),
      );
      ups.add(
        await _uploadRun(
          payload,
          (p) => onPhase(SpeedPhase.upload, 0.5 + p * 0.5),
        ),
      );
      upBps = medianOf(ups);

      onPhase(SpeedPhase.done, 1);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        uploadBps: upBps,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        onPhase(SpeedPhase.cancelled, 0);
        return SpeedTestResult(at: DateTime.now(), error: 'cancelled');
      }
      onPhase(SpeedPhase.failed, 0);
      return SpeedTestResult(
        at: DateTime.now(),
        latencyMs: latencyMs,
        downloadBps: downBps,
        error: 'Network error: ${e.message ?? e.type.name}',
      );
    } catch (e) {
      onPhase(SpeedPhase.failed, 0);
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

  /// One download run: cache-busted fetch of exactly [bytes], returns
  /// measured bytes/sec. Throws on an empty body (proxy answered
  /// without content) so a bogus run never reports.
  Future<double> _downloadRun(
    int bytes,
    void Function(double progress) onProgress,
  ) async {
    final sw = Stopwatch()..start();
    final resp = await _dio.get<List<int>>(
      'https://speed.cloudflare.com/__down',
      queryParameters: {
        'bytes': bytes,
        '_': DateTime.now().millisecondsSinceEpoch,
      },
      cancelToken: _cancel,
      onReceiveProgress: (done, total) {
        if (total > 0) onProgress(done / total);
      },
    );
    sw.stop();
    final got = resp.data?.length ?? 0;
    if (got == 0) throw const FormatException('empty download body');
    return throughputBps(got, sw.elapsedMicroseconds / 1e6);
  }

  /// One upload run: POST [payload] with an explicit Content-Length
  /// (no chunked-transfer guessing), returns measured bytes/sec.
  Future<double> _uploadRun(
    List<int> payload,
    void Function(double progress) onProgress,
  ) async {
    final sw = Stopwatch()..start();
    await _dio.post<void>(
      'https://speed.cloudflare.com/__up',
      data: payload,
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': '${payload.length}',
        },
      ),
      cancelToken: _cancel,
      onSendProgress: (done, total) {
        if (total > 0) onProgress(done / total);
      },
    );
    sw.stop();
    return throughputBps(payload.length, sw.elapsedMicroseconds / 1e6);
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
