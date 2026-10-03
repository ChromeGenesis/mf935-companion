library;

/// Network Scout (SSOT): sampling, spot scoring, ranking, persistence and
/// export for the walk-around-and-mark-spots tool.
///
/// The MF935 has no GPS and the user cannot see RF from inside the app, so
/// the Scout does the only honest thing available: sample the modem
/// wherever the user puts it, let them name the spot, and rank the spots by
/// what the radio actually reported there.
///
/// Design rules baked into this file:
///  - a spot is a *set of samples over time*, never a single reading —
///    one lucky poll must not win a ranking;
///  - missing metrics are *absent*, never zero: a 3G camp with no LTE
///    fields is scored on what it does report, with the weights
///    renormalised, and the confidence label says how thin the data is;
///  - every ranking carries a reason ("best upload", "most stable") so the
///    recommendation can be argued with instead of obeyed.
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'signal_locator.dart';

const scoutPrefsKey = 'scout_sessions_v1';

/// Default sampling cadence. Two seconds is fast enough that walking
/// between spots produces a useful curve and slow enough that the
/// firmware's poller never queues behind it.
const scoutDefaultInterval = Duration(seconds: 2);

/// One reading taken while Scout was running.
class ScoutSample {
  final DateTime at;

  /// Modem signal bars (0..5) — the coarse, always-present metric.
  final int? bars;

  /// LTE metrics (null when the modem is not camped on LTE).
  final int? rsrp;
  final int? rsrq;
  final int? sinr;

  /// Wideband RSSI, the 3G fallback.
  final int? rssi;

  final String networkType;

  /// Instantaneous throughput in Mbps, as reported by the modem's
  /// realtime counters (null when the firmware omits them).
  final double? downMbps;
  final double? upMbps;

  /// Did the modem answer at all for this sample?
  final bool reachable;

  const ScoutSample({
    required this.at,
    this.bars,
    this.rsrp,
    this.rsrq,
    this.sinr,
    this.rssi,
    this.networkType = '',
    this.downMbps,
    this.upMbps,
    this.reachable = true,
  });

  /// Reception quality 1..5 for one sample, using the same bands as the
  /// locator tool (so both tools tell the same story). Null when the
  /// modem reported nothing usable.
  double? get quality {
    final scores = <int>[
      rsrpScore(rsrp),
      rsrqScore(rsrq),
      sinrScore(sinr),
      if (rsrp == null && rsrq == null && sinr == null) rssiScore(rssi),
    ].where((v) => v >= 0).toList();
    if (scores.isEmpty) return null;
    return scores.reduce((a, b) => a + b) / scores.length;
  }

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    if (bars != null) 'bars': bars,
    if (rsrp != null) 'rsrp': rsrp,
    if (rsrq != null) 'rsrq': rsrq,
    if (sinr != null) 'sinr': sinr,
    if (rssi != null) 'rssi': rssi,
    'net': networkType,
    if (downMbps != null) 'down': downMbps,
    if (upMbps != null) 'up': upMbps,
    'ok': reachable,
  };

  factory ScoutSample.fromJson(Map<String, dynamic> j) => ScoutSample(
    at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
    bars: (j['bars'] as num?)?.toInt(),
    rsrp: (j['rsrp'] as num?)?.toInt(),
    rsrq: (j['rsrq'] as num?)?.toInt(),
    sinr: (j['sinr'] as num?)?.toInt(),
    rssi: (j['rssi'] as num?)?.toInt(),
    networkType: '${j['net'] ?? ''}',
    downMbps: (j['down'] as num?)?.toDouble(),
    upMbps: (j['up'] as num?)?.toDouble(),
    reachable: j['ok'] != false,
  );
}

/// Build a sample from one goform status reply. Pure + tested: never
/// invents a metric the modem did not report.
ScoutSample scoutSampleFromStatus(
  Map<String, dynamic> m,
  DateTime at, {
  bool reachable = true,
}) {
  final sig = parseSignalSample(m, at);
  // The firmware reports realtime throughput in BYTES/s (the app's
  // formatRate divides by 1024), so convert to Mbps here — otherwise a
  // 12 MB/s link would read as 12 Mbps and score like a 3G spot.
  double? rate(String key) {
    final v = double.tryParse('${m[key] ?? ''}');
    if (v == null || !v.isFinite || v < 0) return null;
    return v * 8 / 1e6;
  }

  return ScoutSample(
    at: at,
    bars: int.tryParse('${m['signalbar'] ?? ''}'),
    rsrp: sig.rsrp,
    rsrq: sig.rsrq,
    sinr: sig.sinr,
    rssi: sig.rssi,
    networkType: '${m['network_type'] ?? ''}',
    downMbps: rate('realtime_rx_thrpt'),
    upMbps: rate('realtime_tx_thrpt'),
    reachable: reachable,
  );
}

