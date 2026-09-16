library;

/// Signal-locator UI (SSOT): live RSRP/RSRQ/SINR readout + 3GPP-grounded
/// placement guidance. Two entry shells — [SignalLocatorBody] inside the
/// desktop glass modal, [SignalLocatorSheet] as the mobile bottom sheet.
/// One auto-refresh (5s) keeps the numbers live while the user walks the
/// router around; everything is cancellable and read-only.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/signal_locator.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_client.dart';

/// Shared content: metric cards + tips + how-to. The modal and the
/// bottom sheet render the identical [SignalLocatorContent].
class SignalLocatorBody extends StatefulWidget {
  final ValueNotifier<SignalSample?> signalFeed;
  final ZteClient client;

  const SignalLocatorBody({
    super.key,
    required this.signalFeed,
    required this.client,
  });

  @override
  State<SignalLocatorBody> createState() => _SignalLocatorBodyState();
}

class _SignalLocatorBodyState extends State<SignalLocatorBody> {
  Timer? _timer;
  bool _fetching = false;
  bool _manualBusy = false;

  /// Strongest RSRP (least negative dBm) seen while this tool is open.
  /// Session-scoped: walking the router around and watching the live
  /// reading beat — or miss — this mark is the whole walk-test.
  int? _bestRsrp;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Background polls are silent: no spinner, no layout churn — the
    // numbers + gauge just glide to their new values.
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_fetching || !mounted) return;
    _fetching = true;
    if (!silent) setState(() => _manualBusy = true);
    try {
      final s = await SignalSample.fromClient(widget.client);
      if (!mounted) return;
      if (s.rsrp != null && (_bestRsrp == null || s.rsrp! > _bestRsrp!)) {
        _bestRsrp = s.rsrp;
      }
      // One feed write rebuilds the content once — no busy-flag dance
      // on silent polls, so nothing flashes or shifts.
      widget.signalFeed.value = s;
    } catch (_) {
      // Read-only tool: a failed poll just leaves the last sample up.
    } finally {
      _fetching = false;
      if (!silent && mounted) setState(() => _manualBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SignalSample?>(
      valueListenable: widget.signalFeed,
      builder: (context, s, _) => SignalLocatorContent(
        sample: s,
        busy: _manualBusy,
        onRefresh: _refresh,
        bestRsrp: _bestRsrp,
      ),
    );
  }
}

/// Bottom-sheet shell (mobile): opaque card over the barrier, drag
/// handle, close affordance. Same content as the desktop modal. The
/// card uses a fully opaque surface (never translucent glass) so the
/// readout stays legible over the dimmed dashboard behind it. It
/// wraps its content — no fixed height, no dead space below short
/// readouts; tall ones scroll inside the sheet's own max height.
class SignalLocatorSheet extends StatelessWidget {
  final ValueNotifier<SignalSample?> signalFeed;
  final ZteClient client;

