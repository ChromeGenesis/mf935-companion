library;

/// Status-tab hero card (SSOT): battery + carrier + signal on top, data
/// balance beneath, and a compact live-metrics strip (month usage, live
/// down, live up) at the bottom — icons + values only, no separate
/// StatTile row anymore. Stateless — [StatusTab] owns the data.
import 'package:flutter/material.dart';

import 'status_balance.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

/// Glowy hero card: battery + carrier + signal, data balance, and the
/// live-metrics strip (side-by-side when wide, stacked when narrow).
class StatusHero extends StatelessWidget {
  final bool highlighted;
  final int? battery;
  final bool charging;
  final String provider;
  final String netLine;
  final int? signal;

  /// Live metrics strip: month usage / live down / live up, icon +
  /// value only (caption lives in the tooltip).
  final List<(IconData, String, String)> metrics;
  final BalanceSection balance;

  /// Launch the router signal-locator tool (null = disabled, e.g.
  /// when logged out).
  final VoidCallback? onOpenSignalLocator;

  const StatusHero({
    super.key,
    required this.highlighted,
    required this.battery,
    required this.charging,
    required this.provider,
    required this.netLine,
    required this.signal,
    required this.metrics,
    required this.balance,
    this.onOpenSignalLocator,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      highlighted: highlighted,
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (ctx, cons) {
          // Wide hero: status and balance share the card horizontally.
          // Narrow: stacked. (Left pane is ~510px at the 980px minimum.)
          final wide = cons.maxWidth > 480;

          // Live-metrics strip: three equal chips, icon + value only.
          // Tooltip carries the caption; nothing can truncate.
          final metricStrip = Row(
            children: [
              for (var i = 0; i < metrics.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _MetricChip(m: metrics[i])),
              ],
            ],
          );

          // Carrier one-liner: net type + gateway only.
          final statusTop = Row(
            children: [
              BatteryRing(percent: battery, charging: charging, size: 78),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      provider,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      netLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SignalBars(level: signal ?? -1, height: 18),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            signal == null ? 'signal n/a' : 'signal $signal/5',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (onOpenSignalLocator != null) ...[
                          // Push the locator trigger to the row's right
                          // edge — it reads as an action, not a label.
                          const Spacer(),
                          Tooltip(
                            message: 'Signal locator — find the best spot '
                                'for the router (RSRP · RSRQ · SINR)',
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                onTap: onOpenSignalLocator,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: c.accent.withAlpha(32),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: c.accent.withAlpha(110),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.explore,
                                        size: 17,
                                        color: c.accentText,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        'Locate',
                                        style: TextStyle(
                                          color: c.accentText,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );

          if (wide) {
            // Side-by-side: status + metrics left, balance right.
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 11, child: statusTop),
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 14),
                        color: c.borderSubtle,
                      ),
                      Expanded(flex: 10, child: balance),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Divider(color: c.borderSubtle, height: 1),
                const SizedBox(height: 10),
                metricStrip,
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              statusTop,
              const SizedBox(height: 10),
              Divider(color: c.borderSubtle, height: 1),
              const SizedBox(height: 10),
              balance,
              const SizedBox(height: 10),
              metricStrip,
            ],
          );
        },
      ),
    );
  }
}

/// One live metric: icon left, value right. Full-width text so long
/// values ("107.9 GB") never truncate; caption rides in the tooltip.
class _MetricChip extends StatelessWidget {
  final (IconData, String, String) m;

  const _MetricChip({required this.m});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Tooltip(
      message: m.$3,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(m.$1, size: 14, color: c.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  m.$2,
                  maxLines: 1,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
