library;

/// Connection timeline (SSOT): a durable, typed record of what the link
/// did and when.
///
/// The activity log answers "what did the app just do"; it cannot answer
/// "why was the internet bad at 8pm last Tuesday", because those events
/// happened in a previous process, hours ago, with nobody watching. The
/// timeline is the second thing: structured events (session lost,
/// unreachable, internet down, signal drop, network-type change) with
/// severity and supporting values, retained locally, filterable, and
/// folded into incident reports so the carrier gets the story rather
/// than a snapshot.
///
/// Design rules:
///  - events are *state changes*, not samples: no heartbeat rows, or the
///    timeline becomes the log with extra steps;
///  - retention is enforced on write (count + age), never at display
///    time, so a laptop left open for a month cannot grow without bound;
///  - severity is a property of the event, not of the UI mood.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const timelinePrefsKey = 'connection_timeline_v1';

/// How much trouble the event represents.
enum EventSeverity {
  info,

  /// Something degraded but is still working.
  warn,

  /// The connection was lost or unusable.
  critical,
}

/// What happened. Wire names are the enum names (stable forever).
enum ConnEventKind {
  login,
  autoLogin,
  logout,
  sessionLost,
  reconnect,
  unreachable,
  recovered,

  /// The probe found the internet unusable behind a reachable modem.
  internetDown,
  internetUp,
  signalLost,
  signalRecovered,
  networkTypeChanged,
  throughputDrop,
  throughputRecovered,
  reboot,
  shutdown,
}

/// One timeline entry. [data] holds the supporting values (battery,
/// network type, RSRP, verdict…) so an entry can be expanded instead of
/// merely asserted.
class ConnEvent {
  final DateTime at;
  final ConnEventKind kind;
  final EventSeverity severity;
  final String summary;
  final Map<String, String> data;

  const ConnEvent({
    required this.at,
    required this.kind,
    required this.severity,
    required this.summary,
    this.data = const {},
  });

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'kind': kind.name,
    'sev': severity.name,
    'summary': summary,
    if (data.isNotEmpty) 'data': data,
  };

  factory ConnEvent.fromJson(Map<String, dynamic> j) {
    final rawData = j['data'];
    return ConnEvent(
      at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
      kind: ConnEventKind.values.firstWhere(
        (k) => k.name == '${j['kind'] ?? ''}',
        orElse: () => ConnEventKind.recovered,
      ),
      severity: EventSeverity.values.firstWhere(
        (s) => s.name == '${j['sev'] ?? ''}',
        orElse: () => EventSeverity.info,
      ),
      summary: '${j['summary'] ?? ''}',
      data: rawData is Map
          ? rawData.map((k, v) => MapEntry('$k', '$v'))
          : const <String, String>{},
    );
  }
}

/// Default severity for a kind, so callers never have to repeat it and a
/// "session lost" cannot be recorded as a non-event. Pure + tested.
EventSeverity defaultSeverity(ConnEventKind kind) => switch (kind) {
  ConnEventKind.unreachable ||
  ConnEventKind.sessionLost ||
  ConnEventKind.internetDown ||
  ConnEventKind.signalLost => EventSeverity.critical,
  ConnEventKind.throughputDrop ||
  ConnEventKind.logout ||
  ConnEventKind.reboot ||
  ConnEventKind.shutdown ||
  ConnEventKind.networkTypeChanged => EventSeverity.warn,
  _ => EventSeverity.info,
};

/// Retention: drop anything older than [maxAge], then keep the [max]
/// newest by timestamp. Pure + tested.
///
/// Sorting before trimming (rather than trusting insertion order) is what
/// keeps a clock jump — or a restored backup — from pushing a genuinely
/// newer event out of the retained window.
List<ConnEvent> pruneEvents(
  List<ConnEvent> events, {
  required int max,
  Duration maxAge = const Duration(days: 14),
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  final kept =
      events.where((e) => e.at.isAfter(cutoff)).toList()
        ..sort((a, b) => b.at.compareTo(a.at));
  return kept.length <= max ? kept : kept.sublist(0, max);
}

/// Severity filter helper (the timeline's category chips). Pure + tested.
List<ConnEvent> filterEvents(
  List<ConnEvent> events, {
  Set<ConnEventKind>? kinds,
  EventSeverity? minSeverity,
}) => events
    .where(
      (e) =>
          (kinds == null || kinds.isEmpty || kinds.contains(e.kind)) &&
          (minSeverity == null || e.severity.index >= minSeverity.index),
    )
    .toList();

// ── Storage ────────────────────────────────────────────────────────

abstract class TimelineBackend {
  Future<List<ConnEvent>> load();
  Future<void> save(List<ConnEvent> events);
}

class PrefsTimelineBackend implements TimelineBackend {
  const PrefsTimelineBackend();

  @override
  Future<List<ConnEvent>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(timelinePrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ConnEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<ConnEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      timelinePrefsKey,
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }
}

class MemoryTimelineBackend implements TimelineBackend {
  List<ConnEvent> events;
  MemoryTimelineBackend([List<ConnEvent>? seed])
    : events = List<ConnEvent>.from(seed ?? const []);

  @override
  Future<List<ConnEvent>> load() async => List<ConnEvent>.from(events);

  @override
  Future<void> save(List<ConnEvent> events) async {
    this.events = List<ConnEvent>.from(events);
  }
}

/// In-memory, retained, newest-first timeline.
class TimelineStore {
  TimelineBackend backend;
  final int max;

  /// Flush cadence: the poller can fire several events in a burst, and
  /// each prefs write is a disk hit.
  TimelineStore({TimelineBackend? backend, this.max = 300})
    : backend = backend ?? const PrefsTimelineBackend();

  List<ConnEvent> _events = const [];
  bool _dirty = false;

  List<ConnEvent> get events => List<ConnEvent>.unmodifiable(_events);

  Future<List<ConnEvent>> load() async {
    _events = pruneEvents(await backend.load(), max: max);
    _dirty = false;
    return events;
  }

  /// Record one event (pruning as it goes) and mark the store dirty.
  ConnEvent record(
    ConnEventKind kind,
    String summary, {
    Map<String, String>? data,
    EventSeverity? severity,
    DateTime? at,
  }) {
    final e = ConnEvent(
      at: at ?? DateTime.now(),
      kind: kind,
      severity: severity ?? defaultSeverity(kind),
      summary: summary,
      data: data ?? const {},
    );
    _events = pruneEvents([e, ..._events], max: max);
    _dirty = true;
    return e;
  }

  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    await backend.save(_events);
  }

  Future<void> clear() async {
    _events = const [];
    _dirty = false;
    await backend.save(_events);
  }

  /// Plain-text export, newest first — the same shape an incident report
  /// embeds, so a timeline copy and a report copy read alike.
  String exportText({int max = 100}) {
    final buf = StringBuffer()
      ..writeln('=== connection timeline (${_events.length} events) ===');
    for (final e in _events.take(max)) {
      final stamp = e.at.toIso8601String().substring(0, 19).replaceAll('T', ' ');
      buf.writeln('$stamp  [${e.severity.name}] ${e.kind.name}: ${e.summary}');
      for (final entry in e.data.entries) {
        buf.writeln('        ${entry.key}=${entry.value}');
      }
    }
    return buf.toString();
  }
}