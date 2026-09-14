import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'zte_client.dart';

/// App checkbox: transparent with a hairline border when off, amber when
/// on. The raw Material Checkbox keeps its fill in every state — amber
/// box + glow even unticked — so every checkbox goes through this.

/// Ambient background: near-black + amber orb top-left + indigo orb
/// bottom-right. Cheap radial gradients, zero BackdropFilter cost.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Container(
      color: c.scaffold,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -110,
            left: -80,
            child: IgnorePointer(
              child: Container(
                width: 520,
                height: 520,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [c.accent.withAlpha(56), c.accent.withAlpha(0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            right: -90,
            child: IgnorePointer(
              child: Container(
                width: 480,
                height: 480,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.orbSecondary.withAlpha(80),
                      c.orbSecondary.withAlpha(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Glass card: barely-there fill + frosted white border, 16px radius.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlighted;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: highlighted ? c.accent.withAlpha(28) : c.surface.withAlpha(160),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted ? c.accent.withAlpha(140) : c.border,
          width: highlighted ? 1.3 : 1.0,
        ),
        boxShadow: highlighted
            ? [
                BoxShadow(
                  color: c.accentGlow,
                  blurRadius: 22,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}

/// Small caps section label, Rhema style.
class SectionLabel extends StatelessWidget {
  final String text;

  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.6,
        ),
      ),
    );
  }
}

/// Status dot + label pill (connected / logged out / error).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const StatusPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Single stat tile: icon left, big value + caption right. Compact enough
/// for a 2x2 grid inside a fixed-height dashboard (no page scroll).
/// [onTap] makes it a jump link (SMS unread → inbox, devices → Device).
class StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String caption;
  final Color? valueColor;
  final VoidCallback? onTap;

  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.caption,
    this.valueColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final body = Row(
      children: [
        Icon(icon, size: 17, color: c.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: valueColor ?? c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
        if (onTap != null)
          Icon(Icons.chevron_right, size: 16, color: c.textMuted),
      ],
    );
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: body,
            ),
    );
  }
}

/// Cellular signal bars (0–5), amber when strong, red when dead.
class SignalBars extends StatelessWidget {
  final int level; // 0..5, -1 = unknown
  final double height;

  const SignalBars({super.key, required this.level, this.height = 26});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final color = level <= 0
        ? c.danger
        : level <= 2
        ? c.accent
        : c.live;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(5, (i) {
        final on = level >= 0 && i < level;
        return Container(
          width: 5,
          height: height * (0.3 + 0.7 * (i + 1) / 5),
          margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
          decoration: BoxDecoration(
            color: on ? color : c.textMuted.withAlpha(60),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

/// Battery ring with % in the middle.
class BatteryRing extends StatelessWidget {
  final int? percent; // null = unknown
  final bool charging;
  final double size;

  const BatteryRing({
    super.key,
    required this.percent,
    required this.charging,
    this.size = 120,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final p = (percent ?? 0).clamp(0, 100) / 100.0;
    final color = percent == null
        ? c.textMuted
        : charging
        ? c.live
        : percent! <= 20
        ? c.danger
        : c.accent;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: p,
              strokeWidth: 9,
              backgroundColor: c.textMuted.withAlpha(40),
              valueColor: AlwaysStoppedAnimation(color),
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (charging)
                Icon(Icons.bolt, size: 16, color: c.live)
              else
                const SizedBox(height: 4),
              Text(
                percent == null ? '--' : '$percent%',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                charging ? 'charging' : 'battery',
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Rhema-style glass modal shell — the ONE dialog shape in this app.
/// Header (icon pill + title + subtitle + close), body, footer actions.
class GlassModal extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final double width;
  final bool danger;

  const GlassModal({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions,
    this.width = 440,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final accent = danger ? c.danger : c.accent;
    final accentText = danger ? c.danger : c.accentText;
    return Center(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: width,
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height - 88).clamp(
              280.0,
              640.0,
            ),
          ),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.surfaceLifted.withAlpha(245),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 32,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withAlpha(40),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: accent.withAlpha(90)),
                    ),
                    child: Icon(icon, color: accentText, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
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
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close, color: c.textMuted, size: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(child: SingleChildScrollView(child: body)),
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions!.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions![i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Show a [GlassModal] dialog. Single entry point — no raw AlertDialogs.
Future<T?> showGlassModal<T>(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  required Widget body,
  List<Widget>? actions,
  bool danger = false,
  double width = 440,
}) {
  return showDialog<T>(
    context: context,
    // Outside tap always dismisses — no trapped modals.
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassModal(
        icon: icon,
        title: title,
        subtitle: subtitle,
        body: body,
        actions: actions,
        danger: danger,
        width: width,
      ),
    ),
  );
}

/// Destructive/confirm prompt. Returns true when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = true,
}) async {
  final c = context.zc;
  final ok = await showGlassModal<bool>(
    context,
    icon: icon,
    title: title,
    danger: danger,
    body: Text(
      message,
      style: TextStyle(color: c.textSecondary, fontSize: 13.5, height: 1.5),
    ),
    actions: [
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        style: danger
            ? ElevatedButton.styleFrom(
                backgroundColor: c.danger,
                foregroundColor: Colors.white,
              )
            : null,
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(confirmLabel),
      ),
    ],
  );
  return ok == true;
}

/// One option in a [PillSwitcher].
class PillOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  const PillOption({required this.value, required this.label, this.icon});
}

/// Rhema-style frosted switcher: shell container + animated pills.
/// Replaces every SegmentedButton in the app (SSOT).
class PillSwitcher<T> extends StatelessWidget {
  final List<PillOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool enabled;

  const PillSwitcher({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(90),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              Flexible(
                child: GestureDetector(
                  onTap: enabled && o.value != selected
                      ? () => onChanged(o.value)
                      : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: o.value == selected
                          ? c.accent.withAlpha(36)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: o.value == selected
                            ? c.accent.withAlpha(110)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (o.icon != null) ...[
                          Icon(
                            o.icon,
                            size: 13,
                            color: o.value == selected
                                ? c.accentText
                                : c.textMuted,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          o.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: o.value == selected
                                ? c.accentText
                                : c.textMuted,
                            fontSize: 12,
                            fontWeight: o.value == selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
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

/// Centered icon + lines placeholder (logged-out, empty lists, errors).
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c.accent.withAlpha(24),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.accent.withAlpha(80)),
              ),
              child: Icon(icon, color: c.accentText, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textMuted, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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

/// App checkbox: transparent with a hairline border when off, amber fill
/// + black tick when on. The only checkbox shape in this app.
class ZCheck extends StatelessWidget {
  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;

  const ZCheck({
    super.key,
    required this.value,
    this.tristate = false,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return SizedBox(
      width: 28,
      height: 28,
      child: Checkbox(
        value: value,
        tristate: tristate,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: BorderSide(color: c.textMuted.withAlpha(150), width: 1.5),
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return c.accent;
          return Colors.transparent;
        }),
        checkColor: Colors.black,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashRadius: 14,
        onChanged: onChanged,
      ),
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
    final windowSecs = ZteClient.expiryWindowDays(b.name) * 86400;
    final frac = windowSecs <= 0
        ? 0.0
        : (_left.inSeconds / windowSecs).clamp(0.0, 1.0);
    final urgent = _left.inHours <= 48;
    final ring = urgent ? c.danger : c.accentText;
    return Tooltip(
      message:
          '${b.name} · ${ZteClient.formatDataVolume(b.mb)} left · ends ${formatCountdown(_left)}',
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
