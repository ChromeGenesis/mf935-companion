import 'package:flutter_test/flutter_test.dart';
import 'package:zte_mf935_app/core/conn_timeline.dart';

void main() {
  test('Timeline severity defaults match the kind, never softer', () {
    expect(defaultSeverity(ConnEventKind.sessionLost), EventSeverity.critical);
    expect(defaultSeverity(ConnEventKind.unreachable), EventSeverity.critical);
    expect(defaultSeverity(ConnEventKind.internetDown), EventSeverity.critical);
    expect(defaultSeverity(ConnEventKind.networkTypeChanged), EventSeverity.warn);
    expect(defaultSeverity(ConnEventKind.reboot), EventSeverity.warn);
    expect(defaultSeverity(ConnEventKind.login), EventSeverity.info);
    expect(defaultSeverity(ConnEventKind.reconnect), EventSeverity.info);
  });

  test('Timeline retains newest, prunes by age, and survives restarts', () async {
    final now = DateTime.now();
    final backend = MemoryTimelineBackend();
    final store = TimelineStore(backend: backend, max: 5);
    store.load();
    // Twenty events one minute apart: only the newest five may survive,
    // and the month-old one must be dropped by the age rule.
    for (var i = 0; i < 20; i++) {
      store.record(
        ConnEventKind.sessionLost,
        'event $i',
        at: now.subtract(Duration(minutes: i)),
      );
    }
    store.record(
      ConnEventKind.login,
      'ancient',
      at: now.subtract(const Duration(days: 40)),
    );
    expect(store.events.length, 5);
    expect(store.events.first.summary, 'event 0');

    await store.flush();
    final reopened = TimelineStore(backend: backend, max: 5);
    final loaded = await reopened.load();
    expect(loaded.length, 5);
    expect(loaded.first.kind, ConnEventKind.sessionLost);

    // Evidence survives the round-trip (that is the point of an event).
    store.record(
      ConnEventKind.networkTypeChanged,
      'LTE -> 3G',
      data: const {'from': 'LTE', 'to': '3G'},
    );
    await store.flush();
    final withData = await reopened.load();
    expect(withData.first.data['to'], '3G');
  });

  test('Timeline filters by severity floor and kind', () {
    final t = DateTime(2026, 1, 2, 12);
    final events = [
      ConnEvent(
        at: t,
        kind: ConnEventKind.login,
        severity: EventSeverity.info,
        summary: 'login ok',
      ),
      ConnEvent(
        at: t,
        kind: ConnEventKind.internetDown,
        severity: EventSeverity.critical,
        summary: 'no dns',
      ),
      ConnEvent(
        at: t,
        kind: ConnEventKind.networkTypeChanged,
        severity: EventSeverity.warn,
        summary: 'LTE -> 3G',
      ),
    ];
    expect(filterEvents(events, minSeverity: EventSeverity.warn).length, 2);
    expect(
      filterEvents(events, kinds: {ConnEventKind.networkTypeChanged}).length,
      1,
    );
    // An empty kind set means "no filter", not "match nothing".
    expect(filterEvents(events, kinds: {}).length, 3);
  });

  test('Timeline export carries severity, kind and supporting values', () {
    final store = TimelineStore(backend: MemoryTimelineBackend());
    store.record(
      ConnEventKind.sessionLost,
      'session lost (reboot?)',
      at: DateTime.now(),
      data: const {'signal': '0/5'},
    );
    final text = store.exportText();
    expect(text, contains('[critical] sessionLost'));
    expect(text, contains('signal=0/5'));
  });
}