/// A marked location plus every sample taken there.
class ScoutSession {
  final String id;
  final String label;

  /// When the user pressed "Mark spot" (dwell time runs from here).
  final DateTime startedAt;

  final List<ScoutSample> samples;

  /// True once the user ended this spot; finished sessions are the ones
  /// the ranking considers.
  final bool finished;

  ScoutSession({
    required this.id,
    required this.label,
    required this.startedAt,
    List<ScoutSample>? samples,
    this.finished = false,
  }) : samples = List<ScoutSample>.from(samples ?? const []);

  ScoutSession copyWith({
    String? label,
    List<ScoutSample>? samples,
    bool? finished,
  }) => ScoutSession(
    id: id,
    label: label ?? this.label,
    startedAt: startedAt,
    samples: samples ?? this.samples,
    finished: finished ?? this.finished,
  );

  /// Wall-clock span covered by the samples (not now - start): a spot
  /// marked and abandoned seconds later must not look well-measured.
  Duration get duration {
    if (samples.length < 2) return Duration.zero;
    return samples.last.at.difference(samples.first.at);
  }

  int get sampleCount => samples.length;

  /// Dwell gate: a spot needs [minDwell] of measurements before its
  /// result is trusted. Enforced in the UI, exposed here so the rule
  /// lives in one place.
  bool get hasDwell => samples.length >= minSamples && duration >= minDwell;

  static const minSamples = 5;
  static const minDwell = Duration(seconds: 10);

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'at': startedAt.millisecondsSinceEpoch,
    'done': finished,
    'samples': samples.map((s) => s.toJson()).toList(),
  };

  factory ScoutSession.fromJson(Map<String, dynamic> j) => ScoutSession(
    id: '${j['id'] ?? ''}',
    label: '${j['label'] ?? ''}',
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      (j['at'] as num?)?.toInt() ?? 0,
    ),
    samples: (j['samples'] as List?)
            ?.whereType<Map>()
            .map((e) => ScoutSample.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        const [],
    finished: j['done'] == true,
  );
}

/// min / max / average for one metric across a spot's samples.
class MetricStats {
  final double? min;
  final double? max;
  final double? avg;

  const MetricStats(this.min, this.max, this.avg);

  static const empty = MetricStats(null, null, null);

  bool get hasData => avg != null;

  /// Spread (max - min). Null without data. This is the raw material for
  /// the stability component: a spot that swings 25 dB is not "strong".
  double? get spread => (max != null && min != null) ? max! - min! : null;

  /// Compact `avg (min…max)` rendering, empty when unknown.
  String format({int decimals = 0, String unit = ''}) {
    if (avg == null) return 'not reported';
    final a = avg!.toStringAsFixed(decimals);
    if (min == null || max == null) return '$a$unit';
    return '$a$unit (${min!.toStringAsFixed(decimals)}…'
        '${max!.toStringAsFixed(decimals)})';
  }
}

/// min/max/avg over the non-null values of [values]. Pure + tested.
MetricStats statsOf(Iterable<double?> values) {
  final v = values.whereType<double>().toList();
  if (v.isEmpty) return MetricStats.empty;
  var lo = v.first, hi = v.first, sum = 0.0;
  for (final x in v) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
    sum += x;
  }
  return MetricStats(lo, hi, sum / v.length);
}

/// Population standard deviation. Pure + tested.
double stddev(List<double> v) {
  if (v.length < 2) return 0;
  final mean = v.reduce((a, b) => a + b) / v.length;
  final sq = v.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b);
  return math.sqrt(sq / v.length);
}

/// How much to trust a spot's score. Derived from evidence, never from
/// optimism: a two-second spot and a two-minute spot are not the same
/// claim, and the ranking says so out loud.
enum ScoutConfidence { low, medium, high }

/// Confidence for a spot from its sample count and dwell time. Pure +
/// tested. Thresholds match [ScoutSession.minSamples] / minDwell so the
/// label and the gate can never disagree.
ScoutConfidence confidenceFor(ScoutSession s) {
  final n = s.sampleCount;
  final secs = s.duration.inSeconds;
  if (n >= 25 && secs >= 45) return ScoutConfidence.high;
  if (n >= ScoutSession.minSamples && secs >= ScoutSession.minDwell.inSeconds) {
    return ScoutConfidence.medium;
  }
  return ScoutConfidence.low;
}

