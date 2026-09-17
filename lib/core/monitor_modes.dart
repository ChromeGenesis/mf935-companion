library;

/// Phase 7 Battery + Travel Modes (SSOT): monitor modes that trade
/// freshness for battery/radio quiet, battery-health samples with a
/// drain-rate readout, and low/full/prolonged-full notification
/// settings.
///
/// Modes:
/// - desk: 30 s polls, all probes on — rich monitoring.
/// - travel: 90 s polls, SMS-capacity probe off — radio stays quiet.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum MonitorMode { desk, travel }

String monitorModeLabel(MonitorMode m) => switch (m) {
  MonitorMode.desk => 'Desk',
  MonitorMode.travel => 'Travel',
};

String monitorModeBlurb(MonitorMode m) => switch (m) {
  MonitorMode.desk => '30 s polls, every probe on.',
  MonitorMode.travel =>
    '90 s polls, inbox probe off. For the road.',
};

Duration monitorInterval(MonitorMode m) => switch (m) {
  MonitorMode.desk => const Duration(seconds: 30),
  MonitorMode.travel => const Duration(seconds: 90),
};

/// User-facing battery/monitor settings. Persisted; sane defaults.
class MonitorSettings {
  final MonitorMode mode;
  final int lowBatteryPercent;
  final bool lowBatteryNotify;
  final bool fullBatteryNotify;

  const MonitorSettings({
    this.mode = MonitorMode.desk,
    this.lowBatteryPercent = 20,
    this.lowBatteryNotify = true,
    this.fullBatteryNotify = true,
  });

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'lowBatteryPercent': lowBatteryPercent,
    'lowBatteryNotify': lowBatteryNotify,
    'fullBatteryNotify': fullBatteryNotify,
  };

  factory MonitorSettings.decode(String? raw) {
    const d = MonitorSettings();
    if (raw == null || raw.isEmpty) return d;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return d;
      final mode = MonitorMode.values.asNameMap()[j['mode']] ?? d.mode;
      final low = (j['lowBatteryPercent'] as num?)?.toInt();
      return MonitorSettings(
        mode: mode,
        lowBatteryPercent:
            (low == null || low < 5 || low > 50) ? d.lowBatteryPercent : low,
        lowBatteryNotify: (j['lowBatteryNotify'] as bool?) ?? true,
        fullBatteryNotify: (j['fullBatteryNotify'] as bool?) ?? true,
      );
    } catch (_) {
      return d;
    }
  }

  static const key = 'monitor_settings_v1';

  static Future<MonitorSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return MonitorSettings.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}

/// One battery sample for the drain computation.
class BatterySample {
  final DateTime at;
  final int percent;
  final bool charging;

  const BatterySample({
    required this.at,
    required this.percent,
    required this.charging,
  });

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'p': percent,
    'c': charging,
  };

  factory BatterySample.fromJson(Map<String, dynamic> j) => BatterySample(
    at:
        DateTime.tryParse('${j['at']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    percent: (j['p'] as num?)?.toInt() ?? -1,
    charging: j['c'] == true,
  );
}

/// Drain rate in percent/hour over unplugged samples: (first − last)
/// pct over the spanned hours. Positive = draining. Needs ≥2 samples
/// spanning ≥5 min, else null (honest: no fake precision on thin
/// data). Pure + tested.
double? drainPerHour(List<BatterySample> samples) {
  final unplugged = samples.where((s) => !s.charging && s.percent >= 0).toList();
  if (unplugged.length < 2) return null;
  unplugged.sort((a, b) => a.at.compareTo(b.at));
  final hours =
      unplugged.last.at.difference(unplugged.first.at).inMinutes / 60;
  if (hours < 5 / 60) return null;
  return (unplugged.first.percent - unplugged.last.percent) / hours;
}

/// Append-only sample ring (cap 60 ≈ a day of desk polls). Pure
/// helpers + thin prefs layer.
class BatterySamples {
  static const key = 'battery_samples_v1';
  static const maxSamples = 60;

  static List<BatterySample> decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return [];
      final out = <BatterySample>[];
      for (final e in j) {
        if (e is Map) {
          try {
            out.add(
              BatterySample.fromJson(Map<String, dynamic>.from(e)),
            );
          } catch (_) {}
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Newest-last insert with cap. Pure + tested.
  static List<BatterySample> added(
    List<BatterySample> cur,
    BatterySample s,
  ) => [...cur, s].length > maxSamples
      ? [...cur, s].sublist([...cur, s].length - maxSamples)
      : [...cur, s];
}
