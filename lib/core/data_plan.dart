library;

/// Data-plan tracking (SSOT): turns "I bought 6.5 GB for 13 days" into
/// live progress without any ongoing input. The user enters the plan
/// ONCE (quota, validity, price); everything after is derived
/// automatically — consumption since the top-up from the [UsageHistory]
/// ledger, burn rate from its daily trend, days left from the clock.
///
/// The modem never reports tariffs, so the plan itself cannot be
/// auto-detected; but a top-up is one tap (the current plan's figures
/// are prefilled) and every derived number updates on its own from
/// there. Pure records + a thin SharedPreferences store, same shape
/// as `usage_history.dart`.
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'usage_history.dart';

/// '₦1,000' — whole naira, thousands-separated, no kobo noise.
String formatNaira(double n) {
  final whole = n.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return '₦${buf.toString()}';
}

/// One finished top-up, archived when the next bundle is logged.
/// [consumedMb] is how much of [quotaMb] actually got used before the
/// renewal — the honesty behind the ₦/GB efficiency figure.
class PlanTopUp {
  final DateTime date;
  final double quotaMb;
  final double? priceNaira;
  final double consumedMb;

  const PlanTopUp({
    required this.date,
    required this.quotaMb,
    this.priceNaira,
    this.consumedMb = 0,
  });

  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(),
    'quotaMb': quotaMb,
    'priceNaira': priceNaira,
    'consumedMb': consumedMb,
  };

  factory PlanTopUp.fromJson(Map<String, dynamic> j) => PlanTopUp(
    date: DateTime.tryParse('${j['date']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    quotaMb: (j['quotaMb'] as num?)?.toDouble() ?? 0,
    priceNaira: (j['priceNaira'] as num?)?.toDouble(),
    consumedMb: (j['consumedMb'] as num?)?.toDouble() ?? 0,
  );
}

/// How the active bundle is doing against its validity.
enum PlanVerdict {
  /// Projected to last past the expiry date.
  onTrack,

  /// Projected to run dry before the validity ends.
  burningFast,

  /// Nothing left, regardless of the clock.
  exhausted,

  /// Validity lapsed with quota unspent.
  expired,

  /// No measurable burn yet (first day) — nothing to project.
  warmingUp,
}

/// The active plan plus its archive. [baselineMb] is the ledger's
/// cumulative `usedMb` at the moment of top-up; consumption since is
/// simply `liveUsedMb - baselineMb`, so renewals never need the user
/// to type a meter reading.
class DataPlanState {
  static const key = 'data_plan_v1';

  /// Archived top-ups are tiny; two years of weekly bundles is plenty.
  static const maxHistory = 104;

  final String carrier;

  /// The bundle's own name (e.g. SmartCash). Blank when the plan has
  /// none — the UI falls back to a generic title instead.
  final String name;

  /// Size label derived from the quota (e.g. '6.5 GB').
  final String planName;
  final double quotaMb;
  final int validityDays;
  final double? priceNaira;
  final DateTime startedAt;
  final double baselineMb;
  final List<PlanTopUp> history;

  const DataPlanState({
    required this.carrier,
    this.name = '',
    required this.planName,
    required this.quotaMb,
    required this.validityDays,
    this.priceNaira,
    required this.startedAt,
    this.baselineMb = 0,
    this.history = const [],
  });

  /// Card title: the bundle's own name, or a generic fallback.
  String get title => name.isEmpty ? 'Data plan' : name;

  /// The plan the user described: Airtel SmartCash, 6.5 GB / 13 days /
  /// ₦1000. Starting point for the setup sheet — the user just confirms.
  static DataPlanState airtelPreset({DateTime? now}) => DataPlanState(
    carrier: 'Airtel',
    name: 'SmartCash',
    planName: '6.5 GB',
    quotaMb: 6.5 * 1024,
    validityDays: 13,
    priceNaira: 1000,
    startedAt: now ?? DateTime.now(),
  );

  DateTime get endsAt => startedAt.add(Duration(days: validityDays));

  /// Upward jump in the carrier's remaining that reads as a fresh
  /// purchase: at least half the plan quota. Bonus crumbs and meter
  /// jitter stay well under it; a real bundle always clears it. Only
  /// upward jumps count — expiry and usage only move the number down.
  bool isTopUpJump(double prevTotalMb, double newTotalMb) =>
      quotaMb > 0 && newTotalMb - prevTotalMb >= quotaMb / 2;

  /// Adopt a detected purchase size as the new quota, snapped to whole
  /// half-gigabytes so the label stays clean ('6.5 GB', not '6.8 GB').
  static double snapQuota(double jumpMb) =>
      math.max(0.5 * 1024, (jumpMb / 512).round() * 512.0);

  /// Size label derived from a quota ('6.5 GB').
  static String quotaLabel(double mb) {
    final gb = mb / 1024;
    return gb == gb.roundToDouble() ? '${gb.round()} GB' : '$gb GB';
  }

