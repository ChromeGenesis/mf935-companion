import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zte_mf935_app/core/theme.dart';
import 'package:zte_mf935_app/core/usage_history.dart';
import 'package:zte_mf935_app/core/zte_client.dart';
import 'package:zte_mf935_app/features/usage_page.dart';

CycleUsage cycle({
  String id = '2026-10',
  DateTime? startedAt,
  DateTime? lastAt,
  double usedMb = 100,
  double rxMb = 60,
  double txMb = 40,
  Map<String, double>? daily,
  bool startKnown = false,
}) =>
    CycleUsage(
      id: id,
      startedAt: startedAt ?? DateTime(2026, 10, 1, 8),
      lastAt: lastAt ?? DateTime(2026, 10, 20, 8),
      usedMb: usedMb,
      rxMb: rxMb,
      txMb: txMb,
      daily: daily ?? {},
      startKnown: startKnown,
    );

void main() {
  group('UsageHistory ledger', () {
    test('first sample opens a cycle, marked join-mid-cycle', () {
      var h = const UsageHistory.empty();
      final t0 = DateTime(2026, 10, 1, 8);
      h = h.record(100, 60, 40, t0);
      expect(h.current, isNotNull);
      expect(h.current!.usedMb, 100);
      expect(h.current!.rxMb, 60);
      expect(h.current!.txMb, 40);
      expect(h.current!.startKnown, isFalse,
          reason: 'the app cannot know the carrier cycle began today');
      expect(h.current!.id, '2026-10');
      expect(h.past, isEmpty);
    });

    test('growing samples raise the peaks and extend the daily map', () {
      final t0 = DateTime(2026, 10, 1, 8);
      var h = const UsageHistory.empty().record(100, 60, 40, t0);
      h = h.record(250, 150, 100, t0.add(const Duration(days: 1)));
      expect(h.current!.usedMb, 250);
      expect(h.current!.rxMb, 150);
      expect(h.current!.daily.length, 2);
      // Counter held steady on the same day: no new day entry.
      h = h.record(
        250,
        150,
        100,
        t0.add(const Duration(days: 1, hours: 2)),
      );
      expect(h.current!.daily.length, 2);
      expect(h.current!.lastAt, t0.add(const Duration(days: 1, hours: 2)));
    });

    test('a dip inside the tolerance is jitter, not a rollover', () {
      final t0 = DateTime(2026, 10, 1, 8);
      var h = const UsageHistory.empty().record(100, 60, 40, t0);
      final jitter = h.record(99.5, 60, 39.5, t0.add(const Duration(minutes: 1)));
      expect(identical(jitter, h), isTrue,
          reason: 'no-op samples must not rewrite storage');
    });

    test('a counter drop archives the cycle and opens a witnessed one', () {
      final t0 = DateTime(2026, 10, 1, 8);
      final t1 = t0.add(const Duration(hours: 1));
      var h = const UsageHistory.empty().record(100, 60, 40, t0);
      h = h.record(250, 150, 100, t1);
      h = h.record(3, 2, 1, t0.add(const Duration(days: 32)));
      expect(h.past.length, 1);
      expect(h.past.first.usedMb, 250,
          reason: 'the peak is the best estimate of the finished month');
      expect(h.past.first.lastAt, t1, reason: 'ended at its last good sample');
      expect(h.past.first.id, '2026-10');
      expect(h.current!.startKnown, isTrue,
          reason: 'we saw the reset, so this cycle start is real');
      expect(h.current!.usedMb, 3);
      expect(h.current!.id, '2026-11');
    });

    test('daily deltas: unknown baseline day zeroed, negatives floored', () {
      final notKnown = CycleUsage(
        id: '2026-10',
        startedAt: DateTime(2026, 10, 1, 8),
        lastAt: DateTime(2026, 10, 3, 8),
        usedMb: 60,
        rxMb: 40,
        txMb: 20,
        daily: const {
          '2026-10-01': 50.0,
          '2026-10-02': 60.0,
          '2026-10-03': 55.0,
        },
        startKnown: false,
      );
      // App joined mid-cycle: day one's 50 MB predates tracking, and a
      // lower cumulative (counter jitter) never becomes a negative bar.
      expect(
        notKnown.dailyDeltas().map((d) => d.mb).toList(),
        [0, 10, 0],
      );

      final known = CycleUsage(
        id: '2026-10',
        startedAt: DateTime(2026, 10, 1),
        lastAt: DateTime(2026, 10, 3),
        usedMb: 115,
        rxMb: 70,
        txMb: 45,
        daily: const {
          '2026-10-01': 50.0,
          '2026-10-02': 60.0,
          '2026-10-03': 55.0,
        },
        startKnown: true,
      );
      expect(
        known.dailyDeltas().map((d) => d.mb).toList(),
        [50, 10, 0],
        reason: 'witnessed start: the first day owns its cumulative',
      );
    });

    test('archive cap: history keeps the newest 24 cycles', () {
      var h = const UsageHistory.empty();
      var at = DateTime(2026, 1, 1);
      double cum = 10;
      for (var i = 0; i < 30; i++) {
        h = h.record(cum, cum * 0.6, cum * 0.4, at);
        cum += 1000;
        at = at.add(const Duration(days: 5));
        h = h.record(cum, cum * 0.6, cum * 0.4, at);
        at = at.add(const Duration(days: 30));
        h = h.record(10, 6, 4, at); // drop → archive
        cum = 10;
      }
      expect(h.past.length, UsageHistory.maxCycles);
      expect(
        h.past.first.lastAt.isAfter(h.past.last.lastAt),
        isTrue,
        reason: 'newest first',
      );
    });

    test('daily map caps at 62 entries inside one long cycle', () {
      var h = const UsageHistory.empty();
      var at = DateTime(2026, 9, 1);
      double cum = 10;
      for (var i = 0; i < 80; i++) {
        cum += 50;
        at = at.add(const Duration(days: 1));
        h = h.record(cum, cum * 0.6, cum * 0.4, at);
      }
      expect(h.current!.daily.length, UsageHistory.maxDaysPerCycle);
    });

    test('decode: corrupt payloads degrade to empty, good JSON round-trips',
        () {
      expect(UsageHistory.decode(null).hasData, isFalse);
      expect(UsageHistory.decode('').hasData, isFalse);
      expect(UsageHistory.decode('garbage').hasData, isFalse);
      expect(UsageHistory.decode('{"a":1}').hasData, isFalse);

      final history = UsageHistory(
        current: cycle(daily: const {'2026-10-20': 100.0}),
        past: [
          cycle(id: '2026-09', usedMb: 2048, lastAt: DateTime(2026, 9, 30)),
          cycle(id: '2026-08', usedMb: 3072, lastAt: DateTime(2026, 8, 31)),
        ],
      );
      final back = UsageHistory.decode(history.encode());
      expect(back.current!.usedMb, 100);
      expect(back.past.length, 2);
      expect(back.past.first.label, 'Sep 2026');
      expect(back.past.first.usedMb, 2048);
      expect(back.past.last.id, '2026-08');

      // One corrupt row must not kill the whole history.
      final partial = UsageHistory.decode(
        '{"current":null,"past":[{"id":"2026-09","startedAt":"bogus",'
        '"lastAt":"bogus","usedMb":5,"rxMb":3,"txMb":2,"daily":{}},'
        '"not-a-row"]}',
      );
      expect(partial.past.length, 1);
    });

    test('save + load round-trips through prefs', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await UsageHistory.load()).hasData, isFalse);
      final history = UsageHistory(
        current: cycle(daily: const {'2026-10-20': 100.0}),
        past: [cycle(id: '2026-09', usedMb: 2048)],
      );
      await history.save();
      final loaded = await UsageHistory.load();
      expect(loaded.current!.usedMb, 100);
      expect(loaded.past.single.id, '2026-09');
    });

    test('clearedPast drops archives, keeps the live cycle', () {
      final history = UsageHistory(
        current: cycle(),
        past: [cycle(id: '2026-09')],
      );
      final cleared = history.clearedPast();
      expect(cleared.past, isEmpty);
      expect(cleared.current!.usedMb, history.current!.usedMb);
    });

    test('labels, month lengths, short dates', () {
      expect(cycle(id: '2026-10').label, 'Oct 2026');
      expect(cycle(id: '2026-01').label, 'Jan 2026');
      expect(cycle(id: 'weird').label, 'weird');
      expect(UsageHistory.daysInMonth(DateTime(2026, 2, 10)), 28);
      expect(UsageHistory.daysInMonth(DateTime(2028, 2, 10)), 29);
      expect(UsageHistory.daysInMonth(DateTime(2026, 12, 15)), 31);
      expect(shortDate(DateTime(2026, 9, 28)), 'Sep 28');
      expect(shortDate(DateTime(2026, 11, 3)), 'Nov 3');
      expect(UsageHistory.dayKey(DateTime(2026, 3, 4)), '2026-03-04');
      expect(UsageHistory.monthKey(DateTime(2026, 3, 4)), '2026-03');
    });

    test('counter guard: absent counters are skipped, halves default to 0',
        () {
      expect(UsageHistory.parseMonthlyUsage({}), isNull);
      expect(UsageHistory.parseMonthlyUsage({'monthly_rx_bytes': ''}), isNull);
      final s = UsageHistory.parseMonthlyUsage({
        'monthly_rx_bytes': '1048576',
        'monthly_tx_bytes': '2097152',
      });
      expect(s!.$1, 3);
      expect(s.$2, 1);
      expect(s.$3, 2);
      final half = UsageHistory.parseMonthlyUsage({'monthly_tx_bytes': '1'});
      expect(half!.$2, 0);
      expect(half.$3, closeTo(1 / 1048576, 1e-9));
    });
  });

  group('Usage page', () {
    final seeded = UsageHistory(
      current: cycle(
        usedMb: 90,
        rxMb: 60,
        txMb: 30,
        daily: const {
          '2026-10-04': 10.0,
          '2026-10-05': 25.0,
          '2026-10-06': 60.0,
          '2026-10-07': 61.0,
          '2026-10-08': 90.0,
        },
      ),
      past: [
        cycle(id: '2026-09', usedMb: 2048, startedAt: DateTime(2026, 9, 1), lastAt: DateTime(2026, 9, 30, 9)),
        cycle(id: '2026-08', usedMb: 3072, startedAt: DateTime(2026, 8, 1), lastAt: DateTime(2026, 8, 31, 9)),
      ],
    );

    UsagePage page({
      required ValueNotifier<UsageHistory> feed,
      ValueNotifier<double?>? alertFeed,
      void Function(double?)? onAlert,
    }) {
      SharedPreferences.setMockInitialValues({});
      return UsagePage(
        client: ZteClient(),
        connected: true,
        usageFeed: feed,
        alertFeed: alertFeed ?? ValueNotifier<double?>(40 * 1024),
        onAlertChanged: onAlert ?? (_) {},
        onSample: (_, _, _) {},
        onClearHistory: () {},
        log: (_) {},
      );
    }

    Future<void> pump(WidgetTester tester, Widget child, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildZteTheme(brightness: Brightness.dark),
          home: child,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders used number, breakdown, chart and history on '
        'desktop width', (tester) async {
      await pump(
        tester,
        page(feed: ValueNotifier<UsageHistory>(seeded)),
        const Size(980, 1400),
      );
      // Hero: big used number + the alert-line fraction.
      expect(find.text('90 MB'), findsOneWidget);
      expect(find.text('used'), findsOneWidget);
      // Alert-line ring shows the fraction; month range on the pill
      // and the hero overline.
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('Oct 1 – 31'), findsWidgets);
      // Breakdown rows: down/up split.
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('60 MB'), findsOneWidget);
      expect(find.text('30 MB'), findsOneWidget);
      // Chart corners span the billing month, not the samples.
      expect(find.text('Oct 1'), findsOneWidget);
      expect(find.text('Oct 31'), findsOneWidget);
      // History rows for both archived months.
      expect(find.text('PREVIOUS MONTHS'), findsOneWidget);
      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('Aug 2026'), findsOneWidget);
      expect(find.text('Alert at 40.0 GB'), findsOneWidget);
    });

    testWidgets('renders without overflow on a narrow phone', (tester) async {
      await pump(
        tester,
        page(feed: ValueNotifier<UsageHistory>(seeded)),
        const Size(720, 1280),
      );
      expect(find.text('90 MB'), findsOneWidget);
      expect(find.text('Aug 2026'), findsOneWidget);
    });

    testWidgets('empty ledger shows honest empty states', (tester) async {
      await pump(
        tester,
        page(
          feed: ValueNotifier<UsageHistory>(const UsageHistory.empty()),
          alertFeed: ValueNotifier<double?>(null),
        ),
        const Size(980, 1400),
      );
      expect(find.text('No usage observed yet'), findsOneWidget);
      // No history section at all when nothing has been archived.
      expect(find.text('PREVIOUS MONTHS'), findsNothing);
      expect(find.textContaining('No alert line'), findsOneWidget);
    });

    testWidgets('alert editor saves a GB line and reports it', (tester) async {
      double? saved;
      await pump(
        tester,
        page(
          feed: ValueNotifier<UsageHistory>(seeded),
          onAlert: (mb) => saved = mb,
        ),
        const Size(980, 1400),
      );
      await tester.tap(find.text('Alert at 40.0 GB'));
      await tester.pumpAndSettle();
      expect(find.text('Usage alert line'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '25');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, 25 * 1024);
    });

    testWidgets('tapping an archived month re-aims the page at it',
        (tester) async {
      await pump(
        tester,
        page(
          feed: ValueNotifier<UsageHistory>(seeded),
          alertFeed: ValueNotifier<double?>(null),
        ),
        const Size(980, 1400),
      );
      await tester.tap(find.text('Sep 2026'));
      await tester.pumpAndSettle();
      // The hero now shows the archived month's total, and the alert
      // fraction disappears (it only applies to the live cycle).
      expect(find.text('2.0 GB'), findsWidgets, reason: 'hero + history row both show it');
      expect(find.textContaining('of 40.0 GB'), findsNothing);
      expect(find.textContaining('ended Sep 30'), findsWidgets, reason: 'hero caption + history row');
    });
  });
}
