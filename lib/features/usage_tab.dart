library;

/// Data tab (SSOT): the monthly-usage page. Hero ring + stats for the
/// live billing cycle, a per-day bar chart derived from the ledger's
/// daily cumulatives, a down/up split, and the archived-months history
/// that survives every counter reset. Numbers come from the persisted
/// [UsageHistory] feed (poller-fed); pull-to-refresh samples the
/// counters directly so the page is truthful the moment it is opened.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/dialogs.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/usage_history.dart';
import '../core/zte_client.dart';

class UsageTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final ValueListenable<UsageHistory> usageFeed;

  /// The alert line (MB) — also the poller's low-data threshold.
  final double? alertMb;
  final ValueChanged<double?> onAlertChanged;

  /// Feed one manual-refresh sample into the ledger (same path the
  /// poller uses), so pull-to-refresh updates everything at once.
  final void Function(double totalMb, double rxMb, double txMb) onSample;

  /// Archive-only wipe, owned by the dashboard (it owns the feed).
  final VoidCallback onClearHistory;
  final void Function(String) log;

  const UsageTab({
    super.key,
    required this.client,
    required this.connected,
    required this.usageFeed,
    required this.alertMb,
    required this.onAlertChanged,
    required this.onSample,
    required this.onClearHistory,
    required this.log,
  });

  @override
  State<UsageTab> createState() => _UsageTabState();
}

class _UsageTabState extends State<UsageTab> {
  bool _busy = false;