  /// Quota as a setup-sheet field value ('6.5', '3').
  static String quotaFieldValue(double mb) {
    final gb = mb / 1024;
    return gb == gb.roundToDouble() ? '${gb.round()}' : gb.toStringAsFixed(1);
  }
  /// Ledger value comparable to [baselineMb] even across a billing
  /// rollover. Normally the live counter just grows past the baseline;
  /// but when it sits below it, the modem counter reset after the
  /// top-up, so the peaks archived since [startedAt] are added back on
  /// and the plan keeps counting instead of jumping back to full.
  double ledgerNow(double liveUsedMb, List<CycleUsage> past) {
    if (liveUsedMb >= baselineMb) return liveUsedMb;
    var acc = liveUsedMb;
    for (final cy in past) {
      if (!cy.lastAt.isBefore(startedAt)) acc += cy.usedMb;
    }
    return acc;
  }

  /// Ledger MB consumed since this bundle was logged. The modem
  /// counter never resets on purchase, so the baseline subtracts
  /// everything bought before.
  double usedSince(double liveUsedMb) =>
      math.max(0.0, liveUsedMb - baselineMb);

  double remainingMb(double liveUsedMb) => quotaMb - usedSince(liveUsedMb);

  int daysElapsed(DateTime now) =>
      math.max(0, now.difference(startedAt).inDays);

  int daysLeft(DateTime now) => validityDays - daysElapsed(now);

  double fracUsed(double liveUsedMb) =>
      quotaMb <= 0 ? 0 : usedSince(liveUsedMb) / quotaMb;

  double fracElapsed(DateTime now) =>
      validityDays <= 0 ? 0 : daysElapsed(now) / validityDays;

  /// Days of quota left at [burnMbPerDay]. Null when there is no
  /// measurable burn yet or nothing left to burn.
  double? daysUntilEmpty(double liveUsedMb, double burnMbPerDay) {
    if (burnMbPerDay <= 0) return null;
    final left = remainingMb(liveUsedMb);
    if (left <= 0) return null;
    return left / burnMbPerDay;
  }

  PlanVerdict verdict(double liveUsedMb, double burnMbPerDay, DateTime now) {
    if (remainingMb(liveUsedMb) <= 0) return PlanVerdict.exhausted;
    if (!endsAt.isAfter(now)) return PlanVerdict.expired;
    final empty = daysUntilEmpty(liveUsedMb, burnMbPerDay);
    if (empty == null) return PlanVerdict.warmingUp;
    final runsOut = now.add(Duration(hours: (empty * 24).round()));
    return runsOut.isAfter(endsAt)
        ? PlanVerdict.onTrack
        : PlanVerdict.burningFast;
  }

  /// Everything ever paid: the active bundle plus every archived one.
  double get totalSpent =>
      (priceNaira ?? 0) +
      history.fold<double>(0, (a, t) => a + (t.priceNaira ?? 0));

  /// Everything ever consumed under plan tracking, for the ₦/GB line.
  double usedAllTime(double liveUsedMb) =>
      usedSince(liveUsedMb) +
      history.fold<double>(0, (a, t) => a + t.consumedMb);

  /// Log a fresh bundle: the current plan archives with its measured
  /// consumption, and the baseline jumps to the live ledger value.
  /// The bundle name carries over unless a new one is given.
  DataPlanState logTopUp({
    required double quotaMb,
    double? priceNaira,
    String? planName,
    String? name,
    required double liveUsedMb,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final archived = PlanTopUp(
      date: startedAt,
      quotaMb: this.quotaMb,
      priceNaira: this.priceNaira,
      consumedMb: usedSince(liveUsedMb),
    );
    return DataPlanState(
      carrier: carrier,
      name: name ?? this.name,
      planName: planName ?? this.planName,
      quotaMb: quotaMb,
      validityDays: validityDays,
      priceNaira: priceNaira,
      startedAt: at,
      baselineMb: liveUsedMb,
      history: [archived, ...history].take(maxHistory).toList(),
    );
  }

  static DataPlanState? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return DataPlanState(
        carrier: '${j['carrier'] ?? ''}',
        name: '${j['name'] ?? ''}',
        planName: '${j['planName'] ?? ''}',
        quotaMb: (j['quotaMb'] as num?)?.toDouble() ?? 0,
        validityDays: (j['validityDays'] as num?)?.toInt() ?? 0,
        priceNaira: (j['priceNaira'] as num?)?.toDouble(),
        startedAt:
            DateTime.tryParse('${j['startedAt']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        baselineMb: (j['baselineMb'] as num?)?.toDouble() ?? 0,
        history: j['history'] is List
            ? (j['history'] as List)
                  .whereType<Map>()
                  .map((e) => PlanTopUp.fromJson(Map<String, dynamic>.from(e)))
                  .toList()
            : [],
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({
    'carrier': carrier,
    'name': name,
    'planName': planName,
    'quotaMb': quotaMb,
    'validityDays': validityDays,
    'priceNaira': priceNaira,
    'startedAt': startedAt.toIso8601String(),
    'baselineMb': baselineMb,
    'history': history.map((t) => t.toJson()).toList(),
  });

  static Future<DataPlanState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, encode());
  }
}
