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

  /// User label ("bedroom", "before the antenna move") so two runs can be
  /// compared later. Empty when unlabelled.
  final String label;

  /// Radio conditions at the start and end of the run. A throughput
  /// number without them is not comparable: 40 Mbps at -95 dBm and 40
  /// Mbps at -70 dBm are different facts, and a run that started strong
  /// and ended weak is a finding in itself.
  final int? rsrpStart;
  final int? rsrpEnd;
  final String netStart;
  final String netEnd;

  const SpeedRecord({
    required this.at,
    this.latencyMs,
    this.jitterMs,
    this.downMbps,
    this.upMbps,
    this.server = '',
    this.provenance = 'ndt7',
    this.label = '',
    this.rsrpStart,
    this.rsrpEnd,
    this.netStart = '',
    this.netEnd = '',
  });

  factory SpeedRecord.fromResult(
    SpeedTestResult r, {
    String label = '',
    int? rsrpStart,
    int? rsrpEnd,
    String netStart = '',
    String netEnd = '',
  }) => SpeedRecord(
    at: r.at,
    latencyMs: r.latencyMs,
    jitterMs: r.jitterMs,
    downMbps: r.downloadBps == null ? null : r.downloadBps! * 8 / 1e6,
    upMbps: r.uploadBps == null ? null : r.uploadBps! * 8 / 1e6,
    server: r.server,
    provenance: r.provenance,
    label: label,
    rsrpStart: rsrpStart,
    rsrpEnd: rsrpEnd,
    netStart: netStart,
    netEnd: netEnd,
  );

  /// Copy with a new label (renaming a stored run).
  SpeedRecord withLabel(String value) => SpeedRecord(
    at: at,
    latencyMs: latencyMs,
    jitterMs: jitterMs,
    downMbps: downMbps,
    upMbps: upMbps,
    server: server,
    provenance: provenance,
    label: value,
    rsrpStart: rsrpStart,
    rsrpEnd: rsrpEnd,
    netStart: netStart,
    netEnd: netEnd,
  );

  /// True when the run carried signal evidence at either end.
  bool get hasSignal => rsrpStart != null || rsrpEnd != null;

  /// `LTE -86 -> -92 dBm` (start -> end), or '' when nothing was captured.
  String get signalLine {
    final parts = <String>[];
    if (netStart.isNotEmpty || netEnd.isNotEmpty) {
      parts.add(netStart.isEmpty ? netEnd : netStart);
    }
    if (rsrpStart != null || rsrpEnd != null) {
      final a = rsrpStart?.toString() ?? '?';
      final b = rsrpEnd?.toString() ?? '?';
      parts.add(a == b ? '$a dBm' : '$a → $b dBm');
    }
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'latencyMs': latencyMs,
    'jitterMs': jitterMs,
    'downMbps': downMbps,
    'upMbps': upMbps,
    'server': server,
    'provenance': provenance,
    if (label.isNotEmpty) 'label': label,
    if (rsrpStart != null) 'rsrpStart': rsrpStart,
    if (rsrpEnd != null) 'rsrpEnd': rsrpEnd,
    if (netStart.isNotEmpty) 'netStart': netStart,
    if (netEnd.isNotEmpty) 'netEnd': netEnd,
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
    label: '${j['label'] ?? ''}',
    rsrpStart: (j['rsrpStart'] as num?)?.toInt(),
    rsrpEnd: (j['rsrpEnd'] as num?)?.toInt(),
    netStart: '${j['netStart'] ?? ''}',
    netEnd: '${j['netEnd'] ?? ''}',
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
