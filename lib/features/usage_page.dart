library;

/// Data-usage page (SSOT): full-screen route in the One UI idiom: a
/// cycle-range selector, one big "used" number, a plan card (bought vs
/// used, derived automatically), a cumulative area chart with a labeled
/// forecast, and the archived months as tappable rows that re-aim the
/// whole page at that cycle. An all-time breakdown opens from the
/// totals footer. Opened from the Status hero's metric strip and the
/// Info tab's traffic statistics — deliberately NOT a nav tab.
///
/// Numbers come from the persisted [UsageHistory] feed (poller-fed)
/// plus the [DataPlanState] feed (entered once, derived forever);
/// pull-to-refresh samples the counters directly.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/data_plan.dart';
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

  /// Plan tracking (entered once, derived forever after) + the
  /// carrier balance snapshot for the plan card's cross-check.
  final ValueListenable<DataPlanState?> planFeed;
  final ValueListenable<DataBalance?> balanceFeed;
  final ValueChanged<DataPlanState?> onPlanChanged;

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
    required this.planFeed,
    required this.balanceFeed,
    required this.onPlanChanged,
    required this.onSample,
    required this.onClearHistory,
    required this.log,
  });

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  bool _busy = false;

  /// Nigeria's carriers today, with room for whatever comes next via
  /// the "Other" slot in the plan setup sheet.
  static const carriers = ['Airtel', 'MTN', 'Glo', '9mobile'];

  /// 0 = the live cycle, 1..n = past[ n - 1 ]. Tapping a history row
  /// re-aims the whole page (hero, chart, breakdown) at that month.
  int _selected = 0;

  /// Plan card folded away. Persisted — a hidden card stays hidden
  /// across visits until asked back.
  bool _planCollapsed = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final collapsed = prefs.getBool('plan_collapsed') ?? false;
      if (mounted && collapsed != _planCollapsed) {
        setState(() => _planCollapsed = collapsed);
      }
    });
  }

  void _togglePlanCollapsed() {
    setState(() => _planCollapsed = !_planCollapsed);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool('plan_collapsed', _planCollapsed),
    );
  }

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
                            '${shortDate(entries[i].$2.startedAt)} to '
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
    // NOTE: no ctrl.dispose() here — the pop transition still owns the
    // focused field for a frame after the future completes; disposing
    // synchronously crashes with "used after being disposed". The
    // dialog-local controller is garbage-collected with the route.
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
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
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
                            // Per-card listeners: a balance or alert tick only
                            // rebuilds the cards that read it. The whole
                            // page used to rebuild on every feed change,
                            // re-running the chart parse + history rows
                            // for a single alert-line tap.
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (past.isNotEmpty || live != null)
                                  _cyclePill(live, past),
                                const SizedBox(height: 10),
                                ValueListenableBuilder<double?>(
                                  valueListenable: widget.alertFeed,
                                  builder: (context, alertMb, _) =>
                                      ValueListenableBuilder<DataPlanState?>(
                                    valueListenable: widget.planFeed,
                                    builder: (context, plan, _) =>
                                        _heroCard(view, alertMb, plan),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ValueListenableBuilder<DataPlanState?>(
                                  valueListenable: widget.planFeed,
                                  builder: (context, plan, _) =>
                                      ValueListenableBuilder<DataBalance?>(
                                    valueListenable: widget.balanceFeed,
                                    builder: (context, balance, _) =>
                                        _planCard(plan, usage, balance),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _chartCard(view),
                                const SizedBox(height: 12),
                                ValueListenableBuilder<DataPlanState?>(
                                  valueListenable: widget.planFeed,
                                  builder: (context, plan, _) => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (past.isNotEmpty ||
                                          live != null) ...[
                                        _allTimeEntry(usage, plan),
                                        const SizedBox(height: 12),
                                      ],
                                      if (past.isNotEmpty) ...[
                                        const SectionLabel(
                                            'Previous months'),
                                        _historyCard(past),
                                        const SizedBox(height: 12),
                                      ],
                                    ],
                                  ),
                                ),
                                ValueListenableBuilder<double?>(
                                  valueListenable: widget.alertFeed,
                                  builder: (context, alertMb, _) =>
                                      _alertCard(alertMb),
                                ),
                              ],
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

  // ── Cycle selector pill ("Oct 1 to 20") ──────────────────────────

  /// 'Oct 1 to 20' within one month, 'Sep 28 to Oct 27' across months.
  /// A single observed day collapses to one date ('Nov 3').
  String _rangeLabel(DateTime a, DateTime b) {
    if (a.year == b.year && a.month == b.month && a.day == b.day) {
      return shortDate(a);
    }
    if (a.year == b.year && a.month == b.month) {
      return '${monthAbbr(a)} ${a.day} to ${b.day}';
    }
    return '${shortDate(a)} to ${shortDate(b)}';
  }

  Widget _cyclePill(CycleUsage? live, List<CycleUsage> past) {
    final c = context.zc;
    String range(int index) {
      final cy = index == 0 ? live! : past[index - 1];
      // The live pill shows what has actually been observed so far
      // ("Nov 1 to 3"), matching the picker and the hero — never the
      // full billing window, which lives on the chart axis instead.
      return _rangeLabel(cy.startedAt, cy.lastAt);
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
          color: c.surface.withAlpha(54),
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

  // ── Hero: the screenshot card ─────────────────────────────────────

  Widget _heroCard(CycleUsage? view, double? alertMb, DataPlanState? plan) {
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
                'modem: log in to start tracking.',
          ),
        ),
      );
    }
    final isLive = _selected == 0;
    final showAlert = isLive && alertMb != null && alertMb > 0;
    final frac = showAlert ? (view.usedMb / alertMb).clamp(0.0, 1.0) : null;
    final ringColor = frac != null && frac >= 0.9 ? c.danger : c.accentText;
    final range = _rangeLabel(view.startedAt, view.lastAt);

    // One muted caption: freshness for the live cycle, day count for
    // archives, the end-of-month projection once two days are in, and
    // the month's estimated cost whenever a plan prices it.
    final monthSpend = plan?.priceNaira != null && plan!.quotaMb > 0
        ? view.usedMb / plan.quotaMb * plan.priceNaira!
        : null;
    final caption = StringBuffer();
    if (isLive) {
      final ago = ZteClient.timeAgo(view.lastAt);
      caption.write(ago == 'just now' ? 'Just now' : 'sampled $ago');
    } else {
      caption.write(
        'ended ${shortDate(view.lastAt)} · '
        '${view.daysObserved} day${view.daysObserved == 1 ? '' : 's'} '
        'with data',
      );
    }
    if (isLive && view.hasTrend) {
      caption.write(
        ' · on pace for ${ZteClient.formatDataVolume(view.projectedMb())}',
      );
    }
    if (monthSpend != null) {
      caption.write(
        ' · ≈${formatNaira(monthSpend)}${isLive ? ' this cycle' : ''}',
      );
    }

    final maxSide = view.rxMb > view.txMb ? view.rxMb : view.txMb;
    final showSplit = view.rxMb > 0 || view.txMb > 0;

    return GlassCard(
      highlighted: widget.connected && isLive,
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              c.accent.withAlpha(isLive ? 34 : 16),
              c.accent.withAlpha(0),
            ],
          ),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isLive ? 'THIS CYCLE' : 'ARCHIVED',
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                Text(
                  range,
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
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
                                fontSize: 46,
                                height: 1.0,
                                fontWeight: FontWeight.w800,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'used',
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        caption.toString(),
                        style: TextStyle(color: c.textMuted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (showAlert)
                  _MiniRing(
                    frac: frac!,
                    color: ringColor,
                    track: c.textMuted.withAlpha(46),
                    capMb: alertMb,
                  )
                else if (isLive)
                  Tooltip(
                    message: 'Set alert line',
                    child: GestureDetector(
                      onTap: _editAlert,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c.accent.withAlpha(20),
                          shape: BoxShape.circle,
                          border: Border.all(color: c.accent.withAlpha(64)),
                        ),
                        child: Icon(
                          Icons.notifications_active_outlined,
                          size: 17,
                          color: c.accentText,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (showSplit) ...[
              const SizedBox(height: 14),
              Divider(color: c.borderSubtle, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _splitMini(
                      Icons.south,
                      'Downloaded',
                      view.rxMb,
                      maxSide,
                      c.live,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _splitMini(
                      Icons.north,
                      'Uploaded',
                      view.txMb,
                      maxSide,
                      c.accent,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One down/up mini inside the hero: value, share-of-side bar, label.
  Widget _splitMini(
    IconData icon,
    String label,
    double mb,
    double maxSide,
    Color color,
  ) {
    final c = context.zc;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Text(
              ZteClient.formatDataVolume(mb),
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ShareBar(fraction: mb / maxSide, color: color),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(color: c.textMuted, fontSize: 10.5),
        ),
      ],
    );
  }

  // ── Cumulative area chart (One UI style) ──────────────────────────

  Widget _chartCard(CycleUsage? view) {
    final c = context.zc;
    if (view == null) return const SizedBox.shrink();
    final points = <(DateTime, double)>[];
    final days = view.daily.keys.toList()..sort();
    for (final k in days) {
      final d = DateTime.parse(k);
      if (points.isNotEmpty && d.isBefore(points.first.$1)) continue;
      points.add((d, view.daily[k] ?? 0));
    }
    if (points.isEmpty) return const SizedBox.shrink();
    final isLive = _selected == 0;
    // The x-domain is the billing window, not the sampled days, so the
    // curve sits proportionally in its month from day one, One UI
    // style. The live cycle also gets a dashed month-end projection.
    final domainStart = isLive ? monthStart(view.startedAt) : view.startedAt;
    final domainEnd = isLive ? monthEnd(view.startedAt) : view.lastAt;
    // A few evenly spaced ticks: more context than start/end alone,
    // still quiet at a glance.
    final span = domainEnd.difference(domainStart).inDays;
    final tickOffsets = <int>{
      0,
      (span / 3).round(),
      (2 * span / 3).round(),
      span < 1 ? 1 : span,
    }.toList()..sort();
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLive)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.auto_graph, size: 13, color: c.textMuted),
                  const SizedBox(width: 5),
                  Text(
                    'Forecast',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                  const Spacer(),
                  Text(
                    view.hasTrend
                        ? ZteClient.formatDataVolume(view.projectedMb())
                        : 'one more day',
                    style: TextStyle(
                      color: view.hasTrend ? c.accentText : c.textMuted,
                      fontSize: 11.5,
                      fontWeight: view.hasTrend
                          ? FontWeight.w700
                          : FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            width: double.infinity,
            height: 190,
            child: CustomPaint(
              painter: _CumulativePainter(
                points: points,
                domainStart: domainStart,
                domainEnd: domainEnd,
                projectedEndMb: isLive && view.hasTrend
                    ? view.projectedMb()
                    : null,
                line: c.accent,
                fillTop: c.accent.withAlpha(96),
                fillBottom: c.accent.withAlpha(10),
                grid: c.textMuted.withAlpha(68),
                label: c.textMuted,
                dotRing: c.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 34),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final t in tickOffsets)
                  Text(
                    shortDate(domainStart.add(Duration(days: t))),
                    style: TextStyle(color: c.textMuted, fontSize: 10.5),
                  ),
              ],
            ),
          ),
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
                    '${past.length} archived month${past.length == 1 ? '' : 's'}',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear archived months',
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
                  icon: Icon(
                    Icons.delete_outline,
                    size: 17,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// All-time entry: its own tappable row with a proper home above the
  /// archive, far from the delete button.
  Widget _allTimeEntry(UsageHistory usage, DataPlanState? plan) {
    final c = context.zc;
    final past = usage.past;
    final live = usage.current;
    final total =
        past.fold<double>(0, (a, cy) => a + cy.usedMb) + (live?.usedMb ?? 0);
    final cycles = past.length + (live != null ? 1 : 0);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: () => _openAllTime(usage, plan),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(22),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withAlpha(56)),
                ),
                child: Icon(
                  Icons.all_inclusive,
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
                      'All time',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$cycles cycle${cycles == 1 ? '' : 's'} on record',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ZteClient.formatDataVolume(total),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 15, color: c.textMuted),
            ],
          ),
        ),
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
                      ? 'No alert line yet'
                      : 'Alert at ${ZteClient.formatDataVolume(alertMb)}',
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
    );
  }

  // ── Data plan: bought vs used ────────────────────────────────────
  // The plan is entered once; everything here derives automatically:
  // consumption from the ledger (rollover-safe), burn from its daily
  // trend, days from the clock, and the carrier's own remaining from
  // the last balance snapshot.

  String _gbLabel(double gb) => DataPlanState.quotaLabel(gb * 1024);

  String _gbValue(double mb) => DataPlanState.quotaFieldValue(mb);

  Widget _planCard(
    DataPlanState? plan,
    UsageHistory usage,
    DataBalance? balance,
  ) {
    if (plan == null) return _planEmptyCard(usage);
    final c = context.zc;
    final now = DateTime.now();
    final live = usage.current;
    final ledger = plan.ledgerNow(live?.usedMb ?? plan.baselineMb, usage.past);
    final left = plan.remainingMb(ledger).clamp(0.0, double.infinity);
    final burn = (live != null && live.hasTrend) ? live.trendPerDayMb : 0.0;
    final v = plan.verdict(ledger, burn, now);
    final emptyDays = plan.daysUntilEmpty(ledger, burn);

    final Color vColor = switch (v) {
      PlanVerdict.onTrack => c.live,
      PlanVerdict.burningFast => c.accentText,
      PlanVerdict.exhausted => c.danger,
      PlanVerdict.expired => c.textMuted,
      PlanVerdict.warmingUp => c.textMuted,
    };
    final IconData vIcon = switch (v) {
      PlanVerdict.onTrack => Icons.check_circle_outline,
      PlanVerdict.burningFast => Icons.error_outline,
      PlanVerdict.exhausted => Icons.cloud_off_outlined,
      PlanVerdict.expired => Icons.event_busy_outlined,
      PlanVerdict.warmingUp => Icons.hourglass_empty_outlined,
    };
    final String vText = switch (v) {
      PlanVerdict.onTrack => 'On track',
      PlanVerdict.burningFast => () {
        final out = now.add(
          Duration(hours: ((emptyDays ?? 0) * 24).round()),
        );
        final early = plan.daysLeft(now) - (emptyDays ?? 0).ceil();
        return early <= 0
            ? 'Dry as validity ends'
            : 'Dry ${shortDate(out)} · $early day${early == 1 ? '' : 's'} early';
      }(),
      PlanVerdict.exhausted => 'Bundle exhausted',
      PlanVerdict.expired => left > 0
          ? 'Expired · ${ZteClient.formatDataVolume(left)} unused'
          : 'Expired',
      PlanVerdict.warmingUp => 'Reading your pace',
    };

    final daysLeft = plan.daysLeft(now);
    final Color chipColor = daysLeft < 0
        ? c.danger
        : daysLeft <= 3
            ? c.accentText
            : c.textMuted;

    if (_planCollapsed) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: InkWell(
          onTap: _togglePlanCollapsed,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.sim_card_outlined,
                  size: 14,
                  color: c.accentText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    plan.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  ZteClient.formatDataVolume(left),
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'left',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Show plan',
                  child: Icon(
                    Icons.expand_more,
                    size: 16,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'PLAN',
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: chipColor.withAlpha(28),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: chipColor.withAlpha(90)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule, size: 11, color: chipColor),
                    const SizedBox(width: 4),
                    Text(
                      daysLeft < 0
                          ? 'expired'
                          : daysLeft == 0
                              ? 'ends today'
                              : '$daysLeft day${daysLeft == 1 ? '' : 's'} left',
                      style: TextStyle(
                        color: chipColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _showPlanSheet(plan, usage),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: c.textMuted,
                  ),
                ),
              ),
              InkWell(
                onTap: _togglePlanCollapsed,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Tooltip(
                    message: 'Hide plan',
                    child: Icon(
                      Icons.expand_less,
                      size: 16,
                      color: c.textMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: plan.title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (plan.carrier.isNotEmpty || plan.planName.isNotEmpty)
                  TextSpan(
                    text:
                        '  ·  ${[
                      if (plan.carrier.isNotEmpty) plan.carrier,
                      if (plan.planName.isNotEmpty) plan.planName,
                    ].join(' · ')}',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      ZteClient.formatDataVolume(left),
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 34,
                        height: 1.0,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    'left',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (plan.priceNaira != null)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '≈${formatNaira(plan.priceNaira! * (1 - plan.fracUsed(ledger).clamp(0.0, 1.0)))}',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    Text(
                      'of ${formatNaira(plan.priceNaira!)}',
                      style: TextStyle(color: c.textMuted, fontSize: 10.5),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Carrier tick: where the carrier's own remaining puts
          // consumption on the same bar. Agreement is visible; drift
          // is visible.
          ShareBar(
            fraction: plan.fracUsed(ledger),
            color: vColor,
            height: 6,
            markerFraction: balance != null &&
                    balance.totalMb > 0 &&
                    plan.quotaMb > 0
                ? (plan.quotaMb - balance.totalMb) / plan.quotaMb
                : null,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(vIcon, size: 13, color: vColor),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  vText,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (balance != null && balance.totalMb > 0) ...[
                const SizedBox(width: 10),
                Text(
                  '${ZteClient.formatDataVolume(balance.totalMb)} · '
                  '${ZteClient.timeAgo(balance.fetchedAt)}',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// No plan yet: one quiet entry point. Everything after setup is
  /// automatic — the ledger, the clock and the carrier do the rest.
  Widget _planEmptyCard(UsageHistory usage) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: () => _showPlanSheet(null, usage),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.sim_card_outlined, size: 16, color: c.accentText),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Track a data plan',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'One setup, then it runs itself',
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(Icons.add, size: 15, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  /// Enter (or revise) the plan. Quota, validity and price are the only
  /// things the modem can never know, so they are the only things asked.
  Future<void> _showPlanSheet(DataPlanState? existing, UsageHistory usage) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final customCarrierCtrl = TextEditingController();
    var selectedCarrier = 'Airtel';
    final preset = DataPlanState.airtelPreset();
    if (existing != null) {
      if (carriers.contains(existing.carrier)) {
        selectedCarrier = existing.carrier;
      } else if (existing.carrier.isNotEmpty) {
        selectedCarrier = 'Other';
        customCarrierCtrl.text = existing.carrier;
      }
    }
    final quotaCtrl = TextEditingController(
      text: existing != null ? _gbValue(existing.quotaMb) : '6.5',
    );
    final daysCtrl = TextEditingController(
      text: '${existing?.validityDays ?? 13}',
    );
    final priceCtrl = TextEditingController(
      text: existing?.priceNaira?.toStringAsFixed(0) ?? '1000',
    );
    return showGlassModal<void>(
      context,
      icon: Icons.sim_card_outlined,
      title: existing == null ? 'Track a data plan' : 'Edit plan',
      subtitle: 'Only what the modem cannot know',
      body: StatefulBuilder(
        builder: (ctx, setModal) {
          void usePreset() => setModal(() {
                nameCtrl.text = preset.name;
                selectedCarrier = preset.carrier;
                quotaCtrl.text = _gbValue(preset.quotaMb);
                daysCtrl.text = '${preset.validityDays}';
                priceCtrl.text =
                    preset.priceNaira?.toStringAsFixed(0) ?? '';
              });
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (existing == null)
                GestureDetector(
                  onTap: usePreset,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: context.zc.chip,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.zc.chipBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.bolt,
                          size: 15,
                          color: context.zc.accentText,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${preset.name} · ${_gbLabel(preset.quotaMb / 1024)} · '
                            '${preset.validityDays} days',
                            style: TextStyle(
                              color: context.zc.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          'Use',
                          style: TextStyle(
                            color: context.zc.accentText,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (existing == null) const SizedBox(height: 12),
              _planField('Plan name', nameCtrl,
                  hint: 'e.g. SmartCash, optional',
                  onChanged: (_) => setModal(() {})),
              const SizedBox(height: 10),
              Text('Network',
                  style: TextStyle(
                      color: context.zc.textSecondary, fontSize: 12.5)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in [...carriers, 'Other'])
                    GestureDetector(
                      onTap: () => setModal(() => selectedCarrier = option),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selectedCarrier == option
                              ? context.zc.accent.withAlpha(36)
                              : context.zc.chip,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: selectedCarrier == option
                                ? context.zc.accent.withAlpha(110)
                                : context.zc.chipBorder,
                          ),
                        ),
                        child: Text(
                          option,
                          style: TextStyle(
                            color: selectedCarrier == option
                                ? context.zc.accentText
                                : context.zc.textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (selectedCarrier == 'Other') ...[
                const SizedBox(height: 8),
                _planField('Carrier name', customCarrierCtrl,
                    hint: 'e.g. Starlink',
                    onChanged: (_) => setModal(() {})),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _planField('Bundle size', quotaCtrl,
                        suffix: 'GB',
                        number: true,
                        onChanged: (_) => setModal(() {})),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _planField('Lasts', daysCtrl,
                        suffix: 'days',
                        number: true,
                        onChanged: (_) => setModal(() {})),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _planField('Price', priceCtrl,
                  prefix: '₦',
                  number: true,
                  hint: 'optional',
                  onChanged: (_) => setModal(() {})),
              const SizedBox(height: 10),
              Text(
                'The counter is read automatically from here. Buy data, '
                'then log one top-up.',
                style:
                    TextStyle(color: context.zc.textMuted, fontSize: 11),
              ),
            ],
          );
        },
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onPlanChanged(null);
            },
            child: Text(
              'Stop',
              style: TextStyle(color: context.zc.danger),
            ),
          ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final gb = double.tryParse(quotaCtrl.text.trim());
            final days = int.tryParse(daysCtrl.text.trim());
            if (gb == null || gb <= 0 || days == null || days <= 0) return;
            final price = double.tryParse(priceCtrl.text.trim());
            final carrier = selectedCarrier == 'Other'
                ? customCarrierCtrl.text.trim()
                : selectedCarrier;
            final now = DateTime.now();
            Navigator.of(context).pop();
            widget.onPlanChanged(
              DataPlanState(
                carrier: carrier.isEmpty ? 'Airtel' : carrier,
                name: nameCtrl.text.trim(),
                planName: _gbLabel(gb),
                quotaMb: gb * 1024,
                validityDays: days,
                priceNaira: price,
                startedAt: existing?.startedAt ?? now,
                baselineMb:
                    existing?.baselineMb ?? usage.current?.usedMb ?? 0,
              ),
            );
          },
          child: Text(existing == null ? 'Start tracking' : 'Save'),
        ),
      ],
    );
    // NOTE: controllers intentionally not disposed — same pop-transition
    // hazard as the alert editor above. Dialog-locals are GC'd.
  }

  Widget _planField(
    String label,
    TextEditingController ctrl, {
    String? suffix,
    String? prefix,
    String? hint,
    bool number = false,
    required void Function(String) onChanged,
  }) {
    final c = context.zc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(color: c.textSecondary, fontSize: 12.5)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          onChanged: onChanged,
          keyboardType: number
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          decoration: InputDecoration(
            suffixText: suffix,
            prefixText: prefix,
            hintText: hint,
          ),
        ),
      ],
    );
  }

  /// One tap, prefilled with the current plan's figures: the new bundle
  /// starts from today's counter, the old one archives with what it used.
  // ── All time: the full breakdown ───────────────────────────────

  Future<void> _openAllTime(UsageHistory usage, DataPlanState? plan) {
    final c = context.zc;
    final past = usage.past;
    final live = usage.current;
    final archived = past.fold<double>(0, (a, cy) => a + cy.usedMb);
    final allTime = archived + (live?.usedMb ?? 0);
    final rows = <({String label, String sub, double mb})>[
      if (live != null)
        (label: live.label, sub: 'this cycle · to date', mb: live.usedMb),
      for (final cy in past)
        (label: cy.label, sub: 'archived', mb: cy.usedMb),
    ];
    final maxMb = rows.fold<double>(1.0, (m, r) => r.mb > m ? r.mb : m);
    ({String label, double mb})? biggest;
    if (past.isNotEmpty) {
      final b = past.reduce((a, b) => a.usedMb >= b.usedMb ? a : b);
      biggest = (label: b.label, mb: b.usedMb);
    } else if (live != null) {
      biggest = (label: live.label, mb: live.usedMb);
    }
    final spent = plan?.totalSpent ?? 0;
    // Month spend at the current plan's per-GB rate: an estimate, since
    // the plan hasn't covered the whole history.
    final double? unitRate = plan != null &&
            plan.priceNaira != null &&
            plan.quotaMb > 0
        ? plan.priceNaira! / plan.quotaMb
        : null;

    Widget statRow(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Icon(icon, size: 15, color: c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );

    final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              ZteClient.formatDataVolume(allTime),
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 40,
                height: 1.0,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${past.length + (live != null ? 1 : 0)} cycle${past.length + (live != null ? 1 : 0) == 1 ? '' : 's'} on record',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 7,
              child: Row(
                children: [
                  if (archived > 0)
                    Flexible(
                      flex: (archived * 1000).round().clamp(1, 1000000),
                      child: Container(color: c.accent.withAlpha(170)),
                    ),
                  if (live != null && live.usedMb > 0)
                    Flexible(
                      flex: (live.usedMb * 1000).round().clamp(1, 1000000),
                      child: Container(color: c.live),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (live != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'THIS CYCLE',
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                    Text(
                      ZteClient.formatDataVolume(live.usedMb),
                      style: TextStyle(
                        color: c.live,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              if (archived > 0)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ARCHIVED',
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                    Text(
                      ZteClient.formatDataVolume(archived),
                      style: TextStyle(
                        color: c.accentText,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          Divider(color: c.borderSubtle, height: 22),
          statRow(
            Icons.calendar_month,
            'Months tracked',
            '${past.length + (live != null ? 1 : 0)}',
          ),
          if (past.isNotEmpty)
            statRow(
              Icons.analytics_outlined,
              'Monthly average',
              ZteClient.formatDataVolume(archived / past.length),
            ),
          if (biggest != null)
            statRow(
              Icons.emoji_events_outlined,
              'Biggest · ${biggest.label}',
              ZteClient.formatDataVolume(biggest.mb),
            ),
          if (spent > 0)
            statRow(
              Icons.payments_outlined,
              'Spent on bundles',
              formatNaira(spent),
            ),
          if (unitRate != null && allTime > 0)
            statRow(
              Icons.savings_outlined,
              'Est. lifetime cost',
              '≈${formatNaira(allTime * unitRate)}',
            ),
          if (rows.length > 1) ...[
            Divider(color: c.borderSubtle, height: 22),
            Text(
              'BY MONTH',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${r.label} · ${r.sub}',
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              ZteClient.formatDataVolume(r.mb),
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            if (unitRate != null)
                              Text(
                                '≈${formatNaira(r.mb * unitRate)}',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 10.5,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ShareBar(
                      fraction: r.mb / maxMb,
                      color: c.accent.withAlpha(150),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: c.surfaceLifted,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: c.borderSubtle),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textMuted.withAlpha(70),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: c.accent.withAlpha(26),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: c.accent.withAlpha(80)),
                      ),
                      child: Icon(
                        Icons.all_inclusive,
                        size: 17,
                        color: c.accentText,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'All time',
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Every megabyte this app has seen',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  child: content,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
                          ? c.accent.withAlpha(110)
                          : c.accent.withAlpha(56),
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
                        'ended ${shortDate(cycle.lastAt)}',
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
            ShareBar(
              fraction: cycle.usedMb / maxMb,
              color: c.accent.withAlpha(150),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cumulative area chart: usage climbs across the billing window
/// (not the sampled days, so the curve sits proportionally in its
/// month from day one). Gridlines at 0/50/100% of the cycle peak with
/// % labels on the right edge; the newest real sample gets a dot; the
/// live cycle extends a dashed projection with a hollow forecast ring,
/// named in the card header.
class _CumulativePainter extends CustomPainter {
  final List<(DateTime, double)> points;
  final DateTime domainStart;
  final DateTime domainEnd;
  final double? projectedEndMb;
  final Color line;
  final Color fillTop;
  final Color fillBottom;
  final Color grid;
  final Color label;
  final Color dotRing;

  _CumulativePainter({
    required this.points,
    required this.domainStart,
    required this.domainEnd,
    required this.projectedEndMb,
    required this.line,
    required this.fillTop,
    required this.fillBottom,
    required this.grid,
    required this.label,
    required this.dotRing,
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
    var spanDays = domainEnd.difference(domainStart).inDays;
    if (spanDays < 1) spanDays = 1;
    var maxMb = points.fold<double>(0.001, (m, p) => p.$2 > m ? p.$2 : m);
    final projected = projectedEndMb;
    if (projected != null && projected > maxMb) maxMb = projected;

    Offset xy(DateTime d, double mb) {
      var off = d.difference(domainStart).inDays;
      if (off < 0) off = 0;
      if (off > spanDays) off = spanDays;
      final x = _left + (off / spanDays) * chartW;
      final y = _top + (1 - mb / maxMb) * chartH;
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

    final first = xy(points[0].$1, points[0].$2);
    final path = Path()..moveTo(first.dx, first.dy);
    for (var i = 1; i < points.length; i++) {
      final p = xy(points[i].$1, points[i].$2);
      path.lineTo(p.dx, p.dy);
    }
    final last = xy(points.last.$1, points.last.$2);
    final area = Path.from(path)
      ..lineTo(last.dx, _top + chartH)
      ..lineTo(first.dx, _top + chartH)
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

    // Marker on the newest real sample.
    canvas.drawCircle(last, 4.0, Paint()..color = dotRing);
    canvas.drawCircle(last, 2.6, Paint()..color = line);

    // Dashed projection to the end of the billing window, with a
    // hollow ring marking the forecast endpoint.
    if (projected != null) {
      final end = xy(domainEnd, projected);
      final dashPath = Path()
        ..moveTo(last.dx, last.dy)
        ..lineTo(end.dx, end.dy);
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = line.withAlpha(150);
      for (final m in dashPath.computeMetrics()) {
        var dist = 0.0;
        while (dist < m.length) {
          final next = dist + 5 > m.length ? m.length : dist + 5;
          canvas.drawPath(m.extractPath(dist, next), dash);
          dist += 9; // 5 on, 4 off
        }
      }
      canvas.drawCircle(
        end,
        3.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = line.withAlpha(180),
      );
    }
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
      old.projectedEndMb != projectedEndMb ||
      old.domainEnd != domainEnd ||
      old.line != line ||
      old.grid != grid;
}

/// Small alert-line ring in the hero: % of the line inside, amber (or
/// red near the line) sweep around.
class _MiniRing extends StatelessWidget {
  final double frac;
  final Color color;
  final Color track;
  final double capMb;

  const _MiniRing({
    required this.frac,
    required this.color,
    required this.track,
    required this.capMb,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (frac * 100).clamp(0, 999).toStringAsFixed(0);
    return Tooltip(
      message: '$pct% of ${ZteClient.formatDataVolume(capMb)} alert line',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: frac.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (ctx, sweep, _) => SizedBox(
          width: 68,
          height: 68,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(64, 64),
                painter: _MiniRingPainter(
                  sweep: sweep,
                  color: color,
                  track: track,
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniRingPainter extends CustomPainter {
  final double sweep;
  final Color color;
  final Color track;

  _MiniRingPainter({
    required this.sweep,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final rect = Rect.fromLTWH(
      stroke / 2 + 1,
      stroke / 2 + 1,
      size.width - stroke - 2,
      size.height - stroke - 2,
    );
    canvas.drawArc(
      rect,
      0,
      2 * 3.141592653589793,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (sweep <= 0) return;
    canvas.drawArc(
      rect,
      -3.141592653589793 / 2,
      2 * 3.141592653589793 * sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_MiniRingPainter old) =>
      old.sweep != sweep || old.color != color || old.track != track;
}
