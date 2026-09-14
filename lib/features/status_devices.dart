library;

/// Status-tab device-management cards (SSOT): connected stations,
/// power-save presets, reboot/shutdown actions and the firmware data cap.
/// Stateless — [StatusTab] owns the polling state; this module renders.
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_utils.dart';

/// Connected clients with metadata, expandable. Count + freshness in
/// the header; per-client hostname, IP, MAC, and connection time
/// (shown only when the firmware reports it).
class DevicesCard extends StatelessWidget {
  final List<AttachedDevice> devices;
  final DateTime? devicesAt;
  final bool busy;
  final bool open;
  final bool connected;
  final VoidCallback? onRefresh;
  final VoidCallback? onToggleOpen;

  const DevicesCard({
    super.key,
    required this.devices,
    required this.devicesAt,
    required this.busy,
    required this.open,
    required this.connected,
    this.onRefresh,
    this.onToggleOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'CONNECTED DEVICES',
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
              Text(
                '${devices.length} connected',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              if (devicesAt != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    timeAgo(devicesAt!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 11.5),
                  ),
                ),
              IconButton(
                tooltip: 'Refresh clients',
                onPressed: !connected || busy ? null : onRefresh,
                icon: Icon(Icons.refresh, color: c.accentText, size: 19),
              ),
              IconButton(
                tooltip: open ? 'Collapse' : 'Expand',
                onPressed: onToggleOpen,
                icon: Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  color: c.textMuted,
                  size: 20,
                ),
              ),
            ],
          ),
          if (!open)
            Text(
              'No stations reported.',
              style: TextStyle(color: c.textSecondary, fontSize: 12.5),
            )
          else if (busy && devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(10),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'No stations reported — nothing is connected over WiFi.',
                style: TextStyle(color: c.textMuted, fontSize: 12.5),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                physics: devices.length > 4
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: devices.length,
                itemBuilder: (_, index) {
                  final d = devices[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(70),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: c.borderSubtle),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: c.accent.withAlpha(26),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.devices_outlined,
                              size: 16,
                              color: c.accentText,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  d.hostname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: c.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Row(
                                  children: [
                                    MetaRow(
                                      icon: Icons.router_outlined,
                                      text: d.ip,
                                    ),
                                    if (d.mac.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      MetaRow(
                                        icon: Icons.lan_outlined,
                                        text: d.mac,
                                      ),
                                    ],
                                    if (d.connectedAt != null) ...[
                                      const SizedBox(width: 8),
                                      MetaRow(
                                        icon: Icons.schedule_outlined,
                                        text:
                                            'joined ${timeAgo(d.connectedAt!)}',
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
class MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const MetaRow({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c.textMuted),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textMuted,
                fontSize: 10.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Firmware power-save as explicit presets, never free text. Unknown
/// raw values surface as their own option so nothing is lost.
class PowerCard extends StatelessWidget {
  final String powerSave;
  final bool busy;
  final bool connected;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onApply;

  const PowerCard({
    super.key,
    required this.powerSave,
    required this.busy,
    required this.connected,
    this.onChanged,
    this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final options = <String, String>{
      '0': 'Off — always connected',
      '1': 'Auto power save',
    };
    final current = powerSave;
    if (current.isNotEmpty && !options.containsKey(current)) {
      options[current] = 'Current: "$current"';
    }
    final normalized = options.containsKey(current) ? current : '0';
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Power save'),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: normalized,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Power save',
                    isDense: true,
                  ),
                  items: [
                    for (final e in options.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: !connected
                      ? null
                      : (v) => onChanged?.call(v ?? '0'),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: !connected || busy ? null : onApply,
                child: const Text('Apply'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Power save pauses WiFi after idle — the app may lose the connection while it "sleeps".',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// Device actions, confirmed before sending.
class DeviceActionsCard extends StatelessWidget {
  final bool connected;
  final ValueChanged<String>? onAction;

  const DeviceActionsCard({super.key, required this.connected, this.onAction});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: !connected ? null : () => onAction?.call('reboot'),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('Reboot MiFi'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: !connected ? null : () => onAction?.call('shutdown'),
              icon: Icon(Icons.power_settings_new, size: 16, color: c.danger),
              label: Text('Shut down', style: TextStyle(color: c.danger)),
            ),
          ),
        ],
      ),
    );
  }
}

