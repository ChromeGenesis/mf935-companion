library;

/// Persisted session log (SSOT): the app's activity record across
/// restarts, with typed events for the things worth finding later.
///
/// The dashboard used to keep 200 lines in RAM only, so the single most
/// useful evidence — "the MiFi rebooted at 12:41 and my auto-login
/// fired at 12:41:15" — vanished the moment the window closed, which is
/// exactly when people go looking for it. This module owns the durable
/// half: an append-only, capped (rotating) event list plus the
/// formatting and export helpers that read it.
///
/// Storage is [SharedPreferences] rather than a log file: the app has no
/// `path_provider` dependency, prefs already back up through the export
/// manifest, and the log is small (a few KB). "Rotation" therefore means
/// a count cap — [LogStore.maxEvents] entries, oldest dropped — which is
/// the same guarantee a rotating file gives for a log this size.
///
/// Pure + tested: [SessionEvent] JSON round-trips, [rotateEvents] trims
/// oldest-first, [formatLogLine] is locale-independent (a persisted log
/// must not change shape with the phone's 12/24h setting).
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const logPrefsKey = 'session_log_v1';

/// Why a line is in the log. Drives colour and filtering; the wire name
/// is the enum name so old entries stay readable forever.
enum LogKind {
  /// Routine progress ("status poll ok", "saved code remembered").
  info,

  /// A LOGIN succeeded or was attempted by hand.
  login,

  /// The modem answered but the session was gone (reboot).
  sessionLost,

  /// The watchdog re-authenticated, or the link came back on its own.
  recovered,

  /// The router did not answer at all.
  unreachable,

  /// Something was sent to the router that drops the link (reboot).
  reboot,

  /// A notification/alert fired.
  alert,

  /// A failure the user may need to explain to a carrier.
  error,
}

/// One persisted log entry. [kind] is the only classification; [message]
/// is the already-composed human line (no secrets — callers never log
/// credentials, and the incident report redacts as a second layer).
class SessionEvent {
  final DateTime at;
  final LogKind kind;
  final String message;

  const SessionEvent({
    required this.at,
    required this.kind,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'kind': kind.name,
    'message': message,
  };

  factory SessionEvent.fromJson(Map<String, dynamic> j) {
    final kind = LogKind.values.firstWhere(
      (k) => k.name == '${j['kind'] ?? ''}',
      orElse: () => LogKind.info,
    );
    return SessionEvent(
      at: DateTime.fromMillisecondsSinceEpoch(
        (j['at'] as num?)?.toInt() ?? 0,
      ),
      kind: kind,
      message: '${j['message'] ?? ''}',
    );
  }
}

/// Locale-independent one-line rendering: `HH:MM:SS  message` (24h, so a
/// restored log reads the same on every device). Pure + tested.
String formatLogLine(SessionEvent e) {
  final d = e.at;
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  final ss = d.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss  ${e.message}';
}

/// `HH:MM` — the compact stamp used by stale-data badges and timelines.
String formatClock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Drop the oldest entries beyond [max]. Newest-first order is
/// preserved. Pure + tested.
List<SessionEvent> rotateEvents(List<SessionEvent> events, int max) {
  if (max <= 0) return const [];
  return events.length <= max ? events : events.sublist(0, max);
}

/// Entries worth surfacing in an incident report: everything except
/// routine progress, newest first, capped. Pure + tested.
List<SessionEvent> notableEvents(
  List<SessionEvent> events, {
  int max = 25,
  bool includeInfo = false,
}) => rotateEvents(
  events
      .where((e) => includeInfo || e.kind != LogKind.info)
      .toList(),
  max,
);

/// Storage seam. Prefs in the app, memory in tests (and any preview
/// harness that must not touch the user's real log).
abstract class LogBackend {
  Future<List<SessionEvent>> load();
  Future<void> save(List<SessionEvent> events);
}

/// [SharedPreferences]-backed storage. Newest-first list under
/// [logPrefsKey]; a corrupt value reads as empty rather than throwing,
/// because a broken log must never block launch.
class PrefsLogBackend implements LogBackend {
  const PrefsLogBackend();

  @override
  Future<List<SessionEvent>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(logPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => SessionEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<SessionEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      logPrefsKey,
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }
}

/// In-memory backend for tests and previews.
class MemoryLogBackend implements LogBackend {
  List<SessionEvent> events;

  MemoryLogBackend([List<SessionEvent>? seed])
    : events = List<SessionEvent>.from(seed ?? const []);

  @override
  Future<List<SessionEvent>> load() async => List<SessionEvent>.from(events);

  @override
  Future<void> save(List<SessionEvent> events) async {
    this.events = List<SessionEvent>.from(events);
  }
}

/// The log itself: newest-first, capped, batched writes.
///
/// Writes are batched because log lines arrive in bursts (a single
/// incident can produce five in a row) and each prefs write is a disk
/// hit. [append] only touches memory; [flush] persists. Callers that
/// care about durability (login success, session lost) call [flush]
/// explicitly.
class LogStore {
  LogBackend backend;
  final int maxEvents;

  LogStore({LogBackend? backend, this.maxEvents = 400})
    : backend = backend ?? const PrefsLogBackend();

  List<SessionEvent> _events = const [];
  List<SessionEvent> get events => List<SessionEvent>.unmodifiable(_events);

  bool _dirty = false;

  /// Read persisted history into memory (call once at launch).
  Future<List<SessionEvent>> load() async {
    _events = rotateEvents(await backend.load(), maxEvents);
    _dirty = false;
    return events;
  }

  /// Record one line (newest first, rotating the oldest out).
  SessionEvent append(
    LogKind kind,
    String message, {
    DateTime? at,
  }) {
    final e = SessionEvent(
      at: at ?? DateTime.now(),
      kind: kind,
      message: message,
    );
    _events = rotateEvents([e, ..._events], maxEvents);
    _dirty = true;
    return e;
  }

  /// Persist pending lines. Safe to call when nothing is pending.
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    await backend.save(_events);
  }

  /// Drop everything (Settings → clear log).
  Future<void> clear() async {
    _events = const [];
    _dirty = false;
    await backend.save(_events);
  }

  /// Newest [n] entries, newest first.
  List<SessionEvent> recent(int n) => rotateEvents(_events, n);

  /// Formatted display lines, newest first (what the Settings log shows).
  List<String> lines({int max = 200}) =>
      recent(max).map(formatLogLine).toList();

  /// Plain-text export for a bug report: newest first with full dates,
  /// which is what makes a persisted log readable weeks later.
  String exportText({int max = 200}) {
    final buf = StringBuffer()
      ..writeln('=== MiFi Companion session log '
          '(${recent(max).length} of ${_events.length} entries) ===');
    for (final e in recent(max)) {
      buf.writeln(
        '${e.at.toIso8601String().substring(0, 19).replaceAll('T', ' ')}'
        '  [${e.kind.name}] ${e.message}',
      );
    }
    return buf.toString();
  }
}