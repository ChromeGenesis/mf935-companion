library;

/// Status-tab device-management cards (SSOT): connected stations,
/// power-save presets, reboot/shutdown actions and the firmware data cap.
/// Stateless — [StatusTab] owns the polling state; this module renders.
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/dialogs.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_utils.dart';

/// Connected clients with metadata, fully expanded by default — the
/// Status view keeps every client visible (device-management controls
/// live on the Settings tab). Per-client hostname, IP, MAC, and
/// connection time (shown only when the firmware reports it).
class DevicesCard extends StatelessWidget {
  final List<AttachedDevice> devices;
  final DateTime? devicesAt;
  final bool busy;
  final bool connected;
  final VoidCallback? onRefresh;

  const DevicesCard({
    super.key,
    required this.devices,
    required this.devicesAt,
    required this.busy,
    required this.connected,
    this.onRefresh,
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
            ],
          ),
          if (busy && devices.isEmpty)
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
            // Fully expanded: every client visible, no scroll cap. The
            // card lives inside the scroll view, so length is free.
            Column(
              children: [
                for (var index = 0; index < devices.length; index++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: c.chip,
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
                                  devices[index].hostname,
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
                                      text: devices[index].ip,
                                    ),
                                    if (devices[index].mac.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      MetaRow(
                                        icon: Icons.lan_outlined,
                                        text: devices[index].mac,
                                      ),
                                    ],
                                    if (devices[index].connectedAt != null) ...[
                                      const SizedBox(width: 8),
                                      MetaRow(
                                        icon: Icons.schedule_outlined,
                                        text:
                                            'joined ${timeAgo(devices[index].connectedAt!)}',
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
                  ),
              ],
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

/// Battery Saver label for a raw auto_power_save value. The firmware
/// only reports 0/1; unknown values fall through to the raw string so
/// nothing is lost.
String batterySaverLabel(String raw) => switch (raw) {
  '0' => 'Off — always connected',
  '1' => 'Battery saver on',
  '' => '—',
  _ => 'Firmware value: "$raw"',
};

/// ZTE Wi-Fi coverage modes, matching the official ZTE app structure.
const wifiCoverageOptions = <(String, String, String)>{
  ('0', 'Short range', 'Smallest Wi-Fi footprint — lowest battery drain'),
  ('1', 'Standard', 'Balanced range and power use'),
  ('2', 'Pass-through wall', 'Strongest signal through walls — highest battery drain'),
};

/// Wi-Fi sleep presets (minutes), matching the official ZTE app.
const wifiSleepOptions = <(int, String, String)>{
  (0, 'Never', 'Wi-Fi stays on — highest battery drain'),
  (5, '5m', 'Sleeps after 5 minutes idle'),
  (10, '10m', 'Sleeps after 10 minutes idle'),
  (20, '20m', 'Sleeps after 20 minutes idle'),
  (30, '30m', 'Sleeps after 30 minutes idle'),
  (60, '1h', 'Sleeps after one hour idle'),
  (120, '2h', 'Sleeps after two hours idle'),
};

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

/// Power management card (SSOT), mirroring the official ZTE app:
/// Battery Saver, Wi-Fi Coverage (Short range / Standard / Pass-through
/// wall, with battery-consumption warnings) and Wi-Fi Sleep presets.
/// Uses the custom [GlassSelector] — never a Material dropdown.
class PowerCard extends StatelessWidget {
  final String powerSave;
  final String wifiCoverage;
  final int? wifiSleepMinutes; // null = firmware did not report
  final bool busy;
  final bool connected;
  final ValueChanged<String>? onPowerSaveChanged;
  final ValueChanged<String>? onCoverageChanged;
  final ValueChanged<int>? onSleepChanged;
  final VoidCallback? onApply;

  const PowerCard({
    super.key,
    required this.powerSave,
    required this.wifiCoverage,
    required this.wifiSleepMinutes,
    required this.busy,
    required this.connected,
    this.onPowerSaveChanged,
    this.onCoverageChanged,
    this.onSleepChanged,
    this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;

    // Battery Saver options; unknown firmware values surface as their
    // own option so nothing is silently lost.
    final saverOptions = <GlassSelectorOption<String>>[
      const GlassSelectorOption(
        value: '0',
        label: 'Off — always connected',
        hint: 'Wi-Fi never pauses',
        icon: Icons.power_off_outlined,
      ),
      const GlassSelectorOption(
        value: '1',
        label: 'Battery saver on',
        hint: 'Pauses Wi-Fi when idle — the app may lose connection while it sleeps',
        icon: Icons.battery_saver_outlined,
      ),
    ];
    if (powerSave.isNotEmpty &&
        powerSave != '0' &&
        powerSave != '1') {
      saverOptions.add(
        GlassSelectorOption(
          value: powerSave,
          label: 'Firmware value: "$powerSave"',
          icon: Icons.help_outline,
        ),
      );
    }
    final saver = powerSave.isEmpty ? '0' : powerSave;

    // Coverage: normalize unknown firmware values onto Standard unless
    // they match a known option.
    final knownCoverage = wifiCoverageOptions
        .map((o) => o.$1)
        .contains(wifiCoverage);
    final coverage = knownCoverage ? wifiCoverage : '1';

    // Sleep: pick the closest known preset when the firmware value is
    // not an exact match (e.g. 90s rounds to a preset).
    final sleepKnown = wifiSleepMinutes == null
        ? null
        : wifiSleepOptions.where((o) => o.$1 == wifiSleepMinutes).toList();
    final sleep = sleepKnown == null || sleepKnown.isEmpty
        ? 30
        : wifiSleepMinutes!;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Power management')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: !connected || busy ? null : onApply,
                child: Text(
                  busy ? 'Applying…' : 'Apply',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Compact rows: label left, current value right, tap opens
          // the glass modal. Three rows instead of three stacked fields.
          _PowerRow(
            icon: Icons.battery_saver_outlined,
            label: 'Battery Saver',
            value: batterySaverLabel(saver),
            enabled: connected,
            onTap: () async {
              final picked = await _pick<String>(
                context,
                title: 'Battery saver',
                selected: saver,
                options: [
                  for (final o in saverOptions)
                    (o.value, o.label, o.hint ?? '', o.icon),
                ],
              );
              if (picked != null) onPowerSaveChanged?.call(picked);
            },
          ),
          _PowerRow(
            icon: switch (coverage) {
              '0' => Icons.home_outlined,
              '2' => Icons.domain_outlined,
              _ => Icons.wifi_2_bar_outlined,
            },
            label: 'Wi-Fi Coverage',
            value: wifiCoverageOptions
                .firstWhere((o) => o.$1 == coverage)
                .$2,
            enabled: connected,
            warn: coverage == '2',
            onTap: () async {
              final picked = await _pick<String>(
                context,
                title: 'Wi-Fi coverage',
                selected: coverage,
                options: [
                  for (final (value, name, hint) in wifiCoverageOptions)
                    (
                      value,
                      name,
                      hint,
                      switch (value) {
                        '0' => Icons.home_outlined,
                        '2' => Icons.domain_outlined,
                        _ => Icons.wifi_2_bar_outlined,
                      },
                    ),
                ],
              );
              if (picked != null) onCoverageChanged?.call(picked);
            },
          ),
          _PowerRow(
            icon: sleep == 0 ? Icons.all_inclusive : Icons.bedtime_outlined,
            label: 'Wi-Fi Sleep',
            value: wifiSleepOptions.firstWhere((o) => o.$1 == sleep).$2,
            enabled: connected,
            onTap: () async {
              final picked = await _pick<int>(
                context,
                title: 'Wi-Fi sleep',
                selected: sleep,
                options: [
                  for (final (minutes, name, hint) in wifiSleepOptions)
                    (
                      minutes,
                      name,
                      hint,
                      minutes == 0 ? Icons.all_inclusive : Icons.bedtime_outlined,
                    ),
                ],
              );
              if (picked != null) onSleepChanged?.call(picked);
            },
          ),
          // Battery-consumption warning for the high-power mode only.
          if (coverage == '2')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.battery_alert_outlined,
                      size: 13, color: c.accentText),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Pass-through wall keeps the radio at full power — '
                      'expect noticeably shorter battery life.',
                      style: TextStyle(color: c.accentText, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Open the glass option modal and return the picked value.
  Future<T?> _pick<T>(
    BuildContext context, {
    required String title,
    required T selected,
    required List<(T, String, String, IconData?)> options,
  }) {
    return showGlassModal<T>(
      context,
      icon: Icons.tune,
      title: title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _PowerOptionRow<T>(
              value: options[i].$1,
              label: options[i].$2,
              hint: options[i].$3,
              icon: options[i].$4,
              selected: options[i].$1 == selected,
              onTap: () => Navigator.of(context).pop(options[i].$1),
            ),
          ],
        ],
      ),
    );
  }
}

/// One compact settings row: icon + label left, current value right.
class _PowerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool enabled;
  final bool warn;
  final VoidCallback? onTap;

  const _PowerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    this.warn = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Icon(icon, size: 15, color: c.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: warn ? c.accentText : c.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 16, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// One option row inside the power-management modal.
class _PowerOptionRow<T> extends StatelessWidget {
  final T value;
  final String label;
  final String hint;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _PowerOptionRow({
    required this.value,
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? c.accentText : c.textMuted),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? c.accentText : c.textPrimary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (hint.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle, size: 17, color: c.accentText),
          ],
        ),
      ),
    );
  }
}
