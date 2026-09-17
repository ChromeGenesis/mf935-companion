library;

/// Phase 5 Smart Alerts (SSOT): evidence-bearing notifications for
/// placement degradation, repeated outages, network fallback, and
/// reachable-but-poor links.
///
/// Design rules (roadmap):
/// - every alert carries its evidence, never a vague title;
/// - per-alert enable/disable + one configurable quiet period;
/// - latching: one fire per episode, re-arm on recovery;
/// - the engine is pure-ish and unit-tested; persistence is a thin
///   SharedPreferences layer (settings, last-fired, fired history).
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The four smart alerts.
enum SmartAlertId {
  placementDegraded,
  repeatedOutage,
  networkFallback,
  reachablePoor,
}

String smartAlertTitle(SmartAlertId id) => switch (id) {
  SmartAlertId.placementDegraded => 'Placement degraded',
  SmartAlertId.repeatedOutage => 'Repeated outages',
  SmartAlertId.networkFallback => 'Network fallback',
  SmartAlertId.reachablePoor => 'Modem reachable, internet poor',
};

String smartAlertBlurb(SmartAlertId id) => switch (id) {
  SmartAlertId.placementDegraded =>
    'Signal fell sharply from its recent baseline.',
  SmartAlertId.repeatedOutage =>
    'The modem dropped off the network several times recently.',
  SmartAlertId.networkFallback =>
    'Carrier moved to a slower network generation.',
  SmartAlertId.reachablePoor =>
    'Polls answer but signal stays at the floor — placement or congestion.',
};

/// One fired alert with its evidence string.
class SmartAlert {
  final SmartAlertId id;
  final String title;
  final String body;
  final DateTime at;

