import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zte_mf935_app/core/data_plan.dart';
import 'package:zte_mf935_app/core/usage_history.dart';

CycleUsage archived({
  String id = '2026-10',
  double usedMb = 6000,
  DateTime? lastAt,
}) =>
    CycleUsage(
      id: id,
      startedAt: DateTime(2026, 10, 1, 8),
      lastAt: lastAt ?? DateTime(2026, 10, 31, 8),
      usedMb: usedMb,
      rxMb: usedMb * 0.6,
      txMb: usedMb * 0.4,
      daily: const {},
      startKnown: false,
    );

DataPlanState plan({
  double quotaMb = 6.5 * 1024,
  int validityDays = 13,
  double? priceNaira = 1000,
  DateTime? startedAt,
  double baselineMb = 1000,
}) => DataPlanState(
  carrier: 'Airtel',
  planName: '6.5 GB',
  quotaMb: quotaMb,
  validityDays: validityDays,
  priceNaira: priceNaira,
  startedAt: startedAt ?? DateTime(2026, 11, 1, 8),
  baselineMb: baselineMb,
);

void main() {
  group('DataPlan math', () {
    test('used + remaining derive from the ledger baseline', () {
      final p = plan();
      // Ledger has moved 1500 MB since the top-up.
      expect(p.usedSince(2500), 1500);
      expect(p.remainingMb(2500), closeTo(6.5 * 1024 - 1500, 1e-9));
      // A lower reading (counter reset) never goes negative.
      expect(p.usedSince(500), 0);
    });

    test('days elapsed + left from the clock', () {
      final p = plan();
      expect(p.daysElapsed(DateTime(2026, 11, 1, 8)), 0);
      expect(p.daysElapsed(DateTime(2026, 11, 4, 8)), 3);
      expect(p.daysLeft(DateTime(2026, 11, 4, 8)), 10);
      expect(p.endsAt, DateTime(2026, 11, 14, 8));
    });

    test('verdict: on track when the quota outlives the validity', () {
      final p = plan();
      // 1500 used in 3 days = 500/day; ~5156 left = ~10 days of
      // runway, but only 10 validity days remain — still on track
      // when it lands past expiry.
      final v = p.verdict(2500, 400, DateTime(2026, 11, 4, 8));
      expect(v, PlanVerdict.onTrack);
    });

    test('verdict: burning fast when dry before expiry', () {
      final p = plan();
      // 5000 used in 3 days: ~1656 left at ~1666/day = ~1 day.
      final v = p.verdict(6000, 1666, DateTime(2026, 11, 4, 8));
      expect(v, PlanVerdict.burningFast);
    });

    test('verdict: exhausted, expired, warming up', () {
      final p = plan();
      expect(
        p.verdict(1000 + 6.5 * 1024 + 1, 500, DateTime(2026, 11, 4, 8)),
        PlanVerdict.exhausted,
      );
      expect(
        p.verdict(2500, 100, DateTime(2026, 11, 20, 8)),
        PlanVerdict.expired,
      );
      expect(
        p.verdict(2500, 0, DateTime(2026, 11, 4, 8)),
        PlanVerdict.warmingUp,
      );
    });

    test('spend totals active + archived bundles', () {
      final p = plan().logTopUp(
        quotaMb: 6.5 * 1024,
        priceNaira: 1000,
        liveUsedMb: 8000,
        now: DateTime(2026, 11, 14, 8),
      );
      expect(p.totalSpent, 2000);
      // First bundle consumed 7000 of its 6656? No — clamped by what
      // was actually used since its baseline (7000 incl. over-quota).
      expect(p.history.single.consumedMb, 7000);
      expect(p.baselineMb, 8000);
    });

    test('ledger stays honest across a billing rollover', () {
      final p = plan(baselineMb: 5000);
      // Counter reset after the top-up (November peak archived at the
      // rollover, December counting from zero): the archived peak
      // carries what came before it.
      final past = [
        archived(lastAt: DateTime(2026, 11, 30, 8), usedMb: 6000),
      ];
      expect(p.ledgerNow(200, past), 6200);
      expect(p.usedSince(p.ledgerNow(200, past)), 1200);
      // A cycle archived before the plan started is not counted twice.
      final old = [
        archived(id: '2026-09', usedMb: 9000, lastAt: DateTime(2026, 9, 30, 8)),
      ];
      expect(p.ledgerNow(200, old), 200);
    });

    test('top-up jumps ignore jitter, catch real purchases', () {
      final p = plan(); // 6.5 GB quota
      // Bonus crumbs and meter noise stay under half the quota.
      expect(p.isTopUpJump(5000, 5400), isFalse);
      expect(p.isTopUpJump(5000, 4800), isFalse);
      // 400 MB to 6.9 GB reads as the purchase it is.
      expect(p.isTopUpJump(400, 400 + 6.5 * 1024), isTrue);
      // Zero quota plans never fire.
      expect(plan(quotaMb: 0).isTopUpJump(0, 99999), isFalse);
    });

    test('adopted quotas snap clean', () {
      expect(DataPlanState.snapQuota(6.5 * 1024), 6.5 * 1024);
      expect(DataPlanState.snapQuota(7000), 7 * 1024);
      expect(DataPlanState.quotaLabel(6.5 * 1024), '6.5 GB');
      expect(DataPlanState.quotaLabel(3 * 1024), '3 GB');
    });

    test('naira formats without kobo noise', () {
      expect(formatNaira(1000), '₦1,000');
      expect(formatNaira(65000), '₦65,000');
      expect(formatNaira(0), '₦0');
    });

    test('preset matches the Airtel bundle described', () {
      final p = DataPlanState.airtelPreset(now: DateTime(2026, 11, 1));
      expect(p.carrier, 'Airtel');
      expect(p.name, 'SmartCash');
      expect(p.title, 'SmartCash');
      expect(p.quotaMb, 6.5 * 1024);
      expect(p.validityDays, 13);
      expect(p.priceNaira, 1000);
    });

    test('title falls back when the plan has no name', () {
      expect(plan().title, 'Data plan');
      expect(plan().name, isEmpty);
    });
  });

  group('DataPlan persistence', () {
    test('round-trips through prefs, corrupt degrades to null', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await DataPlanState.load(), isNull);
      final p = plan().logTopUp(
        quotaMb: 3 * 1024,
        name: 'SmartCash',
        liveUsedMb: 5000,
        now: DateTime(2026, 11, 10, 8),
      );
      await p.save();
      final back = await DataPlanState.load();
      expect(back, isNotNull);
      expect(back!.quotaMb, 3 * 1024);
      expect(back.name, 'SmartCash');
      expect(back.title, 'SmartCash');
      expect(back.history.length, 1);
      expect(back.history.single.priceNaira, 1000);
      expect(DataPlanState.decode('garbage'), isNull);
      expect(DataPlanState.decode(''), isNull);
      expect(DataPlanState.decode(null), isNull);
    });
  });
}
