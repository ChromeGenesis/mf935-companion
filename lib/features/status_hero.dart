library;

/// Status-tab hero card (SSOT): battery + carrier + signal on the left,
/// data balance on the right (side-by-side when wide, stacked when narrow).
/// Stateless — [StatusTab] owns the data; this module only renders.
import 'package:flutter/material.dart';

import 'status_balance.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

/// Unread-SMS chip on the hero card: icon + honest counter. Glows
/// amber when there are unread; taps to the inbox when the shell
/// provides tab jumps.
class UnreadBadge extends StatelessWidget {
  final String text;
  final bool alive;
  final VoidCallback? onTap;

  const UnreadBadge({
    super.key,
    required this.text,
    required this.alive,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Tooltip(
      message: 'Unread SMS — open inbox',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: alive ? c.accent.withAlpha(26) : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: alive ? c.accent.withAlpha(130) : c.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.markunread_mailbox_outlined,
                size: 15,
                color: alive ? c.accentText : c.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  color: alive ? c.accentText : c.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
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

/// Glowy hero card: battery + carrier + signal on the left, data balance
/// on the right (side-by-side when wide, stacked when narrow).
class StatusHero extends StatelessWidget {
  final bool highlighted;
  final int? battery;
  final bool charging;
  final String provider;
  final String netLine;
  final int? signal;
  final String unreadText;
  final bool unreadAlive;
  final VoidCallback? onUnreadTap;
  final VoidCallback? onRefreshNow;
  final BalanceSection balance;

  const StatusHero({
    super.key,
    required this.highlighted,
    required this.battery,
    required this.charging,
    required this.provider,
    required this.netLine,
    required this.signal,
    required this.unreadText,
    required this.unreadAlive,
    this.onUnreadTap,
    this.onRefreshNow,
    required this.balance,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      highlighted: highlighted,
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (ctx, cons) {
          // Wide hero: status and balance share the card horizontally
          // instead of stacking top-down. Narrow: stacked as before.
          // (Left pane is ~510px at the 980px minimum window.)
          final wide = cons.maxWidth > 480;
          // Carrier one-liner: providerRaw duplicates carrierName
          // ("Airtel NG" + "62120..."), so only net type + gateway.
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
                  ],
                ),
              ),
            ],
          );
          // Bottom strip shares one baseline: signal left, inbox +
          // resync right.
          final statusBottom = Row(
            children: [
              SignalBars(level: signal ?? -1, height: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  signal == null ? 'signal n/a' : 'signal $signal/5',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              UnreadBadge(
                text: unreadText,
                alive: unreadAlive,
                onTap: onUnreadTap,
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  tooltip: 'Refresh now',
                  padding: EdgeInsets.zero,
                  onPressed: onRefreshNow,
                  icon: Icon(Icons.refresh, color: c.accentText, size: 18),
                ),
              ),
            ],
          );
          final statusHead = Row(
            children: [
              BatteryRing(percent: battery, charging: charging, size: 92),
              const SizedBox(width: 16),
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
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      netLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SignalBars(level: signal ?? -1, height: 22),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            signal == null ? 'signal n/a' : 'signal $signal/5',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              UnreadBadge(
                text: unreadText,
                alive: unreadAlive,
                onTap: onUnreadTap,
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: 'Refresh now',
                onPressed: onRefreshNow,
                icon: Icon(Icons.refresh, color: c.accentText, size: 20),
              ),
            ],
          );
          if (wide) {
            // Side-by-side: left column stretches to the balance
            // height (no dead amber space below the carrier), split
            // into top info + bottom signal/actions with a spacer.
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        statusTop,
                        const Spacer(),
                        const SizedBox(height: 10),
                        Divider(color: c.borderSubtle, height: 1),
                        const SizedBox(height: 10),
                        statusBottom,
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 14),
                    color: c.borderSubtle,
                  ),
                  Expanded(flex: 10, child: balance),
                ],
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              statusHead,
              const SizedBox(height: 10),
              Divider(color: c.borderSubtle, height: 1),
              const SizedBox(height: 10),
              balance,
            ],
          );
        },
      ),
    );
  }
}