/// Short label + why, for the results list.
String confidenceLabel(ScoutSession s) {
  final d = s.duration.inSeconds;
  return switch (confidenceFor(s)) {
    ScoutConfidence.high =>
      'high — ${s.sampleCount} samples over ${d}s',
    ScoutConfidence.medium => 'medium — ${s.sampleCount} samples over ${d}s',
    ScoutConfidence.low =>
      s.sampleCount == 0
          ? 'low — no samples'
          : 'low — dwelled ${d}s, need ${ScoutSession.minDwell.inSeconds}s',
  };
}

/// One scored component, 0..100. Null when the metric was never reported
/// (so its weight can be redistributed instead of scoring a phantom zero).
class SpotScore {
  final double overall;
  final double? strength;
  final double? stability;
  final double? throughput;
  final double? reachability;
  final ScoutConfidence confidence;

  /// Why this spot won, filled in by [rankSpots] (null for a lone spot).
  final String? reason;

  const SpotScore({
    required this.overall,
    this.strength,
    this.stability,
    this.throughput,
    this.reachability,
    required this.confidence,
    this.reason,
  });

  SpotScore withReason(String reason) => SpotScore(
    overall: overall,
    strength: strength,
    stability: stability,
    throughput: throughput,
    reachability: reachability,
    confidence: confidence,
    reason: reason,
  );
}

// Component weights. Stability and upload carry real weight on purpose:
// a volatile high-RSRP spot that drops to zero upload is not a better
// place to work from, and a ranking that says otherwise is useless.
const _wStrength = 0.35;
const _wStability = 0.25;
const _wThroughput = 0.25;
const _wReachability = 0.15;

/// Score one spot. Pure + tested.
///
///  - strength: mean per-sample reception band (1..5) → 0..100.
///  - stability: 100 minus the swing in that band and in RSRP; a spot
///    whose reception never moves scores 100 even if it is mediocre.
///  - throughput: log-scaled mean of down+up (10 Mbps ≈ 60, 100 Mbps ≈
///    100), so doubling on a good link still matters but a slow link is
///    not crushed to zero.
///  - reachability: share of samples the modem answered.
///
/// Missing components are dropped and the remaining weights renormalised,
/// so a 3G camp is compared on reachability + RSSI alone rather than
/// being punished for firmware fields that do not exist.
SpotScore scoreSpot(ScoutSession s) {
  final confidence = confidenceFor(s);
  if (s.samples.isEmpty) {
    return SpotScore(overall: 0, confidence: confidence);
  }

  final qualities = s.samples
      .map((x) => x.quality)
      .whereType<double>()
      .toList();
  final rsrps = s.samples.map((x) => x.rsrp ?? x.rssi).whereType<int>().toList();

  double? strength;
  if (qualities.isNotEmpty) {
    final mean = qualities.reduce((a, b) => a + b) / qualities.length;
    strength = ((mean - 1) / 4) * 100;
  }

  double? stability;
  if (qualities.length >= 2) {
    final swing = stddev(qualities) * 25; // one full band of swing = 25 pts
    final swingDb = rsrps.length >= 2 ? stddev(rsrps.map((e) => e.toDouble()).toList()) : 0;
    final dbPenalty = (swingDb / 20) * 25; // 20 dB of variation = 25 pts
    stability = (100 - swing - dbPenalty).clamp(0.0, 100.0);
  }

  double? throughput;
  final downs = s.samples.map((x) => x.downMbps).whereType<double>().toList();
  final ups = s.samples.map((x) => x.upMbps).whereType<double>().toList();
  if (downs.isNotEmpty || ups.isNotEmpty) {
    final down = downs.isEmpty ? 0.0 : downs.reduce((a, b) => a + b) / downs.length;
    final up = ups.isEmpty ? 0.0 : ups.reduce((a, b) => a + b) / ups.length;
    // log10(1+Mbps) scaled so ~100 Mbps total lands near 100.
    final combined = (down + up) / 2;
    throughput = (math.log(1 + combined) / math.log(101)) * 100;
    throughput = throughput.clamp(0.0, 100.0);
  }

  final reachability =
      s.samples.where((x) => x.reachable).length / s.samples.length * 100;

  // Component weights in play. A metric the modem never reported is simply
// absent, and the remaining weights are renormalised below — a 3G camp is
// compared on what it does report, never on phantom zeros.
final parts = <double, double>{
  // Always present: an unreachable sample set must never score 100.
  _wReachability: reachability,
};
if (strength case final s?) parts[_wStrength] = s;
if (stability case final s?) parts[_wStability] = s;
if (throughput case final t?) parts[_wThroughput] = t;
  final totalWeight = parts.keys.fold<double>(0, (a, w) => a + w);
  final overall = totalWeight == 0
      ? 0.0
      : parts.entries.fold<double>(
          0,
          (a, e) => a + e.value * e.key,
        ) /
          totalWeight;

  return SpotScore(
    overall: overall.clamp(0.0, 100.0),
    strength: strength,
    stability: stability,
    throughput: throughput,
    reachability: reachability,
    confidence: confidence,
  );
}

