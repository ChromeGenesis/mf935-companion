library;

/// Monthly data-usage ledger (SSOT): turns the firmware's cumulative
/// monthly counters (`monthly_rx_bytes` + `monthly_tx_bytes`) into a
/// history that survives billing-month rollovers and app restarts.
///
/// The modem resets its counter to zero when the carrier's month rolls
/// over (or the counter is reset manually); before this ledger existed,
/// that reset erased the only copy of the month's usage. Here every
/// poll samples the counter, a counter DROP beyond a small tolerance is
/// read as "the cycle closed", and the closed cycle is archived with
/// its peak — the best estimate of what the month really used, even if
/// the app never saw the exact final second. Pure records + a thin
/// SharedPreferences store, same shape as `speed_history.dart`.
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// 'Sep 28' — short locale-independent date for captions.
String shortDate(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// One observed billing cycle. [usedMb] is the peak cumulative total
/// seen (counters only grow within a cycle, so the peak is the month's
/// usage); [daily] maps `yyyy-MM-dd` to the last cumulative value seen
/// on that day, from which per-day deltas are derived.
class CycleUsage {
  final String id;

  /// First sample of this cycle. Only the real cycle start when
  /// [startKnown] — otherwise the app joined mid-cycle and [startedAt]
  /// is merely when tracking began.
  final DateTime startedAt;
  final DateTime lastAt;
  final double usedMb;
  final double rxMb;
  final double txMb;
  final Map<String, double> daily;

  /// True when we witnessed the counter reset that opened this cycle,
  /// so `startedAt` is the real first day (the first day's cumulative
  /// value is then attributable to that day).
  final bool startKnown;

  const CycleUsage({
    required this.id,
    required this.startedAt,
    required this.lastAt,
    required this.usedMb,
    required this.rxMb,
    required this.txMb,
    required this.daily,
    required this.startKnown,
  });

  /// 'Oct 2026' from the `yyyy-MM` id.
  String get label {
    final parts = id.split('-');
    if (parts.length != 2) return id;
    final m = int.tryParse(parts[1]);
    if (m == null || m < 1 || m > 12) return id;
    return '${_months[m - 1]} ${parts[0]}';
  }

  /// Days with at least one sample — the honest denominator for
  /// per-day averages (a calendar span would count days we slept
  /// through as usage days).
  int get daysObserved => math.max(1, daily.length);

  double get avgPerDayMb => usedMb / daysObserved;

  /// Rough end-of-month projection: average so far × calendar length
  /// of the month the cycle last reported in. Genuinely rough when
  /// [startKnown] is false (the first observed day then carries the
  /// pre-join usage), so the UI labels it as an estimate.
  double projectedMb() => avgPerDayMb * UsageHistory.daysInMonth(lastAt);

  /// Per-day usage derived from consecutive daily cumulatives. The
  /// first day's delta is only known when the cycle's start was
  /// witnessed ([startKnown]); otherwise it is 0 — attributing the
  /// pre-join total to one bar would be a lie.
  List<UsageDay> dailyDeltas() {
    final keys = daily.keys.toList()..sort();
    final out = <UsageDay>[];
    double? prev;
    for (final k in keys) {
      final cum = daily[k] ?? 0;
      final delta = prev == null
          ? (startKnown ? cum : 0.0)
          : math.max(0.0, cum - prev);
      prev = cum;
      out.add(UsageDay(day: DateTime.parse(k), mb: delta));
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'lastAt': lastAt.toIso8601String(),
    'usedMb': usedMb,
    'rxMb': rxMb,
    'txMb': txMb,
    'daily': daily,
    'startKnown': startKnown,
  };

  factory CycleUsage.fromJson(Map<String, dynamic> j) => CycleUsage(
    id: '${j['id'] ?? ''}',
    startedAt:
        DateTime.tryParse('${j['startedAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    lastAt:
        DateTime.tryParse('${j['lastAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    usedMb: (j['usedMb'] as num?)?.toDouble() ?? 0,
    rxMb: (j['rxMb'] as num?)?.toDouble() ?? 0,
    txMb: (j['txMb'] as num?)?.toDouble() ?? 0,
    daily: (j['daily'] is Map)
        ? (j['daily'] as Map).map(
            (k, v) => MapEntry('$k', (v as num?)?.toDouble() ?? 0),
          )
        : {},
    startKnown: j['startKnown'] == true,
  );
}

/// One day's derived usage (see [CycleUsage.dailyDeltas]).
class UsageDay {
  final DateTime day;
  final double mb;
  const UsageDay({required this.day, required this.mb});
}

/// Ledger: the live cycle plus archived ones (newest first). All
/// mutations are pure — [record] returns a new instance, `identical`
/// result means "nothing changed, don't rewrite storage".
class UsageHistory {
  static const key = 'usage_history_v1';

  /// Two years of monthly cycles is plenty; the records are tiny but
  /// the cap keeps a runaway `daily` map from growing forever.
  static const maxCycles = 24;

  /// Counter jitter tolerance: a dip within this margin is noise, not
  /// a reset (matches the poller's 1 MB rollover threshold).
  static const dropToleranceMb = 1.0;

  /// Kept per cycle: ~62 days covers even a doubled-up billing month.
  static const maxDaysPerCycle = 62;

  final CycleUsage? current;
  final List<CycleUsage> past;

  const UsageHistory({this.current, this.past = const []});

  const UsageHistory.empty() : current = null, past = const [];

  bool get hasData => current != null || past.isNotEmpty;

  /// Fold one counter sample in. [cumMb] is the firmware's monthly
  /// total (rx+tx), [rxMb]/[txMb] the individual sides. Callers must
  /// never fabricate a 0 for unreadable counters — an unparseable
  /// counter sampled as 0 would archive a healthy cycle as "rolled
  /// over" (see [parseMonthlyUsage]).
  UsageHistory record(
    double cumMb,
    double rxMb,
    double txMb,
    DateTime at, {
    double dropMb = dropToleranceMb,
  }) {
    if (cumMb.isNaN || cumMb.isInfinite || cumMb < 0) return this;
    final day = dayKey(at);
    final cur = current;
    if (cur == null) {
      return UsageHistory(
        current: CycleUsage(
          id: monthKey(at),
          startedAt: at,
          lastAt: at,
          usedMb: cumMb,
          rxMb: rxMb,
          txMb: txMb,
          daily: {day: cumMb},
          startKnown: false,
        ),
        past: past,
      );
    }
    if (cumMb >= cur.usedMb - 0.05) {
      // Same cycle, grew (or held steady): refresh the day's
      // cumulative and raise the peaks. rx/tx peak independently —
      // their sum may briefly disagree with the total peak, which is
      // fine, they are separate facts.
      return UsageHistory(
        current: CycleUsage(
          id: cur.id,
          startedAt: cur.startedAt,
          lastAt: at,
          usedMb: math.max(cur.usedMb, cumMb),
          rxMb: math.max(cur.rxMb, rxMb),
          txMb: math.max(cur.txMb, txMb),
          daily: _withDay(cur.daily, day, cumMb),
          startKnown: cur.startKnown,
        ),
        past: past,
      );
    }
    if (cur.usedMb - cumMb <= dropMb) return this; // jitter, not a reset
    // The counter dropped well below the peak: the cycle closed and a
    // new one opened (billing rollover, or a manual counter reset —
    // both close the ledger's cycle).
    return UsageHistory(
      current: CycleUsage(
        id: monthKey(at),
        startedAt: at,
        lastAt: at,
        usedMb: cumMb,
        rxMb: rxMb,
        txMb: txMb,
        daily: {day: cumMb},
        startKnown: true,
      ),
      past: [cur, ...past].take(maxCycles).toList(),
    );
  }

  Map<String, double> _withDay(Map<String, double> daily, String day, double cum) {
    final next = {...daily, day: cum};
    if (next.length <= maxDaysPerCycle) return next;
    final keys = next.keys.toList()..sort();
    for (final k in keys.take(next.length - maxDaysPerCycle)) {
      next.remove(k);
    }
    return next;
  }

  String encode() => jsonEncode({
    'current': current?.toJson(),
    'past': past.map((c) => c.toJson()).toList(),
  });

  /// Parse stored JSON. Never throws: a corrupt payload or a bad row
  /// degrades to "empty" instead of blocking launch.
  factory UsageHistory.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const UsageHistory.empty();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const UsageHistory.empty();
      CycleUsage? current;
      final cj = j['current'];
      if (cj is Map) {
        try {
          current = CycleUsage.fromJson(Map<String, dynamic>.from(cj));
        } catch (_) {}
      }
      final past = <CycleUsage>[];
      if (j['past'] is List) {
        for (final e in (j['past'] as List)) {
          if (e is! Map) continue;
          try {
            past.add(CycleUsage.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {
            // One bad row must not kill the whole history.
          }
        }
      }
      return UsageHistory(
        current: current,
        past: past.take(maxCycles).toList(),
      );
    } catch (_) {
      return const UsageHistory.empty();
    }
  }

  static Future<UsageHistory> load() async {
    final prefs = await SharedPreferences.getInstance();
    return UsageHistory.decode(prefs.getString(key));
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, encode());
  }

  /// Drop archived cycles only — the live cycle keeps tracking.
  UsageHistory clearedPast() => UsageHistory(current: current);

  // ── Key/label helpers (pure + tested) ───────────────────────────

  /// 'yyyy-MM-dd', locale-independent.
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 'yyyy-MM', locale-independent cycle id.
  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  static int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

  /// Monthly-counter sample guard: returns (totalMb, rxMb, txMb) only
  /// when the firmware actually reported the counters. An absent pair
  /// yields null — callers skip the sample rather than record a fake
  /// zero that could read as a rollover.
  static (double, double, double)? parseMonthlyUsage(Map<String, dynamic> s) {
    final rxRaw = '${s['monthly_rx_bytes'] ?? ''}';
    final txRaw = '${s['monthly_tx_bytes'] ?? ''}';
    if (rxRaw.isEmpty && txRaw.isEmpty) return null;
    final rx = (double.tryParse(rxRaw) ?? 0) / (1024 * 1024);
    final tx = (double.tryParse(txRaw) ?? 0) / (1024 * 1024);
    return (rx + tx, rx, tx);
  }
}