  const SignalLocatorSheet({
    super.key,
    required this.signalFeed,
    required this.client,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceLifted,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: c.textMuted.withAlpha(80),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c.accent.withAlpha(30),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: c.accent.withAlpha(90)),
                      ),
                      child: Icon(Icons.explore_outlined, size: 17, color: c.accentText),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Router signal locator',
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'RSRP · RSRQ · SINR placement analysis',
                            style: TextStyle(color: c.textMuted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, size: 18, color: c.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SignalLocatorBody(
                  signalFeed: signalFeed,
                  client: client,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The actual readout: animated hero gauge + three metric tiles +
/// guidance list + walk-test method. Read-only and honest — unknown
/// metrics say "not reported".
class SignalLocatorContent extends StatelessWidget {
  final SignalSample? sample;
  final bool busy;
  final VoidCallback onRefresh;

  /// Strongest RSRP seen while the tool is open (session best).
  final int? bestRsrp;

  const SignalLocatorContent({
    super.key,
    required this.sample,
    required this.busy,
    required this.onRefresh,
    this.bestRsrp,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final s = sample;
    final tips = s == null ? const <PlacementTip>[] : placementTips(s);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Hero gauge: at-a-glance reception + best-spot feedback ──
        Center(
          child: _SignalGauge(
            score: s == null ? null : signalOverallScore(s),
            rsrp: s?.rsrp,
            bestRsrp: bestRsrp,
          ),
        ),
        const SizedBox(height: 12),
        // ── Live metrics ──
        Row(
          children: [
            Icon(Icons.monitor_heart_outlined, size: 14, color: c.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                s == null
                    ? 'LIVE METRICS'
                    : 'LIVE METRICS · ${ZteClient.timeAgo(s.at)}',
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
            ),
            // Fixed 24px slot: spinner and icon occupy the same box,
            // so polls never shift the row (no flicker).
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : InkWell(
                        onTap: onRefresh,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.refresh,
                            size: 16,
                            color: c.accentText,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'RSRP',
                value: s?.rsrp == null ? '—' : '${s!.rsrp} dBm',
                quality: rsrpLabel(s?.rsrp),
                level: rsrpScore(s?.rsrp),
                detail: 'Reference signal power',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'RSRQ',
                value: s?.rsrq == null ? '—' : '${s!.rsrq} dB',
                quality: rsrqLabel(s?.rsrq),
                level: rsrqScore(s?.rsrq),
                detail: 'Signal quality / load',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'SINR',
                value: s?.sinr == null ? '—' : '${s!.sinr} dB',
                quality: sinrLabel(s?.sinr),
                level: sinrScore(s?.sinr),
                detail: 'Signal vs interference',
              ),
            ),
          ],
        ),

        // ── Guidance ──
        const SizedBox(height: 14),
        Text(
          'PLACEMENT GUIDANCE',
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 8),
        if (s == null)
          Text(
            'Log in to the MiFi to read live cellular metrics — the '
            'locator is read-only and never changes device settings.',
            style: TextStyle(color: c.textSecondary, fontSize: 12.5, height: 1.5),
          )
        else
          for (final tip in tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c.accent.withAlpha(22),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.accent.withAlpha(70)),
                    ),
                    child: Icon(tip.icon, size: 15, color: c.accentText),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tip.title,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tip.detail,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 11.5,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

        // ── Method (omnidirectional reality) ──
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.accent.withAlpha(14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.accent.withAlpha(50)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.directions_walk, size: 13, color: c.accentText),
                  const SizedBox(width: 6),
                  Text(
                    'Walk-test method (2 minutes)',
                    style: TextStyle(
                      color: c.accentText,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'The MF935 has omnidirectional antennas — it cannot point '
                'at a tower, so the tool teaches by measurement: (1) hold '
                'the router at chest height near a window and note RSRP; '
                '(2) move one meter at a time around the room, pausing ~10s '
                'at each spot for the reading to settle; (3) keep the spot '
                'with the highest RSRP, then fine-tune with quarter turns '
                'watching SINR/RSRQ — orientation shifts polarization '
                'against interference even when position is fixed.',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Hero reception gauge: an animated ring (1..5 overall score) with
/// the quality word + live RSRP in the middle and a best-spot chip
/// underneath. Walk the router around — the ring sweeps to each new
/// reading and the chip tells you whether this spot beats the session
/// best or trails it by N dB.
class _SignalGauge extends StatelessWidget {
  final double? score;
  final int? rsrp;
  final int? bestRsrp;

  const _SignalGauge({
    required this.score,
    required this.rsrp,
    required this.bestRsrp,
  });

  static Color _ringColor(double v, ZteColors c) {
    if (v >= 0.7) return c.live;
    if (v >= 0.45) return c.accentText;
    return c.danger;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final target = (score ?? 0) / 5.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 156,
          height: 156,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: target),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (ctx, v, _) {
              final col = score == null ? c.textMuted : _ringColor(v, c);
              return Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: score == null
                      ? null
                      : [
                          BoxShadow(
                            color: col.withAlpha(50),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 156,
                      height: 156,
                      child: CircularProgressIndicator(
                        value: 1,
                        strokeWidth: 12,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation(
                          c.textMuted.withAlpha(45),
                        ),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    SizedBox(
                      width: 156,
                      height: 156,
                      child: CircularProgressIndicator(
                        value: v,
                        strokeWidth: 12,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation(col),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            overallLabel(score),
                            maxLines: 1,
                            style: TextStyle(
                              color: col,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            rsrp == null ? '—' : '$rsrp dBm',
                            maxLines: 1,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Text(
                          'RSRP',
                          style: TextStyle(
                            color: c.textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        _BestChip(rsrp: rsrp, bestRsrp: bestRsrp),
        const SizedBox(height: 4),
        Text(
          'Walk the router room to room — the ring follows live signal.',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

/// Session-best chip: gold "Best spot" while the live reading holds
/// the mark, amber "N dB off best" when it trails. Hidden until the
/// first RSRP lands.
class _BestChip extends StatelessWidget {
  final int? rsrp;
  final int? bestRsrp;

  const _BestChip({required this.rsrp, required this.bestRsrp});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final live = rsrp;
    if (live == null) return const SizedBox.shrink();
    final isBest = bestRsrp == null || live >= bestRsrp!;
    final color = isBest ? c.live : c.accentText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBest ? Icons.emoji_events_outlined : Icons.trending_down,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            isBest
                ? 'Best spot · $live dBm'
                : '${bestRsrp! - live} dB off best ($live dBm)',
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// One metric: label, big value, quality word + score bars.
class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String quality;
  final int level;
  final String detail;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.quality,
    required this.level,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final color = level < 0
        ? c.textMuted
        : level <= 2
        ? c.danger
        : level == 3
        ? c.accent
        : c.live;
    return Tooltip(
      message: detail,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: c.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Flexible(
                  child: Text(
                    quality,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                SignalBars(level: level, height: 10),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