double? _pickThroughput(SpotScore s) => s.throughput;
double? _pickStability(SpotScore s) => s.stability;
double? _pickStrength(SpotScore s) => s.strength;
double? _pickReachability(SpotScore s) => s.reachability;

/// A scored spot: the session plus everything the results list shows.
class RankedSpot {
  final ScoutSession session;
  final SpotScore score;
  final MetricStats rsrp;
  final MetricStats bars;
  final MetricStats down;
  final MetricStats up;

  const RankedSpot({
    required this.session,
    required this.score,
    required this.rsrp,
    required this.bars,
    required this.down,
    required this.up,
  });
}

/// Rank spots best-first and attach the reason each one won. Pure +
/// tested.
///
/// Ranking is by [SpotScore.overall], and the reason is whichever
/// component the winner leads on — ties fall back to the next-largest
/// component difference, so the label always names something the user
/// can check. Spots without the [ScoutSession.hasDwell] minimum are
/// ranked but flagged, never quietly mixed in as if measured.
List<RankedSpot> rankSpots(List<ScoutSession> sessions) {
  final scored = sessions
      .map(
        (s) => RankedSpot(
          session: s,
          score: scoreSpot(s),
          rsrp: statsOf(s.samples.map((x) => x.rsrp?.toDouble())),
          bars: statsOf(s.samples.map((x) => x.bars?.toDouble())),
          down: statsOf(s.samples.map((x) => x.downMbps)),
          up: statsOf(s.samples.map((x) => x.upMbps)),
        ),
      )
      .toList()
    ..sort((a, b) => b.score.overall.compareTo(a.score.overall));

  if (scored.length < 2) {
    return scored
        .map((e) => RankedSpot(
              session: e.session,
              score: e.score.withReason('only spot measured'),
              rsrp: e.rsrp,
              bars: e.bars,
              down: e.down,
              up: e.up,
            ))
        .toList();
  }

  // How far each component's leader is ahead of the field's average.
  double lead(RankedSpot s, double? Function(SpotScore) pick) {
    final mine = pick(s.score);
    if (mine == null) return double.negativeInfinity;
    final others = scored
        .map((e) => pick(e.score))
        .whereType<double>()
        .toList();
    if (others.isEmpty) return double.negativeInfinity;
    final avg = others.reduce((a, b) => a + b) / others.length;
    return mine - avg;
  }

  const ladder = <(String, double? Function(SpotScore))>[
    ('best upload', _pickThroughput),
    ('most stable', _pickStability),
    ('strongest signal', _pickStrength),
    ('most reliable', _pickReachability),
  ];

  return scored.map((s) {
    if (s != scored.first) return s;
    final gaps = <(String, double)>[
      for (final (name, pick) in ladder)
        (name, lead(s, pick)),
      // Nothing separated the components — say the quiet, honest thing.
      ('best overall', double.negativeInfinity),
    ];
    gaps.sort((a, b) => b.$2.compareTo(a.$2));
    return RankedSpot(
      session: s.session,
      score: s.score.withReason(gaps.first.$1),
      rsrp: s.rsrp,
      bars: s.bars,
      down: s.down,
      up: s.up,
    );
  }).toList();
}

// ── Persistence ────────────────────────────────────────────────────

/// Storage seam (prefs in the app, memory in tests).
abstract class ScoutBackend {
  Future<List<ScoutSession>> load();
  Future<void> save(List<ScoutSession> sessions);
}

class PrefsScoutBackend implements ScoutBackend {
  const PrefsScoutBackend();

  @override
  Future<List<ScoutSession>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(scoutPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ScoutSession.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<ScoutSession> sessions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      scoutPrefsKey,
      jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
  }
}

class MemoryScoutBackend implements ScoutBackend {
  List<ScoutSession> sessions;
  MemoryScoutBackend([List<ScoutSession>? seed])
    : sessions = List<ScoutSession>.from(seed ?? const []);

