/// Signal locator (SSOT): RSRP/RSRQ/SINR acquisition for the router
/// placement tool. Polls the modem's LTE metric endpoint; falls back to
/// RSSI-only (3G mode) when the LTE fields are absent. Guidance is
/// grounded in industry-standard 3GPP metric interpretation (TS 36.214
/// / TS 36.133 thresholds), never heuristics.
library;

import 'package:flutter/material.dart' show IconData, Icons;

import '../core/zte_client.dart';

/// One live cellular reading with the standard LTE quality metrics.
class SignalSample {
  final DateTime at;

  /// Reference Signal Received Power, dBm (resource-element level).
  /// null when the modem did not report it.
  final int? rsrp;

  /// Reference Signal Received Quality, dB (RSRP/RSSI ratio). null when
  /// the modem did not report it.
  final int? rsrq;

  /// Signal to Interference + Noise Ratio, dB. null when the modem did
  /// not report it.
  final int? sinr;

  /// Received Signal Strength Indicator, dBm (wideband). Always
  /// available on this firmware family; the fallback metric.
  final int? rssi;

  const SignalSample({
    required this.at,
    this.rsrp,
    this.rsrq,
    this.sinr,
    this.rssi,
  });

  /// Fetch the current metrics from the modem. LTE fields are
  /// best-effort — 3G/2G camps report RSSI only, which is normal.
  static Future<SignalSample> fromClient(ZteClient client) async {
    final m = await client.getStatus(
      cmds: const ['lte_rsrp', 'lte_rsrq', 'lte_snr', 'rssi', 'network_type'],
    );
    int? dbm(String key) {
      final v = int.tryParse('${m[key] ?? ''}'.replaceAll('.0', ''));
      // Firmware sentinel: 0 or implausible values mean "not reported".
      if (v == null || v == 0 || v < -150 || v > 0) return null;
      return v;
    }

    return SignalSample(
      at: DateTime.now(),
      rsrp: dbm('lte_rsrp'),
      rsrq: dbm('lte_rsrq'),
      sinr: () {
        final v = int.tryParse('${m['lte_snr'] ?? ''}'.replaceAll('.0', ''));
        if (v == null || v == 0) return null;
        return v;
      }(),
      rssi: dbm('rssi'),
    );
  }
}

/// Standard 3GPP-aligned interpretation bands (TS 36.214 definitions,
/// thresholds per the industry conventions used by drive-test tools):
/// - RSRP: > -80 excellent, -80..-90 good, -90..-100 fair, < -100 poor
/// - RSRQ: > -10 excellent, -10..-15 good, -15..-20 fair, < -20 poor
/// - SINR: > 20 excellent, 13..20 good, 6..13 fair, < 6 poor
String rsrpLabel(int? v) {
  if (v == null) return 'not reported';
  if (v >= -80) return 'Excellent';
  if (v >= -90) return 'Good';
  if (v >= -100) return 'Fair';
  return 'Poor';
}

String rsrqLabel(int? v) {
  if (v == null) return 'not reported';
  if (v >= -10) return 'Excellent';
  if (v >= -15) return 'Good';
  if (v >= -20) return 'Fair';
  return 'Poor';
}

String sinrLabel(int? v) {
  if (v == null) return 'not reported';
  if (v >= 20) return 'Excellent';
  if (v >= 13) return 'Good';
  if (v >= 6) return 'Fair';
  return 'Poor';
}

/// 0..5 score for a single metric (null = -1 unknown). Mirrors the
/// dashboard signal-bar mapping so the tool and the hero agree.
int rsrpScore(int? v) {
  if (v == null) return -1;
  if (v >= -80) return 5;
  if (v >= -90) return 4;
  if (v >= -100) return 3;
  if (v >= -110) return 2;
  return 1;
}

int rsrqScore(int? v) {
  if (v == null) return -1;
  if (v >= -10) return 5;
  if (v >= -15) return 4;
  if (v >= -20) return 3;
  return 2;
}

int sinrScore(int? v) {
  if (v == null) return -1;
  if (v >= 20) return 5;
  if (v >= 13) return 4;
  if (v >= 6) return 3;
  return 2;
}

/// Overall 1..5 reception score: the mean of the reported metric bands
/// (RSRP/RSRQ/SINR), ignoring unreported ones so a 3G camp's missing
/// LTE fields never drag the average down. Null when the modem
/// reported nothing usable — the gauge then shows its idle state.
/// Pure + tested; drives the locator's animated hero ring.
double? signalOverallScore(SignalSample s) {
  final scores = <int>[
    rsrpScore(s.rsrp),
    rsrqScore(s.rsrq),
    sinrScore(s.sinr),
  ].where((v) => v >= 0).toList();
  if (scores.isEmpty) return null;
  return scores.reduce((a, b) => a + b) / scores.length;
}

/// Quality word for an overall score band (matches the per-metric
/// Excellent/Good/Fair/Poor vocabulary).
String overallLabel(double? score) {
  if (score == null) return 'Waiting';
  if (score >= 4.5) return 'Excellent';
  if (score >= 3.5) return 'Good';
  if (score >= 2.5) return 'Fair';
  return 'Poor';
}

/// One directional placement suggestion.
class PlacementTip {
  final IconData icon;
  final String title;
  final String detail;

  const PlacementTip({
    required this.icon,
    required this.title,
    required this.detail,
  });
}

