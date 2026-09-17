library;

/// Phase 9 Advanced Features (SSOT): best time-of-day, scheduled
/// diagnostics, read-only capability discovery, safe scheduled
/// reboot, loopback read-only API, and plaintext backup/restore.
///
/// Deliberately NOT here: room heatmaps and Scout-session compare —
/// both need Phase 1 spot data, which doesn't exist yet. No dead UI
/// is shipped for them; see [todo.md] ordering.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'incident_report.dart';
import 'speed_history.dart';

// ── Best time of day ─────────────────────────────────────────────

/// Best hour-bucket for downloads from history: `{hour, avgDownMbps,
/// count, label}`. Buckets are 2 h wide; a bucket needs ≥2 samples to
/// qualify (one lucky test is not a pattern). Null when no bucket
/// qualifies. Pure + tested.
({int hour, double avgDown, int count})? bestTimeOfDay(
  List<SpeedRecord> records,
) {
  final buckets = <int, List<double>>{};
  for (final r in records) {
    if (r.downMbps == null) continue;
    final bucket = (r.at.hour ~/ 2) * 2;
    buckets.putIfAbsent(bucket, () => []).add(r.downMbps!);
  }
  ({int hour, double avgDown, int count})? best;
  for (final e in buckets.entries) {
    if (e.value.length < 2) continue;
    final avg = e.value.reduce((a, b) => a + b) / e.value.length;
    if (best == null || avg > best.avgDown) {
      best = (hour: e.key, avgDown: avg, count: e.value.length);
    }
  }
  return best;
}

String bestTimeLabel(({int hour, double avgDown, int count}) b) {
  String h(int v) => v.toString().padLeft(2, '0');
  return '${h(b.hour)}:00–${h((b.hour + 2) % 24)}:00 averages fastest '
      '(${b.avgDown.toStringAsFixed(1)} Mbps over ${b.count} tests)';
}

// ── Scheduled diagnostics ────────────────────────────────────────

/// Daily diagnostic snapshot settings. Auto speed test defaults OFF
/// and additionally requires the first-run speed consent — a
/// scheduled run must never surprise-spend carrier data.
class ScheduledDiag {
  final bool enabled;
  final int hour; // 0-23 local
  final bool autoSpeedTest;
  final String lastRunDay; // yyyy-MM-dd, '' = never

  const ScheduledDiag({
    this.enabled = false,
    this.hour = 7,
    this.autoSpeedTest = false,
    this.lastRunDay = '',
  });

  static String dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Due when enabled, the hour matches, and today hasn't run.
  /// Pure + tested.
  bool dueAt(DateTime now) =>
      enabled && now.hour == hour && lastRunDay != dayKey(now);

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'hour': hour,
    'autoSpeedTest': autoSpeedTest,
    'lastRunDay': lastRunDay,
  };

  factory ScheduledDiag.decode(String? raw) {
    const d = ScheduledDiag();
    if (raw == null || raw.isEmpty) return d;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return d;
      final h = (j['hour'] as num?)?.toInt();
      return ScheduledDiag(
        enabled: j['enabled'] == true,
        hour: (h == null || h < 0 || h > 23) ? d.hour : h,
        autoSpeedTest: j['autoSpeedTest'] == true,
        lastRunDay: '${j['lastRunDay'] ?? ''}',
      );
    } catch (_) {
      return d;
    }
  }

  static const key = 'scheduled_diag_v1';

  static Future<ScheduledDiag> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ScheduledDiag.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}

// ── Safe scheduled reboot ────────────────────────────────────────

/// One-shot reboot schedule. The shell executes it once, then clears
/// it — a reboot schedule must never repeat by accident.
class ScheduledReboot {
  final DateTime? at;

  const ScheduledReboot({this.at});

  bool get armed => at != null;

  /// Due and still armed. Pure + tested.
  bool dueAt(DateTime now) => at != null && !now.isBefore(at!);

  Map<String, dynamic> toJson() => {'at': at?.toIso8601String()};

  factory ScheduledReboot.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const ScheduledReboot();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const ScheduledReboot();
      final at = DateTime.tryParse('${j['at']}');
      if (at == null) return const ScheduledReboot();
      return ScheduledReboot(at: at);
    } catch (_) {
      return const ScheduledReboot();
    }
  }

  static const key = 'scheduled_reboot_v1';

  static Future<ScheduledReboot> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ScheduledReboot.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}

// ── Read-only capability discovery ───────────────────────────────

/// Status keys probed with ONE read-only GET. No writes, no
/// station_list (different response shape), no identity keys.
const discoveryProbeKeys = <String>[
  'signalbar',
  'network_type',
  'network_provider',
  'battery_vol_percent',
  'battery_charging',
  'rssi',
  'rscp',
  'lte_rsrp',
  'lte_rsrq',
  'lte_sinr',
  'realtime_rx_bytes',
  'realtime_tx_bytes',
  'realtime_time',
  'monthly_rx_bytes',
  'monthly_tx_bytes',
  'realtime_rx_thrpt',
  'realtime_tx_thrpt',
  'wifi_coverage',
  'auto_power_save',
  'sms_unread_num',
  'wa_inner_version',
  'cr_version',
  'hardware_version',
  'web_version',
  'lan_ipaddr',
  'wan_ipaddr',
  'ppp_status',
];

/// Split a probe reply into supported vs silent keys. Pure + tested.
({List<String> supported, List<String> silent}) splitDiscovery(
  Map<String, dynamic> reply,
) {
  final supported = <String>[];
  final silent = <String>[];
  for (final k in discoveryProbeKeys) {
    if ('${reply[k] ?? ''}'.isNotEmpty) {
      supported.add(k);
    } else {
      silent.add(k);
    }
  }
  return (supported: supported, silent: silent);
}