  Future<void> _refresh() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final t = await widget.client.getTrafficStats();
      final sample = UsageHistory.parseMonthlyUsage(t);
      if (!mounted) return;
      if (sample != null) {
        widget.onSample(sample.$1, sample.$2, sample.$3);
        widget.log('usage counters refreshed');
      } else {
        widget.log('usage refresh: modem reported no counters');
      }
    } catch (e) {
      if (!mounted) return;
      widget.log('usage refresh failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAlert() async {
    final c = context.zc;
    final ctrl = TextEditingController(
      text: widget.alertMb == null
          ? ''
          : (widget.alertMb! / 1024).toStringAsFixed(
              widget.alertMb! < 1024 ? 1 : 0,
            ),
    );
    final res = await showGlassModal<({bool save, double? mb})>(
      context,
      icon: Icons.notifications_active_outlined,
      title: 'Usage alert line',
      subtitle: 'One notification per cycle when usage crosses it',
      body: StatefulBuilder(
        builder: (ctx, setModal) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Alert me when this cycle reaches',
                style: TextStyle(color: c.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setModal(() {}),
                decoration: const InputDecoration(suffixText: 'GB'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final gb in const [5, 10, 20, 40, 60, 100])
                    GestureDetector(
                      onTap: () => setModal(() => ctrl.text = '$gb'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: c.chip,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: c.chipBorder),
                        ),
                        child: Text(
                          '$gb GB',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'The line also arms the monthly usage notification '
                'from the monitor.',
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ],
          );
        },
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(const (save: false, mb: null)),
          child: const Text('Cancel'),
        ),
        if (widget.alertMb != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const (save: true, mb: null)),
            child: const Text('Remove'),
          ),
        ElevatedButton(
          onPressed: double.tryParse(ctrl.text.trim()) == null
              ? null
              : () => Navigator.of(context).pop((
                  save: true,
                  mb: double.tryParse(ctrl.text.trim())! * 1024,
                )),
          child: const Text('Save'),
        ),
      ],
    );
    if (res == null || !res.save) return;
    widget.onAlertChanged(res.mb);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UsageHistory>(
      valueListenable: widget.usageFeed,
      builder: (context, usage, _) {
        final cur = usage.current;
        return RefreshIndicator(
          color: context.zc.accentText,
          backgroundColor: context.zc.surfaceLifted,
          onRefresh: _refresh,
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            children: [
              _heroCard(cur),
              const SizedBox(height: 16),
              const SectionLabel('Day by day'),
              _dailyChartCard(cur),
              const SizedBox(height: 16),
              const SectionLabel('Previous months'),
              _historyCard(usage),
            ],
          ),
        );
      },
    );
  }

  // ── Hero ──────────────────────────────────────────────────────────

  Widget _heroCard(CycleUsage? cur) {
    final c = context.zc;
    return GlassCard(
      highlighted: widget.connected && cur != null,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cur == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: EmptyState(
                icon: Icons.data_usage,
                title: 'No usage observed yet',
                subtitle: 'The ledger fills as the poller samples the '
                    'modem — log in to start tracking.',
              ),
            )
          else
            LayoutBuilder(
              builder: (ctx, cons) {
                final wide = cons.maxWidth > 480;
                final ring = _UsageRing(
                  usedMb: cur.usedMb,
                  capMb: widget.alertMb,
                );
                final stamp = Text(
                  'sampled ${_ago(cur.lastAt)}',
                  style: TextStyle(color: c.textMuted, fontSize: 10.5),
                );
                final body = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cur.startKnown
                          ? '${cur.label} cycle · since ${shortDate(cur.startedAt)}'
                          : '${cur.label} cycle · tracking began '
                              '${shortDate(cur.startedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _chipGrid(cur),
                    const SizedBox(height: 12),
                    _splitBar(cur),
                  ],
                );
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [ring, const SizedBox(height: 8), stamp],
                      ),
                      const SizedBox(width: 14),
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        color: c.borderSubtle,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: body),
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: Column(children: [ring, const SizedBox(height: 8), stamp])),
                    const SizedBox(height: 14),
                    body,
                  ],
                );
              },
            ),
          Divider(color: c.borderSubtle, height: 22),
          // Alert line row: the ring's denominator and the monitor's
          // low-data notification share this one setting.
          InkWell(
            onTap: _editAlert,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    widget.alertMb == null
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_active_outlined,
                    size: 15,
                    color: widget.alertMb == null
                        ? c.textMuted
                        : c.accentText,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.alertMb == null
                          ? 'No alert line — tap to set one'
                          : 'Alert at ${ZteClient.formatDataVolume(widget.alertMb!)}',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipGrid(CycleUsage cur) {
    final peak = _peakDay(cur);
    final chips = [
      ('average', '${ZteClient.formatDataVolume(cur.avgPerDayMb)}/day'),
      ('month-end estimate', '~${ZteClient.formatDataVolume(cur.projectedMb())}'),
      ('days with data', '${cur.daysObserved}'),
      ('peak day', peak),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < 2; row++) ...[
          if (row > 0) const SizedBox(height: 6),
          Row(
            children: [
              for (var col = 0; col < 2; col++) ...[
                if (col > 0) const SizedBox(width: 6),
                Expanded(child: _chip(chips[row * 2 + col].$1, chips[row * 2 + col].$2)),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _chip(String caption, String value) {
    final c = context.zc;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.chip,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _peakDay(CycleUsage cur) {
    UsageDay? best;
    for (final d in cur.dailyDeltas()) {
      if (best == null || d.mb > best.mb) best = d;
    }
    if (best == null || best.mb <= 0) return '—';
    return '${shortDate(best.day)} · ${ZteClient.formatDataVolume(best.mb)}';
  }

  /// Down vs up split of the cycle: green = down, amber = up.
  Widget _splitBar(CycleUsage cur) {
    final c = context.zc;
    final total = cur.rxMb + cur.txMb;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: total <= 0
                ? Container(color: c.textMuted.withAlpha(40))
                : Row(
                    children: [
                      Expanded(
                        flex: (cur.rxMb / total * 1000).round().clamp(1, 999),
                        child: Container(color: c.live),
                      ),
                      Expanded(
                        flex: (cur.txMb / total * 1000).round().clamp(1, 999),
                        child: Container(color: c.accent),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            _splitLegend(c, c.live, Icons.south, ZteClient.formatDataVolume(cur.rxMb)),
            const SizedBox(width: 14),
            _splitLegend(c, c.accent, Icons.north, ZteClient.formatDataVolume(cur.txMb)),
            const Spacer(),
            Text(
              total <= 0 ? 'no split yet' : 'of this cycle',
              style: TextStyle(color: c.textMuted, fontSize: 10.5),
            ),
          ],
        ),
      ],
    );
  }

  Widget _splitLegend(ZteColors c, Color color, IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // ── Daily chart ───────────────────────────────────────────────────

  Widget _dailyChartCard(CycleUsage? cur) {
    final c = context.zc;
    final days = cur?.dailyDeltas() ?? const <UsageDay>[];
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: days.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: EmptyState(
                icon: Icons.bar_chart,
                title: 'No daily bars yet',
                subtitle: 'Bars appear as the poller samples the counter '
                    'across two or more days of the cycle.',
              ),
            )
          : LayoutBuilder(
              builder: (ctx, cons) {
                final maxMb = days.fold<double>(1.0, (m, d) => d.mb > m ? d.mb : m);
                final avgMb = cur!.avgPerDayMb;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'max ${ZteClient.formatDataVolume(maxMb)}',
                          style: TextStyle(color: c.textMuted, fontSize: 10.5),
                        ),
                        const Spacer(),
                        Text(
                          'avg ${ZteClient.formatDataVolume(avgMb)}/day',
                          style: TextStyle(color: c.textMuted, fontSize: 10.5),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 132,
                      child: Stack(
                        children: [
                          // Average line sits behind the bars.
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: (avgMb / maxMb).clamp(0.02, 0.98) * 132,
                            child: Container(
                              height: 1,
                              color: c.textMuted.withAlpha(110),
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < days.length; i++)
                                Expanded(
                                  child: Tooltip(
                                    message:
                                        '${shortDate(days[i].day)} · ${ZteClient.formatDataVolume(days[i].mb)}',
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 1,
                                      ),
                                      height: days[i].mb <= 0
                                          ? 2
                                          : 4 +
                                              (days[i].mb / maxMb) *
                                                  (132 - 4),
                                      decoration: BoxDecoration(
                                        color: i == days.length - 1
                                            ? c.accentText
                                            : c.accent.withAlpha(150),
                                        borderRadius: const BorderRadius.vertical(
                                          top: Radius.circular(3),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (var i = 0; i < days.length; i++)
                          Expanded(
                            child: Text(
                              _dayLabel(days, i),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              style: TextStyle(
                                color: i == days.length - 1
                                    ? c.accentText
                                    : c.textMuted,
                                fontSize: 9.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
    );
  }

  /// Sparse x labels: first, last, and every 5th day.
  String _dayLabel(List<UsageDay> days, int i) {
    if (i == 0 || i == days.length - 1 || (i + 1) % 5 == 0) {
      return '${days[i].day.day}';
    }
    return '';
  }

  // ── History ───────────────────────────────────────────────────────

  Widget _historyCard(UsageHistory usage) {
    final c = context.zc;
    final past = usage.past;
    if (past.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.all(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: EmptyState(
            icon: Icons.history,
            title: 'No archived months yet',
            subtitle: 'When the carrier resets the counter into a new '
                'cycle, the finished month is archived here — it is '
                'never thrown away.',
          ),
        ),
      );
    }
    final maxMb = past.fold<double>(1.0, (m, cy) => cy.usedMb > m ? cy.usedMb : m);
    final total = past.fold<double>(0, (a, cy) => a + cy.usedMb);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < past.length; i++) ...[
            if (i > 0) Divider(color: c.borderSubtle, height: 22),
            _MonthRow(cycle: past[i], maxMb: maxMb),
          ],
          Divider(color: c.borderSubtle, height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${past.length} month${past.length == 1 ? '' : 's'} '
                  'tracked · ${ZteClient.formatDataVolume(total)} total',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final ok = await confirmAction(
                    context,
                    icon: Icons.history,
                    title: 'Clear usage history?',
                    message:
                        'All archived months are deleted. The live cycle '
                        'keeps tracking, and future rollovers archive '
                        'again.',
                    confirmLabel: 'Clear',
                  );
                  if (ok) widget.onClearHistory();
                },
                child: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 90) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// One archived month: label + value + a bar scaled to the biggest
/// archived month, with the honest "ended / averaged" caption.
class _MonthRow extends StatelessWidget {
  final CycleUsage cycle;
  final double maxMb;

  const _MonthRow({required this.cycle, required this.maxMb});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: c.accent.withAlpha(26),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: c.accent.withAlpha(80)),
              ),
              child: Icon(Icons.calendar_month, size: 15, color: c.accentText),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cycle.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'ended ${shortDate(cycle.lastAt)} · '
                    '${cycle.daysObserved}d · avg '
                    '${ZteClient.formatDataVolume(cycle.avgPerDayMb)}/day',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              ZteClient.formatDataVolume(cycle.usedMb),
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 5,
            child: Stack(
              children: [
                Container(color: c.textMuted.withAlpha(30)),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (cycle.usedMb / maxMb).clamp(0.02, 1.0),
                  child: Container(color: c.accent.withAlpha(170)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The hero ring. Sweep is the used fraction of the alert line; with
/// no line set the ring stays a quiet track and the number speaks for
/// itself (no fake denominator). Crosses to red at 90%.
class _UsageRing extends StatelessWidget {
  final double usedMb;
  final double? capMb;

  const _UsageRing({required this.usedMb, required this.capMb});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    const size = 156.0;
    final frac = (capMb == null || capMb! <= 0)
        ? null
        : usedMb / capMb!;
    final color = frac == null
        ? c.accent
        : frac >= 1
        ? c.danger
        : frac >= 0.9
        ? c.danger
        : c.accent;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: (frac ?? 0).clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (ctx, sweep, _) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(size, size),
              painter: _RingPainter(
                sweep: sweep,
                track: c.textMuted.withAlpha(42),
                arc: color,
              ),
            ),
            SizedBox(
              width: size * 0.7,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      ZteClient.formatDataVolume(usedMb),
                      maxLines: 1,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    capMb == null
                        ? 'this cycle'
                        : '${(frac! * 100).clamp(0, 999).toStringAsFixed(0)}% of '
                            '${ZteClient.formatDataVolume(capMb!)}',
                    maxLines: 1,
                    style: TextStyle(
                      color: frac != null && frac >= 0.9 ? c.danger : c.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  /// 0..1 fraction of the circle to sweep; 0 draws track only.
  final double sweep;
  final Color track;
  final Color arc;

  _RingPainter({required this.sweep, required this.track, required this.arc});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 11.0;
    final inset = stroke / 2 + 1;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, 2 * 3.141592653589793, false, trackPaint);
    if (sweep <= 0) return;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = arc;
    canvas.drawArc(rect, -3.141592653589793 / 2, 2 * 3.141592653589793 * sweep,
        false, arcPaint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.sweep != sweep || old.arc != arc || old.track != track;
}