/// Omnidirectional placement guidance derived from the current metric
/// set. The MF935 is a battery MiFi with omnidirectional internal
/// antennas: it cannot beam-steer, so guidance is about *position and
/// orientation relative to the serving cell* — which direction the
/// signal comes from can be learned by walking the router and watching
/// RSRP move (empirical, standards-consistent with 3GPP's own
/// measurement definitions: the metric IS the location's truth).
///
/// Rules grounded in the metric semantics:
/// - RSRP is power-limited → move toward fewer/less dense obstructions.
/// - RSRQ is interference-limited → moving often matters less than
///   re-orienting away from interference sources (microwaves, USB3).
/// - SINR combines both → the tie-breaker when RSRP is fine but
///   throughput is not.
List<PlacementTip> placementTips(SignalSample s) {
  final tips = <PlacementTip>[];
  final rsrp = s.rsrp;
  final rsrq = s.rsrq;
  final sinr = s.sinr;
  final rssi = s.rssi;

  // No LTE metrics at all: we are likely on 3G — say so honestly.
  if (rsrp == null && rsrq == null && sinr == null) {
    if (rssi != null) {
      tips.add(
        PlacementTip(
          icon: Icons.info_outline,
          title: 'LTE metrics unavailable',
          detail:
              'The modem did not report RSRP/RSRQ/SINR (device may be '
              'camped on 3G/2G). Only wideband RSSI is available: '
              'positioning advice below uses that weaker proxy. Move the '
              'router and watch the value — higher (less negative) dBm '
              'is better.',
        ),
      );
      if (rssi >= -70) {
        tips.add(
          PlacementTip(
            icon: Icons.check_circle_outline,
            title: 'RSSI is strong ($rssi dBm)',
            detail: 'Keep the current spot; RSSI ≥ −70 dBm rarely limits '
                'throughput by itself.',
          ),
        );
      }
      return tips;
    }
    return const [
      PlacementTip(
        icon: Icons.help_outline,
        title: 'No signal data',
        detail: 'Log in to the MiFi to read live cellular metrics.',
      ),
    ];
  }

  // ── RSRP-driven (power): the dominant placement metric. ──
  if (rsrp != null) {
    if (rsrp >= -80) {
      tips.add(
        PlacementTip(
          icon: Icons.check_circle_outline,
          title: 'RSRP excellent ($rsrp dBm)',
          detail:
              'Reference-signal power is strong — no placement change '
              'needed for coverage. Optimize for RSRQ/SINR only if '
              'throughput still disappoints.',
        ),
      );
    } else if (rsrp >= -90) {
      tips.add(
        PlacementTip(
          icon: Icons.explore_outlined,
          title: 'RSRP good ($rsrp dBm)',
          detail:
              'Solid coverage. There is 5–10 dB of headroom to gain by '
              'moving the router a few meters toward a window or an '
              'exterior wall on the side of town that faces the tower.',
        ),
      );
    } else if (rsrp >= -100) {
      tips.add(
        PlacementTip(
          icon: Icons.arrow_outward,
          title: 'RSRP fair ($rsrp dBm) — move it',
          detail:
              'Power-limited. Place the router higher and nearer a '
              'window, away from interior walls; each meter counts at '
              'this level. Try different rooms — indoor loss varies '
              '10–20 dB between spots.',
        ),
      );
    } else {
      tips.add(
        PlacementTip(
          icon: Icons.warning_amber_outlined,
          title: 'RSRP poor ($rsrp dBm) — placement critical',
          detail:
              'At this level the signal is at cell edge. Windowsills, '
              'balconies or, best, an elevated spot near the wall '
              'facing the strongest outdoor signal. Even 5–10 dB of '
              'placement gain transforms the connection.',
        ),
      );
    }
  }

  // ── RSRQ-driven (interference): matters when power is fine. ──
  if (rsrq != null && rsrq < -15) {
    tips.add(
      PlacementTip(
        icon: Icons.wifi_tethering_off_outlined,
        title: 'RSRQ degraded ($rsrq dB)',
        detail:
            'Reference-signal quality is interference-limited, not '
            'power-limited. Re-position away from interference '
            'sources — microwave ovens, USB 3.0 docks, other routers — '
            'and try rotating the device 90°: the internal antennas '
            'are polarized.',
      ),
    );
  }

  // ── SINR tie-breaker. ──
  if (sinr != null && sinr < 6) {
    tips.add(
      PlacementTip(
        icon: Icons.graphic_eq_outlined,
        title: 'SINR low ($sinr dB)',
        detail:
            'Signal is drowning in interference/noise even though raw '
            'power may look acceptable. Higher placement (above desk '
            'and clutter level) usually lifts SINR before RSRP does.',
      ),
    );
  }

  // ── Coherence check: fine power but bad quality is the classic
  //    "you are close to a strong interferer / serving cell is far but
  //    another cell bleeds in" signature. ──
  if (rsrp != null && rsrp >= -85 && (rsrq != null && rsrq < -15 || sinr != null && sinr < 6)) {
    tips.add(
      const PlacementTip(
        icon: Icons.compare_arrows_outlined,
        title: 'Strong but volatile — re-orient',
        detail:
            'Power is fine yet quality metrics lag: a neighboring cell '
            'or in-room interferer dominates. Rotate the router a '
            'quarter turn and re-measure; orientation can add several '
            'dB of SINR without moving a single meter.',
      ),
    );
  }

  if (tips.isEmpty) {
    tips.add(
      const PlacementTip(
        icon: Icons.check_circle_outline,
        title: 'All metrics healthy',
        detail:
            'RSRP, RSRQ and SINR are all in their good-or-better bands. '
            'Placement is not the limiting factor — remaining variance '
            'is network-side (congestion, backhaul).',
      ),
    );
  }
  return tips;
}
