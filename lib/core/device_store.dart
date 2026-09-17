library;

/// Phase 6 Connected-Device Intelligence (SSOT): first/last seen per
/// station, local friendly names, appearance/disappearance episodes,
/// connection durations, and important-device disappearance.
///
/// Honest limits: per-client traffic is NOT shown — the MF935
/// firmware exposes no trustworthy per-station counters, and the
/// roadmap forbids inventing them. The count itself stays visible on
/// the Status devices card; this store is the memory behind it.
///
/// Merge rule: a station counts as left only after missing TWO
/// consecutive snapshots, so a Wi-Fi flap doesn't forge an episode.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Join/leave episode for one station.
class DeviceEvent {
  final String mac;
  final String name;
  final bool joined; // false = left
  final DateTime at;

  const DeviceEvent({
    required this.mac,
    required this.name,
    required this.joined,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
    'mac': mac,
    'name': name,
    'joined': joined,
    'at': at.toIso8601String(),
  };

  factory DeviceEvent.fromJson(Map<String, dynamic> j) => DeviceEvent(
    mac: '${j['mac'] ?? ''}',
    name: '${j['name'] ?? ''}',
    joined: j['joined'] == true,
    at:
        DateTime.tryParse('${j['at']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Everything remembered about one station, keyed by MAC.
class KnownDevice {
  final String mac;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final String lastHostname;
  final String lastIp;

  /// Local friendly name (`Work laptop`). Empty = none set.
  final String customName;

  /// Notify when this station disappears.
  final bool important;

  /// Consecutive snapshots missing (reset on sight). Internal but
  /// persisted so a restart doesn't erase a pending leave.
  final int missStreak;

  const KnownDevice({
    required this.mac,
    required this.firstSeen,
    required this.lastSeen,
    this.lastHostname = '',
    this.lastIp = '',
    this.customName = '',
    this.important = false,
    this.missStreak = 0,
  });

  String displayName(String fallbackHostname) =>
      customName.isEmpty ? fallbackHostname : customName;

  /// Total span from first sight to last sight.
  Duration get span => lastSeen.difference(firstSeen);

  Map<String, dynamic> toJson() => {
    'mac': mac,
    'firstSeen': firstSeen.toIso8601String(),
    'lastSeen': lastSeen.toIso8601String(),
    'lastHostname': lastHostname,
    'lastIp': lastIp,
    'customName': customName,
    'important': important,
    'missStreak': missStreak,
  };

  factory KnownDevice.fromJson(Map<String, dynamic> j) {
    DateTime dt(String k) =>
        DateTime.tryParse('${j[k]}') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return KnownDevice(
      mac: '${j['mac'] ?? ''}',
      firstSeen: dt('firstSeen'),
      lastSeen: dt('lastSeen'),
      lastHostname: '${j['lastHostname'] ?? ''}',
      lastIp: '${j['lastIp'] ?? ''}',
      customName: '${j['customName'] ?? ''}',
      important: j['important'] == true,
      missStreak: (j['missStreak'] as num?)?.toInt() ?? 0,
    );
  }

  KnownDevice copyWith({
    DateTime? lastSeen,
    String? lastHostname,
    String? lastIp,
    String? customName,
    bool? important,
    int? missStreak,
  }) => KnownDevice(
    mac: mac,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    lastHostname: lastHostname ?? this.lastHostname,
    lastIp: lastIp ?? this.lastIp,
    customName: customName ?? this.customName,
    important: important ?? this.important,
    missStreak: missStreak ?? this.missStreak,
  );
}

/// Merge result: updated store + events fired by this snapshot.
class DeviceMerge {
  final DeviceStore store;
  final List<DeviceEvent> events;

  const DeviceMerge(this.store, this.events);
}

/// The store: known stations + recent episodes. Immutable-ish:
/// [merge] returns the next store. Pure + tested (pass [now]).
class DeviceStore {
  static const key = 'device_store_v1';
  static const maxEvents = 100;

  final Map<String, KnownDevice> known;
  final List<DeviceEvent> events; // newest first

  const DeviceStore({this.known = const {}, this.events = const []});

  /// Fold one station snapshot into the store.
  DeviceMerge merge(List<AttachedDevice> current, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final seen = {for (final d in current) d.mac: d};
    final next = Map<String, KnownDevice>.from(known);
    final fired = <DeviceEvent>[];

    for (final d in current) {
      if (d.mac.isEmpty) continue;
      final prev = next[d.mac];
      if (prev == null) {
        next[d.mac] = KnownDevice(
          mac: d.mac,
          firstSeen: t,
          lastSeen: t,
          lastHostname: d.hostname,
          lastIp: d.ip,
        );
        fired.add(
          DeviceEvent(
            mac: d.mac,
            name: d.hostname,
            joined: true,
            at: t,
          ),
        );
      } else {
        next[d.mac] = prev.copyWith(
          lastSeen: t,
          lastHostname: d.hostname,
          lastIp: d.ip,
          missStreak: 0,
        );
      }
    }
    for (final entry in next.entries.toList()) {
      if (seen.containsKey(entry.key)) continue;
      final updated = entry.value.copyWith(
        missStreak: entry.value.missStreak + 1,
      );
      next[entry.key] = updated;
      if (updated.missStreak == 2) {
        final label = updated.customName.isEmpty
            ? updated.lastHostname
            : updated.customName;
        fired.add(
          DeviceEvent(
            mac: entry.key,
            name: label,
            joined: false,
            at: t,
          ),
        );
      }
    }
    final allEvents = [...fired, ...events].take(maxEvents).toList();
    return DeviceMerge(
      DeviceStore(known: next, events: allEvents),
      fired,
    );
  }

  DeviceStore withDevice(KnownDevice d) {
    final next = Map<String, KnownDevice>.from(known)..[d.mac] = d;
    return DeviceStore(known: next, events: events);
  }

  /// Stations currently around: seen in the latest snapshot, or
  /// missing exactly once (Wi-Fi flap grace — the leave fires on the
  /// second consecutive miss). Anything missing twice is gone.
  List<KnownDevice> present() =>
      known.values.where((d) => d.missStreak <= 1).toList();

  /// Stations confirmed gone (two consecutive misses).
  List<KnownDevice> gone() =>
      known.values.where((d) => d.missStreak >= 2).toList();

  Map<String, dynamic> toJson() => {
    'known': {for (final e in known.entries) e.key: e.value.toJson()},
    'events': events.map((e) => e.toJson()).toList(),
  };

  /// Never throws: corrupt rows are skipped. Pure + tested.
  factory DeviceStore.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const DeviceStore();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const DeviceStore();
      final known = <String, KnownDevice>{};
      final rawKnown = j['known'];
      if (rawKnown is Map) {
        for (final e in rawKnown.entries) {
          if (e.value is Map) {
            try {
              final d = KnownDevice.fromJson(
                Map<String, dynamic>.from(e.value as Map),
              );
              if (d.mac.isNotEmpty) known[d.mac] = d;
            } catch (_) {}
          }
        }
      }
      final events = <DeviceEvent>[];
      final rawEvents = j['events'];
      if (rawEvents is List) {
        for (final e in rawEvents) {
          if (e is Map) {
            try {
              events.add(
                DeviceEvent.fromJson(Map<String, dynamic>.from(e)),
              );
            } catch (_) {}
          }
        }
      }
      return DeviceStore(known: known, events: events.take(maxEvents).toList());
    } catch (_) {
      return const DeviceStore();
    }
  }

  static Future<DeviceStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DeviceStore.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(toJson()));
  }
}
