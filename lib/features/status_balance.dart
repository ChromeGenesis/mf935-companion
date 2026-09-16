library;

/// Status-tab data-balance presentation (SSOT): snapshot section with
/// bundle rows, quota bars, expiry chips and the relocated countdown
/// pill. Stateless — [StatusTab] owns the snapshot lifecycle. Parsed
/// results only — the raw modem reply lives exclusively in Settings.
import 'package:flutter/material.dart';

import '../core/expiry_widgets.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/zte_utils.dart';

/// Balance section: total, bundles, raw. The side-by-side hero supplies
/// its own separator, so no divider lives here.
class BalanceSection extends StatelessWidget {
  final DataBalance? balance;
  final bool busy;
  final bool connected;
  final VoidCallback? onRefresh;

  /// Carrier-specific query code shown in hints (MTN *323*4#,
  /// Airtel *323*1#). Purely informational — the dial itself lives in
  /// [ZteClient.fetchDataBalance].
  final String balanceCode;

  const BalanceSection({
    super.key,
    required this.balance,
    required this.busy,
    required this.connected,
    this.onRefresh,
    this.balanceCode = '*323*1#',
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final b = balance;
    // Biggest bundle: quota bars are relative shares of this. The modem
    // never reports plan totals, so absolute % would be a guess.
    final maxMb = (b?.bundles ?? const <DataBundle>[]).fold<double>(
      0,
      (m, x) => x.mb > m ? x.mb : m,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              'DATA BALANCE',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const Spacer(),
            if (b != null)
              Text(
                timeAgo(b.fetchedAt),
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            const SizedBox(width: 6),
            SizedBox(
              width: 30,
              height: 30,
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(7),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Re-check ($balanceCode)',
                      padding: EdgeInsets.zero,
                      onPressed: (!connected || busy) ? null : onRefresh,
                      icon: Icon(Icons.refresh, color: c.accentText, size: 18),
                    ),
            ),
          ],
        ),
        if (b == null && !busy)
          Row(
            children: [
              Expanded(
                child: Text(
                  connected
                      ? 'Dial $balanceCode for the real balance.'
                      : 'Log in, then check the real balance.',
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              ElevatedButton(
                onPressed: (!connected || busy) ? null : onRefresh,
                child: const Text('Check'),
              ),
            ],
          )
        else if (b != null) ...[
          // Active total + remaining-time pill side by side: the
          // countdown relocated here from the top header lives
          // alongside the balance it describes.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatDataVolume(b.totalMb),
                        maxLines: 1,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      b.bundles.isEmpty
                          ? 'could not parse — see Settings raw log'
                          : 'left across ${b.bundles.length} bundle${b.bundles.length == 1 ? '' : 's'}',
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (b.nextExpiry != null) ...[
                const SizedBox(width: 8),
                ExpiryDial(bundle: b.nextExpiry!, compact: true),
              ],
            ],
          ),
          for (final bundle in b.bundles)
            Opacity(
              // Exhausted bundles take less precedence: dimmed, last.
              opacity: bundle.exhausted ? 0.45 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            bundle.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12.5,
                              decoration: bundle.exhausted
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        Text(
                          formatDataVolume(bundle.mb),
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ExpiryChip(bundle: bundle),
                      ],
                    ),
                    if (!bundle.exhausted && maxMb > 0) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: Container(
                          height: 3,
                          color: c.textMuted.withAlpha(45),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (bundle.mb / maxMb).clamp(0.02, 1.0),
                            child: Container(color: c.accentText),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          // Raw modem text lives exclusively in Settings (raw data log).
          // Status stays parsed-only + glanceable.
        ],
      ],
    );
  }
}

/// Expiry chip: "exhausted" (grey, precedence over everything) for
/// empty bundles, red when expired, amber under 3 days, muted
/// otherwise, "expiry?" when unknown instead of guessing.
class ExpiryChip extends StatelessWidget {
  final DataBundle bundle;

  const ExpiryChip({super.key, required this.bundle});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    if (bundle.exhausted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.textMuted.withAlpha(20),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.textMuted.withAlpha(50)),
        ),
        child: Text(
          'exhausted',
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final exp = bundle.expiry;
    if (exp == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.textMuted.withAlpha(24),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.textMuted.withAlpha(60)),
        ),
        child: Text(
          'expiry?',
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final days = exp.difference(DateTime.now()).inDays;
    final Color color;
    final String label;
    if (days < 0) {
      color = c.danger;
      label = 'expired';
    } else if (days < 3) {
      color = c.accentText;
      label = days == 0 ? 'today' : '${days}d left';
    } else {
      color = c.textMuted;
      label = '${days}d left';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
