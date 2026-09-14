import 'package:flutter/material.dart';

import 'theme.dart';

/// Desktop rail: brand mark, view switcher, connection footer.
/// Rhema operator-sidebar pattern (translucent surface, glow-pill active).
class AppSidebar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final bool connected;
  final String gatewayIp;

  const AppSidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.connected,
    required this.gatewayIp,
  });

  static const _items = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Status'),
    (Icons.sms_outlined, Icons.sms, 'SMS'),
    (Icons.dialpad_outlined, Icons.dialpad, 'USSD'),
    (Icons.info_outline, Icons.info, 'Info'),
    (Icons.settings_outlined, Icons.settings, 'Device'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Container(
      width: 184,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface.withAlpha(120),
        border: Border(right: BorderSide(color: c.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Brand mark.
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.accent.withAlpha(110)),
                ),
                child: Icon(
                  Icons.wifi_tethering,
                  color: c.accentText,
                  size: 18,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MF935',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Companion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'VIEWS',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < _items.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            _SideNavButton(
              icon: _items[i].$1,
              activeIcon: _items[i].$2,
              label: _items[i].$3,
              active: selected == i,
              onTap: () => onSelect(i),
            ),
          ],
          const Spacer(),
          // Connection footer — always visible, never in the way.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: (connected ? c.live : c.danger).withAlpha(22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: (connected ? c.live : c.danger).withAlpha(70),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: connected ? c.live : c.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    connected ? gatewayIp : 'offline',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: connected ? c.live : c.danger,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SideNavButton({
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
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active ? c.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: c.accentGlow,
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              active ? activeIcon : icon,
              size: 16,
              color: active ? Colors.black : c.textSecondary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: active ? Colors.black : c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