class DiscoveryResult {
  final DateTime at;
  final List<String> supported;
  final List<String> silent;

  const DiscoveryResult({
    required this.at,
    this.supported = const [],
    this.silent = const [],
  });

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'supported': supported,
    'silent': silent,
  };

  factory DiscoveryResult.decode(String? raw) {
    if (raw == null || raw.isEmpty) return DiscoveryResult(at: DateTime.fromMillisecondsSinceEpoch(0));
    try {
      final j = jsonDecode(raw);
      if (j is! Map) {
        return DiscoveryResult(at: DateTime.fromMillisecondsSinceEpoch(0));
      }
      List<String> strs(String k) {
        final v = j[k];
        if (v is! List) return const [];
        return v.map((e) => '$e').toList();
      }

      return DiscoveryResult(
        at:
            DateTime.tryParse('${j['at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        supported: strs('supported'),
        silent: strs('silent'),
      );
    } catch (_) {
      return DiscoveryResult(at: DateTime.fromMillisecondsSinceEpoch(0));
    }
  }

  static const key = 'capability_discovery_v1';

  static Future<DiscoveryResult> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DiscoveryResult.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}

// ── Loopback read-only API ───────────────────────────────────────

class LocalApiSettings {
  final bool enabled;
  final int port;

  const LocalApiSettings({this.enabled = false, this.port = 18080});

  Map<String, dynamic> toJson() => {'enabled': enabled, 'port': port};

  factory LocalApiSettings.decode(String? raw) {
    const d = LocalApiSettings();
    if (raw == null || raw.isEmpty) return d;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return d;
      final p = (j['port'] as num?)?.toInt();
      return LocalApiSettings(
        enabled: j['enabled'] == true,
        port: (p == null || p < 1024 || p > 65535) ? d.port : p,
      );
    } catch (_) {
      return d;
    }
  }

  static const key = 'local_api_v1';

  static Future<LocalApiSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalApiSettings.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}

/// Loopback-only HTTP server: `/snapshot` (scrubbed status) and
/// `/health`. Binds 127.0.0.1 exclusively — never a LAN interface.
class LocalApiServer {
  HttpServer? _server;

  bool get running => _server != null;
  int get port => _server?.port ?? -1;

  Future<void> start({
    required int port,
    required Map<String, dynamic> Function() snapshot,
  }) async {
    await stop();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      try {
        if (req.uri.path == '/health') {
          res.write('{"ok":true}');
        } else if (req.uri.path == '/snapshot') {
          res.write(
            jsonEncode({
              'ok': true,
              'at': DateTime.now().toIso8601String(),
              'status': scrubSnapshot(snapshot()),
            }),
          );
        } else {
          res.statusCode = HttpStatus.notFound;
          res.write('{"ok":false,"error":"unknown path"}');
        }
      } catch (e) {
        res.statusCode = HttpStatus.internalServerError;
        res.write('{"ok":false,"error":"$e"}');
      }
      await res.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

// ── Backup / restore (plaintext JSON) ────────────────────────────

/// Prefs keys included in a backup. Everything the app remembers,
/// nothing it shouldn't (no passwords — the admin password lives
/// under `admin_password` and is deliberately excluded).
const backupKeys = <String>[
  'gateway_ip',
  'theme_mode',
  'speed_test_consent',
  'speed_history_v1',
  'smart_alerts_settings_v1',
  'smart_alerts_lastfired_v1',
  'smart_alerts_history_v1',
  'device_store_v1',
  'monitor_settings_v1',
  'battery_samples_v1',
  'scheduled_diag_v1',
  'scheduled_reboot_v1',
  'capability_discovery_v1',
  'local_api_v1',
  'sms_autoclean',
];

/// Export included prefs as versioned JSON. Pure I/O, tested decode.
Future<String> buildBackup() async {
  final prefs = await SharedPreferences.getInstance();
  final data = <String, String>{};
  for (final k in backupKeys) {
    final v = prefs.getString(k);
    if (v != null) data[k] = v;
    final b = prefs.getBool(k);
    if (b != null && v == null) data[k] = b ? 'bool:true' : 'bool:false';
  }
  return const JsonEncoder.withIndent('  ').convert({
    'app': 'MiFi Companion backup',
    'version': 1,
    'at': DateTime.now().toIso8601String(),
    'data': data,
  });
}

/// Validate + apply a backup. Returns the restored key count.
/// Throws [FormatException] on anything malformed — the caller shows
/// the message. Never wipes keys the backup doesn't mention.
Future<int> restoreBackup(String raw) async {
  dynamic j;
  try {
    j = jsonDecode(raw);
  } catch (_) {
    throw const FormatException('Not valid JSON.');
  }
  if (j is! Map ||
      j['app'] != 'MiFi Companion backup' ||
      j['data'] is! Map) {
    throw const FormatException('Not a MiFi Companion backup.');
  }
  final data = Map<String, dynamic>.from(j['data'] as Map);
  final prefs = await SharedPreferences.getInstance();
  var count = 0;
  for (final k in backupKeys) {
    final v = data[k];
    if (v is! String) continue;
    if (v == 'bool:true' || v == 'bool:false') {
      await prefs.setBool(k, v == 'bool:true');
    } else {
      await prefs.setString(k, v);
    }
    count++;
  }
  if (count == 0) throw const FormatException('Backup holds no known keys.');
  return count;
}
