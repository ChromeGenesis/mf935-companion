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

/// Remaining-time label: whole days only above 24h ("11 days"),
/// HH:mm:ss only under a day ("14:22:31"), "expired" past zero.
/// Pure + tested; [CountdownText] ticks it live.
String formatCountdown(Duration left) {
  if (left.inSeconds <= 0) return 'expired';
  final d = left.inDays;
  if (d > 0) return '$d day${d == 1 ? '' : 's'}';
  final h = left.inHours;
  final m = left.inMinutes % 60;
  final s = left.inSeconds % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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

/// Header remaining-time indicator for the next-expiring bundle:
/// a clean pill with an hourglass glyph + "11 days" (or "14:22:31"
/// under a day). Rendered inside the dashboard balance card alongside
/// the active total (relocated from the top header). Tap jumps to Status.
/// Self-ticking — rebuilds only itself, once a second.
class ExpiryDial extends StatefulWidget {
  final DataBundle bundle;
  final bool compact; // narrow screens: no bundle name
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
    final urgent = _left.inHours <= 48;
    final ring = urgent ? c.danger : c.accentText;
    return Tooltip(
      message:
          '${b.name} · ${zu.formatDataVolume(b.mb)} left · ends ${_left.inHours > 24 ? '${_left.inDays} days' : 'in ${formatCountdown(_left)}'}',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: c.surface.withAlpha(170),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: ring.withAlpha(70)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hourglass_bottom, size: 13, color: ring),
              const SizedBox(width: 6),
              // Flexible text: the countdown shrinks/ellipsizes instead of
              // pushing the header past the screen edge on narrow phones.
              Flexible(
                child: Column(
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
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatCountdown(_left),
                        maxLines: 1,
                        style: TextStyle(
                          color: ring,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