  const SmartAlert({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
    'id': id.name,
    'title': title,
    'body': body,
    'at': at.toIso8601String(),
  };

  factory SmartAlert.fromJson(Map<String, dynamic> j) {
    final id = SmartAlertId.values.asNameMap()[j['id']];
    if (id == null) throw const FormatException('unknown alert id');
    return SmartAlert(
      id: id,
      title: '${j['title'] ?? ''}',
      body: '${j['body'] ?? ''}',
      at:
          DateTime.tryParse('${j['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Rank a raw `network_type` string: higher = faster generation.
/// Unknown/empty ranks -1 (ignored, never a verdict). Pure + tested.
int networkRank(String raw) {
  final t = raw.toUpperCase();
  if (t.isEmpty) return -1;
  if (t.contains('5G') || t.contains('NR')) return 4;
  if (t.contains('LTE') || t.contains('4G')) return 3;
  if (t.contains('WCDMA') ||
      t.contains('HSPA') ||
      t.contains('UMTS') ||
      t.contains('3G') ||
      t.contains('TD-SCDMA')) {
    return 2;
  }
  if (t.contains('GSM') ||
      t.contains('EDGE') ||
      t.contains('GPRS') ||
      t.contains('2G') ||
      t.contains('CDMA') ||
      t.contains('1X')) {
    return 1;
  }
  return -1;
}

/// Per-alert toggles + quiet period. Persisted; defaults all-on/30 min.
class SmartAlertSettings {
  final Map<SmartAlertId, bool> enabled;
  final int quietMinutes;

  const SmartAlertSettings({required this.enabled, required this.quietMinutes});

  factory SmartAlertSettings.defaults() => SmartAlertSettings(
    enabled: {for (final id in SmartAlertId.values) id: true},
    quietMinutes: 30,
  );

  bool isEnabled(SmartAlertId id) => enabled[id] ?? true;

  Map<String, dynamic> toJson() => {
    'enabled': {for (final e in enabled.entries) e.key.name: e.value},
    'quietMinutes': quietMinutes,
  };

  factory SmartAlertSettings.decode(String? raw) {
    final d = SmartAlertSettings.defaults();
    if (raw == null || raw.isEmpty) return d;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return d;
      final en = Map<String, bool>.from(d.toJson()['enabled'] as Map);
      final rawEn = j['enabled'];
      if (rawEn is Map) {
        for (final id in SmartAlertId.values) {
          final v = rawEn[id.name];
          if (v is bool) en[id.name] = v;
        }
      }
      final q = (j['quietMinutes'] as num?)?.toInt();
      return SmartAlertSettings(
        enabled: {
          for (final id in SmartAlertId.values) id: en[id.name] ?? true,
        },
        quietMinutes: (q == null || q < 0) ? d.quietMinutes : q,
      );
    } catch (_) {
      return d;
    }
  }
}

/// Stateful evaluator. Feed every poller tick; returns newly-fired
/// alerts (already quiet-gated). Pass an explicit [now] in tests.
class SmartAlertEngine {
  static const outageWindow = Duration(minutes: 30);
  static const outageThreshold = 3;
  static const poorStreakThreshold = 3;
  static const baselineMinSamples = 6;

  final List<({DateTime at, int bars})> _bars = [];
  final List<({DateTime at, DateTime recoveredAt})> _outages = [];
  int? _lastRank;
  String _lastNetwork = '';
  int _poorStreak = 0;
  bool _wasUnreachable = false;
  DateTime? _unreachableSince;
  final Map<SmartAlertId, DateTime> lastFired;

  SmartAlertEngine({Map<SmartAlertId, DateTime>? lastFired})
    : lastFired = lastFired ?? {};

  List<SmartAlert> tick({
    required bool reachable,
    int? bars,
    String networkType = '',
    required SmartAlertSettings settings,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    final out = <SmartAlert>[];
    void fire(SmartAlertId id, String body) {
      if (!settings.isEnabled(id)) return;
      final last = lastFired[id];
      if (last != null &&
          t.difference(last) <
              Duration(minutes: settings.quietMinutes)) {
        return;
      }
      lastFired[id] = t;
      out.add(
        SmartAlert(
          id: id,
          title: smartAlertTitle(id),
          body: body,
          at: t,
        ),
      );
    }

    if (!reachable) {
      _wasUnreachable = true;
      _unreachableSince ??= t;
      _poorStreak = 0;
      return out;
    }
    if (_wasUnreachable) {
      // Episode ended: record it, maybe fire the repeated-outage alert.
      _wasUnreachable = false;
      final since = _unreachableSince ?? t;
      _unreachableSince = null;
      _outages.add((at: since, recoveredAt: t));
      _outages.removeWhere((e) => t.difference(e.at) > outageWindow);
      if (_outages.length >= outageThreshold) {
        final mins = t.difference(_outages.first.at).inMinutes;
        fire(
          SmartAlertId.repeatedOutage,
          'Modem unreachable ${_outages.length}× in the last $mins min '
          '(latest outage ${(t.difference(since).inSeconds)}s). Check power '
          'and Wi-Fi before suspecting the carrier.',
        );
      }
    }

    if (bars != null && bars >= 0 && bars <= 5) {
      _bars.add((at: t, bars: bars));
      // Keep one hour; baseline uses the older half so a slow fade
      // still trips (baseline ≠ current).
      _bars.removeWhere((e) => t.difference(e.at) > const Duration(hours: 1));
      if (_bars.length >= baselineMinSamples) {
        final baseline = _medianBars(_bars);
        if (baseline >= 3 && bars <= baseline - 2) {
          fire(
            SmartAlertId.placementDegraded,
            'Signal fell from $baseline/5 (recent baseline) to $bars/5 '
            'while Wi-Fi stayed connected. Try the locator\'s best spot '
            'before retesting speed.',
          );
        }
      }
      if (bars <= 1) {
        _poorStreak++;
        if (_poorStreak == poorStreakThreshold) {
          fire(
            SmartAlertId.reachablePoor,
            'Polls answer but signal holds at $bars/5 for '
            '$poorStreakThreshold consecutive polls. Placement or carrier '
            'congestion — move the MiFi, then run a Full speed test.',
          );
        }
      } else {
        _poorStreak = 0;
      }
    }

    final rank = networkRank(networkType);
    if (rank >= 0) {
      final prev = _lastRank;
      if (prev != null &&
          prev >= 2 &&
          rank < prev &&
          networkType != _lastNetwork) {
        fire(
          SmartAlertId.networkFallback,
          'Network moved ${_lastNetwork.isEmpty ? 'from a faster mode' : 'from $_lastNetwork'} '
          'to $networkType. Expect slower throughput until it returns.',
        );
      }
      _lastRank = rank;
      if (networkType.isNotEmpty) _lastNetwork = networkType;
    }
    return out;
  }

  static int _medianBars(List<({DateTime at, int bars})> samples) {
    final s = samples.map((e) => e.bars).toList()..sort();
    return s[s.length ~/ 2];
  }
}

/// Persistence: settings, last-fired map, fired history (cap 50).
class SmartAlertStore {
  static const settingsKey = 'smart_alerts_settings_v1';
  static const lastFiredKey = 'smart_alerts_lastfired_v1';
  static const historyKey = 'smart_alerts_history_v1';
  static const maxHistory = 50;

  static Future<SmartAlertSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return SmartAlertSettings.decode(prefs.getString(settingsKey));
  }

  static Future<void> saveSettings(SmartAlertSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(settingsKey, jsonEncode(s.toJson()));
  }

  static Future<Map<SmartAlertId, DateTime>> loadLastFired() async {
    final out = <SmartAlertId, DateTime>{};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(lastFiredKey);
    if (raw == null || raw.isEmpty) return out;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return out;
      for (final id in SmartAlertId.values) {
        final v = DateTime.tryParse('${j[id.name]}');
        if (v != null) out[id] = v;
      }
    } catch (_) {}
    return out;
  }

  static Future<void> saveLastFired(Map<SmartAlertId, DateTime> m) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      lastFiredKey,
      jsonEncode({
        for (final e in m.entries) e.key.name: e.value.toIso8601String(),
      }),
    );
  }

  /// Newest-first fired history (for incident reports). Pure-ish
  /// helpers are static so tests skip prefs.
  static List<SmartAlert> decodeHistory(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return [];
      final out = <SmartAlert>[];
      for (final e in j) {
        if (e is Map) {
          try {
            out.add(SmartAlert.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<List<SmartAlert>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    return decodeHistory(prefs.getString(historyKey));
  }

  static Future<void> appendHistory(List<SmartAlert> fired) async {
    if (fired.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final cur = decodeHistory(prefs.getString(historyKey));
    final next = [...fired, ...cur].take(maxHistory).toList();
    await prefs.setString(
      historyKey,
      jsonEncode(next.map((a) => a.toJson()).toList()),
    );
  }
}
