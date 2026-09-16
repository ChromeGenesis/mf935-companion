library;

/// Speed-test card (SSOT): runs the [SpeedTestRunner] phases with a
/// linear progress track, then shows latency / down / up results.
/// First run per install asks for consent (the test consumes real
/// data); results are logged to the diagnostics feed.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dialogs.dart';
import '../core/speed_test.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_utils.dart';

class SpeedTestCard extends StatefulWidget {
  final bool connected;
  final void Function(String line) log;

  const SpeedTestCard({
    super.key,
    required this.connected,
    required this.log,
  });

  @override
  State<SpeedTestCard> createState() => _SpeedTestCardState();
}

class _SpeedTestCardState extends State<SpeedTestCard> {
  static const _consentKey = 'speed_test_consent';

  final _runner = SpeedTestRunner();
  SpeedPhase _phase = SpeedPhase.idle;
  double _progress = 0;
  double? _liveBps;
  SpeedTestResult? _last;

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // First-use data-use warning (Phase 4 guardrail): one consent, then
    // never asked again.
    final prefs = await SharedPreferences.getInstance();
    final consented = prefs.getBool(_consentKey) ?? false;
    if (!consented && mounted) {
      final ok = await confirmAction(
        context,
        icon: Icons.speed,
        title: 'Run a speed test?',
        danger: false,
        message:
            'The test uses about 10 MB of carrier data (downloads ~9 MB, '
            'uploads ~1 MB). It runs parallel streams like fast.com and '
            'reports the peak sustained rate — never automatically in '
            'the background.',
        confirmLabel: 'Run test',
      );
      if (!ok) return;
      await prefs.setBool(_consentKey, true);
    }

    widget.log('speed test: starting…');
    final r = await _runner.run((phase, progress, liveBps) {
      if (!mounted) return;
      setState(() {
        _phase = phase;
        _progress = progress;
        _liveBps = liveBps;
      });
    });
    if (!mounted) return;
    setState(() {
      _last = r;
      _progress = 0;
      _liveBps = null;
    });
    if (r.error != null && r.error != 'cancelled') {
      widget.log('speed test failed: ${r.error}');
    } else if (r.error == 'cancelled') {
      widget.log('speed test cancelled');
    } else {
      widget.log(
        'speed test: ${r.latencyMs?.toStringAsFixed(0)} ms · '
        '${formatRate(r.downloadBps ?? 0)} down · '
        '${formatRate(r.uploadBps ?? 0)} up',
      );
    }
  }

  void _cancel() {
    _runner.cancel();
  }

  /// Cautious diagnosis (Phase 4): signal problem vs carrier congestion
  /// is only ever a hint, never a verdict.
  String? _hint() {
    final r = _last;
    if (r == null || r.downloadBps == null) return null;
    if (r.downloadBps! < 1 * 1024 * 1024) {
      return 'Under 1 Mbps down — retest after checking signal bars; '
          'a strong signal with slow throughput usually means carrier '
          'congestion rather than placement.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final running = _phase == SpeedPhase.latency ||
        _phase == SpeedPhase.download ||
        _phase == SpeedPhase.upload;
    final r = _last;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.speed, size: 16, color: c.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SPEED TEST',
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
              if (!running)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                  onPressed: !widget.connected ? null : _start,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Test'),
                )
              else
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _cancel,
                  icon: Icon(Icons.close, size: 16, color: c.danger),
                  label: Text('Cancel', style: TextStyle(color: c.danger)),
                ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 10),
            Center(
              child: _SpeedMeter(
                phase: _phase,
                progress: _progress,
                liveBps: _liveBps,
              ),
            ),
          ],
          if (!running && r != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _speedStat(
                    c,
                    r.latencyMs == null
                        ? '—'
                        : '${r.latencyMs!.toStringAsFixed(0)} ms',
                    'latency',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _speedStat(
                    c,
                    r.downloadBps == null
                        ? '—'
                        : formatRate(r.downloadBps!),
                    'download',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _speedStat(
                    c,
                    r.uploadBps == null ? '—' : formatRate(r.uploadBps!),
                    'upload',
                  ),
                ),
              ],
            ),
            if (r.error != null) ...[
              const SizedBox(height: 8),
              Text(
                r.error == 'cancelled'
                    ? 'Cancelled — no result recorded.'
                    : 'Failed: ${r.error}',
                style: TextStyle(
                  color: r.error == 'cancelled' ? c.textMuted : c.danger,
                  fontSize: 11.5,
                ),
              ),
            ],
            if (_hint() != null) ...[
              const SizedBox(height: 8),
              Text(
                _hint()!,
                style: TextStyle(color: c.textSecondary, fontSize: 11.5),
              ),
            ],
          ],
          if (!running && r == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Parallel streams through the carrier, peak sustained '
                'rate like fast.com. Uses real data — run sparingly.',
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _speedStat(ZteColors c, String value, String caption) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.chip,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(
            caption,
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Animated run meter: a sweeping progress ring with the phase icon
/// in the middle and the live transfer rate sweeping underneath it
/// during download/upload (percent during latency). Replaces the
/// plain progress bar — the test reads alive while streams run.
class _SpeedMeter extends StatelessWidget {
  final SpeedPhase phase;
  final double progress;
  final double? liveBps;

  const _SpeedMeter({
    required this.phase,
    required this.progress,
    required this.liveBps,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final target = progress.clamp(0.0, 1.0);
    final icon = switch (phase) {
      SpeedPhase.latency => Icons.timelapse_outlined,
      SpeedPhase.download => Icons.download_outlined,
      SpeedPhase.upload => Icons.upload_outlined,
      _ => Icons.speed_outlined,
    };
    final showRate =
        (phase == SpeedPhase.download || phase == SpeedPhase.upload) &&
        liveBps != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 148,
          height: 148,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: target),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            builder: (ctx, v, _) => Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: c.accent.withAlpha(45),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 148,
                    height: 148,
                    child: CircularProgressIndicator(
                      value: 1,
                      strokeWidth: 11,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(
                        c.textMuted.withAlpha(45),
                      ),
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  SizedBox(
                    width: 148,
                    height: 148,
                    child: CircularProgressIndicator(
                      value: v,
                      strokeWidth: 11,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(c.accent),
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 26, color: c.accentText),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 108,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            showRate
                                ? formatRate(liveBps!)
                                : '${(v * 100).round()}%',
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
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          SpeedTestRunner.phaseLabel(phase),
          style: TextStyle(color: c.textSecondary, fontSize: 12.5),
        ),
      ],
    );
  }
}
