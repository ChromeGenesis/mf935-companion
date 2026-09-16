library;

/// Core UI primitives for the MF935 companion (SSOT).
///
/// Extracted from the former `widgets.dart` god file: ambient background,
/// glass cards, labels, pills, tiles, bars, rings, switches, checkboxes
/// and empty states. Dialogs live in `dialogs.dart`, the countdown ring in
/// `expiry_widgets.dart`; `widgets.dart` re-exports all three so existing
/// imports keep working unchanged.
import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'theme.dart';

/// Ambient background: amber orb top-left + secondary orb bottom-right
/// over the theme scaffold. Cheap radial gradients, zero BackdropFilter
/// cost.
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

/// Glass card: barely-there fill + subtle border, 16px radius.
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
    // TradeMum GlassMorphicCard architecture: ClipRRect -> DecoratedBox,
    // no BackdropFilter — the glass illusion comes from a low-alpha
    // fill (alpha ~20 of the theme surface) over the ambient orbs, plus
    // a faint foreground border (borderSubtle, never opaque white).
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: highlighted
              ? c.accent.withAlpha(28)
              : c.surface.withAlpha(56),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlighted
                ? c.accent.withAlpha(90)
                : c.borderSubtle,
            width: highlighted ? 1.0 : 0.8,
          ),
          boxShadow: highlighted
              ? [
                  // Tight, small glow — a big offset shadow reads as a
                  // color bleed under the card.
                  BoxShadow(
                    color: c.accentGlow.withAlpha(50),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: child,
      ),
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
    // Icon sits beside the caption only — the value takes the FULL tile
    // width, so "107.0 GB" never ellipsizes on narrow phones.
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.fade,
          style: TextStyle(
            color: valueColor ?? c.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Row(
          children: [
            Icon(icon, size: 14, color: c.textMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right, size: 15, color: c.textMuted),
          ],
        ),
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

/// Battery ring with % in the middle. When [charging] is true a soft
/// pulse + slow rotation play on the ring so charging reads as active
/// at a glance. Inner labels are size-relative + scale-down fitted, so
/// the "charging" caption can never overflow the circle boundary.
class BatteryRing extends StatefulWidget {
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
  State<BatteryRing> createState() => _BatteryRingState();
}

class _BatteryRingState extends State<BatteryRing>
    with TickerProviderStateMixin {
  AnimationController? _pulse;
  AnimationController? _spin;

  @override
  void initState() {
    super.initState();
    if (widget.charging) _start();
  }

  @override
  void didUpdateWidget(BatteryRing old) {
    super.didUpdateWidget(old);
    if (widget.charging && !old.charging) {
      _start();
    } else if (!widget.charging && old.charging) {
      _stop();
    }
  }

  void _start() {
    _pulse ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _spin ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    );
    if (!(_pulse?.isAnimating ?? false)) {
      _pulse?.repeat(reverse: true);
    }
    if (!(_spin?.isAnimating ?? false)) _spin?.repeat();
  }

  void _stop() {
    _pulse?.stop();
    _spin?.stop();
  }

  @override
  void dispose() {
    _pulse?.dispose();
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final size = widget.size;
    final p = (widget.percent ?? 0).clamp(0, 100) / 100.0;
    final color = widget.percent == null
        ? c.textMuted
        : widget.charging
        ? c.live
        : widget.percent! <= 20
        ? c.danger
        : c.accent;
    // Size-relative typography: the caption always fits inside the
    // ring, no matter how small the hero renders it.
    final percentFont = (size * 0.26).clamp(14.0, 28.0);
    final labelFont = (size * 0.13).clamp(8.5, 12.0);
    final boltSize = (size * 0.19).clamp(12.0, 20.0);

    final ring = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        value: p,
        strokeWidth: 9,
        backgroundColor: c.textMuted.withAlpha(40),
        valueColor: AlwaysStoppedAnimation(color),
        strokeCap: StrokeCap.round,
      ),
    );

    final core = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ring,
          if (widget.charging && _spin != null)
            // Slow rotating highlight arc over the base ring.
            RotationTransition(
              turns: _spin!,
              child: SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  value: 0.28,
                  strokeWidth: 3.5,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(
                    c.live.withAlpha(160),
                  ),
                  strokeCap: StrokeCap.round,
                ),
              ),
            ),
          // Constrained center: fitted so long captions ("charging")
          // scale down instead of clipping past the circle edge.
          SizedBox(
            width: size * 0.68,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.charging)
                  _PulseBolt(iconSize: boltSize, color: c.live, pulse: _pulse)
                else
                  SizedBox(height: boltSize * 0.35),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.percent == null ? '--' : '${widget.percent}%',
                    maxLines: 1,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: percentFont,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.charging ? 'charging' : 'battery',
                    maxLines: 1,
                    style: TextStyle(color: c.textMuted, fontSize: labelFont),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!widget.charging) return core;

    // Soft breathing glow behind the ring while charging.
    final pulse = _pulse;
    if (pulse == null) return core;
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = pulse.value; // 0..1
        return Container(
          width: size + 10,
          height: size + 10,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: c.live.withAlpha((18 + t * 30).round()),
                blurRadius: 14 + t * 10,
                spreadRadius: 1 + t * 2,
              ),
            ],
          ),
          child: child,
        );
      },
      child: core,
    );
  }
}

