library;

/// Countdown + fuse-ring widgets for bundle expiry (SSOT).
///
/// Extracted from the former `widgets.dart` god file: the pure
/// [formatCountdown] formatter, the self-ticking [CountdownText], and the
/// header [ExpiryDial] that counts down to the next-expiring bundle.
/// `widgets.dart` re-exports this file so existing imports keep working.
import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';
import 'zte_utils.dart' as zu;

/// "13d 04:12:33", "04:12:33" under a day, "expired" past zero.
/// Pure + tested; [CountdownText] ticks it live.
String formatCountdown(Duration left) {
  if (left.inSeconds <= 0) return 'expired';
  final d = left.inDays;
  final h = left.inHours % 24;
  final m = left.inMinutes % 60;
  final s = left.inSeconds % 60;
  final clock =
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return d > 0 ? '${d}d $clock' : clock;
}

/// Self-ticking countdown to [target]. Owns its 1s timer and only ever
/// rebuilds itself — cheap enough to leave on the dashboard permanently.
class CountdownText extends StatefulWidget {
  final DateTime target;
  final TextStyle? style;

  const CountdownText({super.key, required this.target, this.style});

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? _timer;
  late Duration _left;

  @override
  void initState() {
    super.initState();
    _left = widget.target.difference(DateTime.now());
    if (_left.inSeconds > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  @override
  void didUpdateWidget(CountdownText old) {
    super.didUpdateWidget(old);
    if (old.target != widget.target) {
      _timer?.cancel();
      _left = widget.target.difference(DateTime.now());
      if (_left.inSeconds > 0 && mounted) {
        _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      }
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _left = widget.target.difference(DateTime.now()));
    if (_left.inSeconds <= 0) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Text(
      formatCountdown(_left),
      style:
          (widget.style ??
                  TextStyle(
                    color: c.accentText,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ))
              .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}

/// Fuse ring: radial countdown for the next-expiring bundle, living in
/// the app header at title level. The ring burns down over the plan
/// window inferred from the bundle name (daily/weekly/monthly); the
/// exact numbers ride in the text + tooltip. Tap jumps to Status.
/// Self-ticking — rebuilds only itself, once a second.
class ExpiryDial extends StatefulWidget {
  final DataBundle bundle;
  final bool compact; // narrow screens: ring + time, no name
  final VoidCallback? onTap;

  const ExpiryDial({
    super.key,
    required this.bundle,
    this.compact = false,
    this.onTap,
  });

  @override
  State<ExpiryDial> createState() => _ExpiryDialState();
}

class _ExpiryDialState extends State<ExpiryDial> {
  Timer? _timer;
  late Duration _left;

  Duration _remaining() {
    final exp = widget.bundle.expiry;
    if (exp == null) return Duration.zero;
    return exp.difference(DateTime.now());
  }

  @override
  void initState() {
    super.initState();
    _left = _remaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = _remaining());
    });
  }

  @override
  void didUpdateWidget(ExpiryDial old) {
    super.didUpdateWidget(old);
    if (old.bundle.expiry != widget.bundle.expiry) {
      _left = _remaining();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final b = widget.bundle;
    final windowSecs = zu.expiryWindowDays(b.name) * 86400;
    final frac = windowSecs <= 0
        ? 0.0
        : (_left.inSeconds / windowSecs).clamp(0.0, 1.0);
    final urgent = _left.inHours <= 48;
    final ring = urgent ? c.danger : c.accentText;
    return Tooltip(
      message:
          '${b.name} · ${zu.formatDataVolume(b.mb)} left · ends ${formatCountdown(_left)}',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.surface.withAlpha(170),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: ring.withAlpha(70)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        value: frac,
                        strokeWidth: 3,
                        backgroundColor: c.textMuted.withAlpha(50),
                        valueColor: AlwaysStoppedAnimation(ring),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Icon(Icons.hourglass_bottom, size: 11, color: ring),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.compact)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textMuted, fontSize: 10.5),
                      ),
                    ),
                  Text(
                    formatCountdown(_left),
                    style: TextStyle(
                      color: ring,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
