library;

/// Mobile bottom navigation bar (SSOT): compact docked bar in the
/// same glass language as the cards (surface fill + subtle border).
/// Replaces Material's NavigationBar — standard height, five equal
/// slots, icon + 10.5px label, glow pill behind the active slot.
/// Everything is FractionallySizedBox + Flexible so it can never
/// overflow horizontally, and there are no badges to overflow vertically.
import 'package:flutter/material.dart';

import '../core/theme.dart';

class BottomNavBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;

  const BottomNavBar({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  static const _items = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Status'),
    (Icons.sms_outlined, Icons.sms, 'SMS'),
    (Icons.dialpad_outlined, Icons.dialpad, 'USSD'),
    (Icons.info_outline, Icons.info, 'Info'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    // Quiet docked bar: the same translucent surface fill as the cards
    // with a whisper of a shadow — present, never prominent.
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: c.surface.withAlpha(56),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.borderSubtle),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: _NavSlot(
                icon: _items[i].$1,
                activeIcon: _items[i].$2,
                label: _items[i].$3,
                active: selected == i,
                onTap: () => onSelect(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavSlot({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: active ? c.accent.withAlpha(36) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? c.accent.withAlpha(110) : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? activeIcon : icon,
              size: 20,
              color: active ? c.accentText : c.textMuted,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? c.accentText : c.textMuted,
                fontSize: 10.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
