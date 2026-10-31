library;

/// Data-usage page (SSOT): full-screen route in the One UI idiom — a
/// cycle-range selector, one big "used" number, a cumulative area chart
/// with 50%/100% gridlines, a down/up breakdown list, and the archived
/// months as tappable rows that re-aim the whole page at that cycle.
/// Opened from the Status hero's metric strip and the Info tab's traffic
/// statistics — deliberately NOT a nav tab.
///
/// Numbers come from the persisted [UsageHistory] feed (poller-fed);
/// pull-to-refresh samples the counters directly.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/usage_history.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

class UsagePage extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final ValueListenable<UsageHistory> usageFeed;

  /// The alert line (MB) — also the poller's low-data threshold.
  final ValueListenable<double?> alertFeed;
  final ValueChanged<double?> onAlertChanged;

  /// Feed one manual-refresh sample into the ledger (same path the
  /// poller uses), so pull-to-refresh updates everything at once.
  final void Function(double totalMb, double rxMb, double txMb) onSample;

  /// Archive-only wipe, owned by the dashboard (it owns the feed).
  final VoidCallback onClearHistory;
  final void Function(String) log;

  const UsagePage({
    super.key,
    required this.client,
    required this.connected,
    required this.usageFeed,
    required this.alertFeed,
    required this.onAlertChanged,
    required this.onSample,
    required this.onClearHistory,
    required this.log,
  });

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  bool _busy = false;

  /// 0 = the live cycle, 1..n = past[ n - 1 ]. Tapping a history row
  /// re-aims the whole page (hero, chart, breakdown) at that month.
  int _selected = 0;

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

  Future<void> _pickCycle(List<CycleUsage> past) async {
    final c = context.zc;
    final live = widget.usageFeed.value.current;
    final entries = <(int, CycleUsage, bool)>[
      if (live != null) (0, live, true),
      for (var i = 0; i < past.length; i++) (i + 1, past[i], false),
    ];
    final picked = await showGlassModal<int>(
      context,
      icon: Icons.event_outlined,
      title: 'Cycle',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(entries[i].$1),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _selected == entries[i].$1
                      ? c.accent.withAlpha(36)
                      : c.chip,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selected == entries[i].$1
                        ? c.accent.withAlpha(110)
                        : c.borderSubtle,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${shortDate(entries[i].$2.startedAt)} – '
                            '${shortDate(entries[i].$2.lastAt)}',
                            style: TextStyle(
                              color: _selected == entries[i].$1
                                  ? c.accentText
                                  : c.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            entries[i].$3
                                ? 'current cycle · live'
                                : '${entries[i].$2.label} · ended '
                                    '${shortDate(entries[i].$2.lastAt)}',
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_selected == entries[i].$1)
                      Icon(Icons.check_circle, size: 18, color: c.accentText),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (picked == null) return;
    setState(() => _selected = picked);
  }

  Future<void> _editAlert() async {
    final c = context.zc;
    final current = widget.alertFeed.value;
    final ctrl = TextEditingController(
      text: current == null
          ? ''
          : (current / 1024).toStringAsFixed(current < 1024 ? 1 : 0),
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
                'Alert me when the cycle reaches',
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
          onPressed: () =>
              Navigator.of(context).pop(const (save: false, mb: null)),
          child: const Text('Cancel'),
        ),
        if (current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const (save: true, mb: null)),
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
    final c = context.zc;
    return Scaffold(
      backgroundColor: c.scaffold,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: ZSystemUI.overlay(context),
        child: AmbientBackground(
          child: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              color: c.accentText,
              backgroundColor: c.surfaceLifted,
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    systemOverlayStyle: ZSystemUI.overlay(context),
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    pinned: true,
                    title: Text(
                      'Data usage',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Refresh',
                        onPressed: _busy ? null : _refresh,
                        icon: Icon(Icons.refresh, color: c.accentText),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    sliver: SliverList.list(
                      children: [
                        ValueListenableBuilder<UsageHistory>(
                          valueListenable: widget.usageFeed,
                          builder: (context, usage, _) {
                            final past = usage.past;
                            if (_selected > past.length) {
                              // History was cleared under us: snap home.
                              _selected = 0;
                            }
                            final live = usage.current;
                            final view = _selected == 0
                                ? live
                                : past[_selected - 1];
                            return ValueListenableBuilder<double?>(
                              valueListenable: widget.alertFeed,
                              builder: (context, alertMb, _) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (past.isNotEmpty || live != null)
                                    _cyclePill(live, past),
                                  const SizedBox(height: 10),
                                  _heroCard(view, alertMb),
                                  const SizedBox(height: 12),
                                  _chartCard(view),
                                  const SizedBox(height: 12),
                                  _breakdownCard(view),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Measured by the MiFi monthly counter. '
                                    'It resets at each billing rollover — '
                                    'finished months are archived below.',
                                    style: TextStyle(
                                      color: c.textMuted,
                                      fontSize: 11.5,
                                      height: 1.45,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  if (past.isNotEmpty) ...[
                                    const SectionLabel('Previous months'),
                                    _historyCard(past),
                                    const SizedBox(height: 12),
                                  ],
                                  _alertCard(alertMb),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Cycle selector pill ("Oct 3 – 31 ▾") ──────────────────────────

  Widget _cyclePill(CycleUsage? live, List<CycleUsage> past) {
    final c = context.zc;
    String range(int index) {
      final cy = index == 0 ? live! : past[index - 1];
      final end = index == 0 ? DateTime.now() : cy.lastAt;
      return '${shortDate(cy.startedAt)} – ${shortDate(end)}';
    }

    // A cleared ledger can leave the selection pointing at "live" while
    // only archived cycles exist — fall through to the newest archive.
    var sel = _selected;
    if (sel == 0 && live == null && past.isNotEmpty) sel = 1;
    final label = range(sel);
    return GestureDetector(
      onTap: () => _pickCycle(past),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: c.surface.withAlpha(70),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.event_outlined, size: 16, color: c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(Icons.expand_more, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
  }

  // ── Hero: big "used" number ───────────────────────────────────────

  Widget _heroCard(CycleUsage? view, double? alertMb) {
    final c = context.zc;
    if (view == null) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: EmptyState(
            icon: Icons.data_usage,
            title: 'No usage observed yet',
            subtitle: 'The ledger fills as the poller samples the '
                'modem — log in to start tracking.',
          ),
        ),
      );
    }
    final isLive = _selected == 0;
    final showAlert = isLive && alertMb != null && alertMb > 0;
    final frac = showAlert ? (view.usedMb / alertMb).clamp(0.0, 1.0) : null;
    final overLine = showAlert && view.usedMb >= alertMb;
    final lineColor = overLine || (frac ?? 0) >= 0.9 ? c.danger : c.accent;

    // One muted caption carries the numbers that only mean something
    // once the cycle has a couple of days behind it.
    final caption = StringBuffer();
    if (isLive) {
      caption.write('cycle since ${shortDate(view.startedAt)} · ');
      caption.write('sampled ${_ago(view.lastAt)}');
    } else {
      caption.write('ended ${shortDate(view.lastAt)} · ');
      caption.write('${view.daysObserved} day${view.daysObserved == 1 ? '' : 's'} '
          'with data');
    }
    if (view.daysObserved >= 2) {
      caption.write(
        ' · avg ${ZteClient.formatDataVolume(view.avgPerDayMb)}/day'
        ' · projects ~${ZteClient.formatDataVolume(view.projectedMb())}',
      );
    }

    return GlassCard(
      highlighted: widget.connected && isLive,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  ZteClient.formatDataVolume(view.usedMb),
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 40,
                    height: 1.0,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'used',
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (showAlert)
                Text(
                  '${(frac! * 100).clamp(0, 999).toStringAsFixed(0)}% '
                  'of ${ZteClient.formatDataVolume(alertMb)}',
                  style: TextStyle(
                    color: overLine || frac >= 0.9 ? c.danger : c.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (showAlert) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Stack(
                  children: [
                    Container(color: c.textMuted.withAlpha(36)),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: frac!.clamp(0.01, 1.0),
                      child: Container(color: lineColor),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            caption.toString(),
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  // ── Cumulative area chart (One UI style) ──────────────────────────

  Widget _chartCard(CycleUsage? view) {
    final c = context.zc;
    final points = <(DateTime, double)>[];
    if (view != null) {
      final days = view.daily.keys.toList()..sort();
      for (final k in days) {
        final d = DateTime.parse(k);
        if (points.isNotEmpty && d.isBefore(points.first.$1)) continue;
        points.add((d, view.daily[k] ?? 0));
      }
    }
    final enough = points.length >= 2;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
      child: enough
          ? LayoutBuilder(
              builder: (ctx, cons) {
                final first = points.first.$1;
                final last = points.last.$1;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 190,
                      child: CustomPaint(
                        painter: _CumulativePainter(
                          points: points,
                          line: c.accent,
                          fillTop: c.accent.withAlpha(115),
                          fillBottom: c.accent.withAlpha(12),
                          grid: c.textMuted.withAlpha(90),
                          label: c.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(right: 34),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            shortDate(first),
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                          Text(
                            shortDate(last),
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            )
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: EmptyState(
                icon: Icons.show_chart,
                title: 'The curve appears after two days',
                subtitle: 'Cumulative usage is plotted as the poller '
                    'samples the counter across the cycle.',
              ),
            ),
    );
  }

  // ── Down/up breakdown list ────────────────────────────────────────

  Widget _breakdownCard(CycleUsage? view) {
    final c = context.zc;
    if (view == null || (view.rxMb <= 0 && view.txMb <= 0)) {
      return const SizedBox.shrink();
    }
    final maxSide = view.rxMb > view.txMb ? view.rxMb : view.txMb;
    Widget row(IconData icon, String label, double mb, Color color) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                ZteClient.formatDataVolume(mb),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: Stack(
                children: [
                  Container(color: c.textMuted.withAlpha(30)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (mb / maxSide).clamp(0.02, 1.0),
                    child: Container(color: color),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(Icons.south, 'Downloaded', view.rxMb, c.live),
          const SizedBox(height: 14),
          row(Icons.north, 'Uploaded', view.txMb, c.accent),
        ],
      ),
    );
  }

  // ── Archived months (One UI list rows) ────────────────────────────

  Widget _historyCard(List<CycleUsage> past) {
    final c = context.zc;
    final maxMb = past.fold<double>(
      1.0,
      (m, cy) => cy.usedMb > m ? cy.usedMb : m,
    );
    final total = past.fold<double>(0, (a, cy) => a + cy.usedMb);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < past.length; i++) ...[
            if (i > 0) Divider(color: c.borderSubtle, height: 1),
            _MonthRow(
              cycle: past[i],
              maxMb: maxMb,
              selected: _selected == i + 1,
              onTap: () => setState(() => _selected = i + 1),
            ),
          ],
          Divider(color: c.borderSubtle, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
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
          ),
        ],
      ),
    );
  }

  Widget _alertCard(double? alertMb) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: _editAlert,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                alertMb == null
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_active_outlined,
                size: 16,
                color: alertMb == null ? c.textMuted : c.accentText,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  alertMb == null
                      ? 'No alert line — tap to set one'
                      : 'Alert at ${ZteClient.formatDataVolume(alertMb)}',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
            ],
          ),
        ),
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

/// One archived month, One UI list style: icon chip, title + caption,
/// value right, thin share-of-max bar. Tap re-aims the page at it.
class _MonthRow extends StatelessWidget {
  final CycleUsage cycle;
  final double maxMb;
  final bool selected;
  final VoidCallback onTap;

  const _MonthRow({
    required this.cycle,
    required this.maxMb,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: selected
                        ? c.accent.withAlpha(46)
                        : c.accent.withAlpha(22),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: selected
                          ? c.accent.withAlpha(130)
                          : c.accent.withAlpha(70),
                    ),
                  ),
                  child: Icon(
                    selected ? Icons.calendar_month : Icons.calendar_today,
                    size: 15,
                    color: c.accentText,
                  ),
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
                        'ended ${shortDate(cycle.lastAt)} · avg '
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
                height: 4,
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
        ),
      ),
    );
  }
}

/// Cumulative area chart: usage climbs left → right across the cycle,
/// gridlines at 0/50/100% of the cycle's peak with % labels on the
/// right edge (One UI data-usage idiom), amber gradient fill.
class _CumulativePainter extends CustomPainter {
  final List<(DateTime, double)> points;
  final Color line;
  final Color fillTop;
  final Color fillBottom;
  final Color grid;
  final Color label;

  _CumulativePainter({
    required this.points,
    required this.line,
    required this.fillTop,
    required this.fillBottom,
    required this.grid,
    required this.label,
  });

  static const _left = 4.0;
  static const _right = 38.0; // % labels on the right edge
  static const _top = 6.0;
  static const _bottom = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final chartW = size.width - _left - _right;
    final chartH = size.height - _top - _bottom;
    final spanDays = points.last.$1.difference(points.first.$1).inDays;
    final span = spanDays < 1 ? 1 : spanDays;
    final maxMb = points.fold<double>(
      0.001,
      (m, p) => p.$2 > m ? p.$2 : m,
    );

    Offset xy(int i) {
      final day = points[i].$1.difference(points.first.$1).inDays;
      final x = _left + (day / span) * chartW;
      final y = _top + (1 - points[i].$2 / maxMb) * chartH;
      return Offset(x, y);
    }

    // Gridlines + % labels at 100 / 50 / 0.
    final gridPaint = Paint()
      ..strokeWidth = 1
      ..color = grid;
    for (final f in const [1.0, 0.5, 0.0]) {
      final y = _top + (1 - f) * chartH;
      canvas.drawLine(Offset(_left, y), Offset(_left + chartW, y), gridPaint);
      _label(
        canvas,
        '${(f * 100).round()}%',
        Offset(_left + chartW + 6, y),
      );
    }

    final path = Path()..moveTo(xy(0).dx, xy(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(xy(i).dx, xy(i).dy);
    }
    final area = Path.from(path)
      ..lineTo(xy(points.length - 1).dx, _top + chartH)
      ..lineTo(xy(0).dx, _top + chartH)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fillTop, fillBottom],
        ).createShader(Rect.fromLTWH(_left, _top, chartW, chartH)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = line,
    );
  }

  void _label(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: label, fontSize: 10.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at.translate(0, -tp.height / 2));
  }

  @override
  bool shouldRepaint(_CumulativePainter old) =>
      old.points.length != points.length ||
      old.line != line ||
      old.grid != grid;
}
