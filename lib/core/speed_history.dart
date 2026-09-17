library;

/// Speed-test history (SSOT): every finished run is appended here so
/// incident reports, best-time-of-day and the results list have real
/// data. Persisted as JSON in SharedPreferences, capped at 100
/// entries (newest first). Pure record type + thin store.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'speed_test.dart';

/// One stored run. Mb/s (not B/s) keeps the JSON human-readable.
class SpeedRecord {
  final DateTime at;
  final double? latencyMs;
  final double? jitterMs;
  final double? downMbps;
  final double? upMbps;
  final String server;
  final String provenance;

  const SpeedRecord({
    required this.at,
    this.latencyMs,
    this.jitterMs,
    this.downMbps,
    this.upMbps,
    this.server = '',
    this.provenance = 'ndt7',
  });

  factory SpeedRecord.fromResult(SpeedTestResult r) => SpeedRecord(
    at: r.at,
    latencyMs: r.latencyMs,
    jitterMs: r.jitterMs,
    downMbps: r.downloadBps == null ? null : r.downloadBps! * 8 / 1e6,
    upMbps: r.uploadBps == null ? null : r.uploadBps! * 8 / 1e6,
    server: r.server,
    provenance: r.provenance,
  );

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'latencyMs': latencyMs,
    'jitterMs': jitterMs,
    'downMbps': downMbps,
    'upMbps': upMbps,
    'server': server,
    'provenance': provenance,
  };

  factory SpeedRecord.fromJson(Map<String, dynamic> j) => SpeedRecord(
    at:
        DateTime.tryParse('${j['at']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    latencyMs: (j['latencyMs'] as num?)?.toDouble(),
    jitterMs: (j['jitterMs'] as num?)?.toDouble(),
    downMbps: (j['downMbps'] as num?)?.toDouble(),
    upMbps: (j['upMbps'] as num?)?.toDouble(),
    server: '${j['server'] ?? ''}',
    provenance: '${j['provenance'] ?? 'ndt7'}',
  );
}

/// Append-only store, newest first, hard cap so history cannot grow
/// forever (Phase 3 retention rule applied early).
class SpeedHistory {
  static const key = 'speed_history_v1';
  static const maxEntries = 100;

  final List<SpeedRecord> records;

  const SpeedHistory([this.records = const []]);

  /// Parse stored JSON. Never throws: corrupt entries are skipped.
  /// Pure + tested.
  factory SpeedHistory.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const SpeedHistory();
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const SpeedHistory();
      final recs = <SpeedRecord>[];
      for (final e in list) {
        if (e is Map) {
          try {
            recs.add(
              SpeedRecord.fromJson(Map<String, dynamic>.from(e)),
            );
          } catch (_) {
            // One bad row must not kill the whole history.
          }
        }
      }
      return SpeedHistory(recs.take(maxEntries).toList());
    } catch (_) {
      return const SpeedHistory();
    }
  }

  String encode() => jsonEncode(records.map((r) => r.toJson()).toList());

  /// Newest-first insert with cap. Pure + tested.
  SpeedHistory added(SpeedRecord r) =>
      SpeedHistory([r, ...records].take(maxEntries).toList());

  static Future<SpeedHistory> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SpeedHistory.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, encode());
  }
}