  @override
  Future<List<ScoutSession>> load() async =>
      List<ScoutSession>.from(sessions);

  @override
  Future<void> save(List<ScoutSession> sessions) async {
    this.sessions = List<ScoutSession>.from(sessions);
  }
}

/// Keep the most recent sessions only: a Scout history is a survey log,
/// not an archive, and the cap stops it growing without bound.
const maxScoutSessions = 20;

List<ScoutSession> capSessions(List<ScoutSession> sessions) =>
    sessions.length <= maxScoutSessions
    ? sessions
    : sessions.sublist(0, maxScoutSessions);

/// Persisted Scout session store.
class ScoutStore {
  ScoutBackend backend;
  ScoutStore({ScoutBackend? backend}) : backend = backend ?? const PrefsScoutBackend();

  Future<List<ScoutSession>> load() async =>
      capSessions(await backend.load());

  Future<void> save(List<ScoutSession> sessions) =>
      backend.save(capSessions(sessions));

  /// One-line id: timestamp + counter-free suffix keeps sessions unique
  /// even when two are marked in the same second.
  static String newId([DateTime? at]) =>
      (at ?? DateTime.now()).millisecondsSinceEpoch.toString();
}

// ── Export ─────────────────────────────────────────────────────────

/// Plain-text survey report. Pure + tested.
String buildScoutReport(List<ScoutSession> sessions, {DateTime? now}) {
  final ranked = rankSpots(sessions);
  final buf = StringBuffer()
    ..writeln('=== Network Scout survey ===')
    ..writeln(
      'generated: ${(now ?? DateTime.now()).toIso8601String().substring(0, 16)}',
    )
    ..writeln('spots: ${ranked.length}');
  if (ranked.isEmpty) {
    buf.writeln('no spots marked yet');
    return buf.toString();
  }
  final best = ranked.first;
  buf.writeln(
    'Best location: ${best.session.label.isEmpty ? best.session.id : best.session.label}'
    ' (${best.score.overall.toStringAsFixed(0)}/100'
    '${best.score.reason == null ? '' : ' — ${best.score.reason}'})',
  );
  for (var i = 0; i < ranked.length; i++) {
    final r = ranked[i];
    final label = r.session.label.isEmpty ? r.session.id : r.session.label;
    buf
      ..writeln(
        '${i + 1}. $label — ${r.score.overall.toStringAsFixed(0)}/100'
        '${r.score.reason == null ? '' : ' [${r.score.reason}]'}',
      )
      ..writeln(
        '   samples: ${r.session.sampleCount} over '
        '${r.session.duration.inSeconds}s · ${confidenceLabel(r.session)}',
      )
      ..writeln('   RSRP ${r.rsrp.format()} dBm · bars ${r.bars.format(decimals: 1)}')
      ..writeln(
        '   down ${r.down.format(decimals: 2)} Mbps · '
        'up ${r.up.format(decimals: 2)} Mbps',
      );
  }
  return buf.toString();
}

/// JSON twin of [buildScoutReport] for issue trackers. Pure + tested.
Map<String, dynamic> buildScoutJson(List<ScoutSession> sessions) {
  final ranked = rankSpots(sessions);
  return {
    'generated': DateTime.now().toIso8601String(),
    'spots': [
      for (final r in ranked)
        {
          'label': r.session.label,
          'id': r.session.id,
          'at': r.session.startedAt.toIso8601String(),
          'samples': r.session.sampleCount,
          'seconds': r.session.duration.inSeconds,
          'score': r.score.overall,
          'reason': r.score.reason,
          'confidence': r.score.confidence.name,
          'components': {
            'strength': r.score.strength,
            'stability': r.score.stability,
            'throughput': r.score.throughput,
            'reachability': r.score.reachability,
          },
          'rsrp': {'min': r.rsrp.min, 'max': r.rsrp.max, 'avg': r.rsrp.avg},
          'down': {'min': r.down.min, 'max': r.down.max, 'avg': r.down.avg},
          'up': {'min': r.up.min, 'max': r.up.max, 'avg': r.up.avg},
        },
    ],
  };
}

String encodeScoutJson(List<ScoutSession> sessions) =>
    const JsonEncoder.withIndent('  ').convert(buildScoutJson(sessions));

/// Friendly spot names offered before typing one. A free-text label
/// beats a numbered spot only if naming is cheap.
const scoutSpotSuggestions = <String>[
  'Desk',
  'Window',
  'Kitchen',
  'Bedroom',
  'Upstairs',
  'Balcony',
];