/// Charging bolt with a gentle opacity pulse. Static icon when no
/// controller is attached (e.g. first frame before _start).
class _PulseBolt extends StatelessWidget {
  final double iconSize;
  final Color color;
  final AnimationController? pulse;

  const _PulseBolt({
    required this.iconSize,
    required this.color,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.bolt, size: iconSize, color: color);
    final p = pulse;
    if (p == null) return icon;
    return AnimatedBuilder(
      animation: p,
      builder: (_, _) =>
          Opacity(opacity: 0.65 + p.value * 0.35, child: icon),
    );
  }
}

/// One option in a [PillSwitcher].
class PillOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  const PillOption({required this.value, required this.label, this.icon});
}

/// Rhema-style frosted switcher: shell container + animated pills.
/// Replaces every SegmentedButton in the app (SSOT). With [expanded],
/// the shell fills its parent and pills split the width evenly —
/// no empty track trailing the last option.
class PillSwitcher<T> extends StatelessWidget {
  final List<PillOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final bool expanded;

  const PillSwitcher({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        width: expanded ? double.infinity : null,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (final o in options)
              expanded
                  ? Expanded(child: _pill(context, c, o))
                  : Flexible(child: _pill(context, c, o)),
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, ZteColors c, PillOption<T> o) {
    return GestureDetector(
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
                        Flexible(
                          child: Text(
                            o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
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

/// One selectable row inside a [GlassSelector].
class GlassSelectorOption<T> {
  final T value;
  final String label;
  final String? hint;
  final IconData? icon;

  const GlassSelectorOption({
    required this.value,
    required this.label,
    this.hint,
    this.icon,
  });
}

/// Custom glassmorphic selector: a frosted field that opens a glass
/// modal list. Replaces every Material dropdown in this app (SSOT).
class GlassSelector<T> extends StatelessWidget {
  final List<GlassSelectorOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final String title;
  final String label;
  final bool enabled;

  const GlassSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.title,
    this.label = 'Select',
    this.enabled = true,
  });

  String get _currentLabel {
    for (final o in options) {
      if (o.value == selected) return o.label;
    }
    return options.isNotEmpty ? options.first.label : '—';
  }

  Future<void> _open(BuildContext context) async {
    final c = context.zc;
    final picked = await showGlassModal<T>(
      context,
      icon: Icons.tune,
      title: title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _GlassOptionRow<T>(
              option: options[i],
              selected: options[i].value == selected,
              onTap: () => Navigator.of(context).pop(options[i].value),
            ),
          ],
        ],
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
        ),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: c.inputBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(color: c.textSecondary, fontSize: 11.5),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _currentLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 18,
                    color: c.textMuted,
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

class _GlassOptionRow<T> extends StatelessWidget {
  final GlassSelectorOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  const _GlassOptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? c.accent.withAlpha(36)
              : c.chip,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? c.accent.withAlpha(110) : c.borderSubtle,
          ),
        ),
        child: Row(
          children: [
            if (option.icon != null) ...[
              Icon(
                option.icon,
                size: 16,
                color: selected ? c.accentText : c.textMuted,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      color: selected ? c.accentText : c.textPrimary,
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (option.hint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      option.hint!,
                      style: TextStyle(color: c.textMuted, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 18, color: c.accentText),
          ],
        ),
      ),
    );
  }
}

/// App checkbox: transparent with a hairline border when off, amber fill
/// + tick when on. The only checkbox shape in this app.
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
