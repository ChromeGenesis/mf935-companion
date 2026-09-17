library;

/// Monitoring + battery card (SSOT): Desk/Travel mode, low-battery
/// threshold, notification toggles, and the drain-rate readout.
/// Self-contained prefs I/O; notifies [onChanged] after a save so the
/// shell can restart the poller with the new interval.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/monitor_modes.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

const _lowOptions = <int>[10, 15, 20, 25, 30];

class MonitorModesCard extends StatefulWidget {
  final VoidCallback? onChanged;

  const MonitorModesCard({super.key, this.onChanged});

  @override
  State<MonitorModesCard> createState() => _MonitorModesCardState();
}

class _MonitorModesCardState extends State<MonitorModesCard> {
  MonitorSettings _settings = const MonitorSettings();
  List<BatterySample> _samples = const [];
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    MonitorSettings s;
    List<BatterySample> samples = const [];
    try {
      s = await MonitorSettings.load();
      final prefs = await SharedPreferences.getInstance();
      samples = BatterySamples.decode(prefs.getString(BatterySamples.key));
    } catch (_) {
      s = const MonitorSettings();
    }
    if (mounted) {
      setState(() {
        _settings = s;
        _samples = samples;
        _ready = true;
      });
    }
  }

  Future<void> _save(MonitorSettings s) async {
    final modeChanged = s.mode != _settings.mode;
    setState(() {
      _settings = s;
      _busy = true;
    });
    try {
      await s.save();
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    if (modeChanged) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final s = _settings;
    final drain = drainPerHour(_samples);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withAlpha(90)),
                ),
                child: Icon(
                  s.mode == MonitorMode.desk
                      ? Icons.desktop_windows_outlined
                      : Icons.luggage_outlined,
                  size: 17,
                  color: c.accentText,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SectionLabel('Monitoring & battery')),
              if (_busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.accentText,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_ready)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(),
              ),
            )
          else ...[
            PillSwitcher<MonitorMode>(
              expanded: true,
              options: const [
                PillOption(
                  value: MonitorMode.desk,
                  label: 'Desk',
                  icon: Icons.desktop_windows_outlined,
                ),
                PillOption(
                  value: MonitorMode.travel,
                  label: 'Travel',
                  icon: Icons.luggage_outlined,
                ),
              ],
              selected: s.mode,
              onChanged: (m) => _save(
                MonitorSettings(
                  mode: m,
                  lowBatteryPercent: s.lowBatteryPercent,
                  lowBatteryNotify: s.lowBatteryNotify,
                  fullBatteryNotify: s.fullBatteryNotify,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              monitorModeBlurb(s.mode),
              style: TextStyle(color: c.textMuted, fontSize: 11.5),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.battery_std_outlined, size: 15, color: c.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Drain rate',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ),
                Text(
                  drain == null
                      ? 'collecting…'
                      : drain <= 0
                      ? 'holding charge'
                      : '${drain.toStringAsFixed(1)}%/h',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Low-battery alert at',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ),
                PillSwitcher<int>(
                  options: [
                    for (final p in _lowOptions)
                      PillOption(value: p, label: '$p%'),
                  ],
                  selected: s.lowBatteryPercent,
                  onChanged: (p) => _save(
                    MonitorSettings(
                      mode: s.mode,
                      lowBatteryPercent: p,
                      lowBatteryNotify: s.lowBatteryNotify,
                      fullBatteryNotify: s.fullBatteryNotify,
                    ),
                  ),
                ),
              ],
            ),
            _toggleRow(
              c,
              'Low-battery toast',
              s.lowBatteryNotify,
              (v) => _save(
                MonitorSettings(
                  mode: s.mode,
                  lowBatteryPercent: s.lowBatteryPercent,
                  lowBatteryNotify: v,
                  fullBatteryNotify: s.fullBatteryNotify,
                ),
              ),
            ),
            _toggleRow(
              c,
              'Full + held-at-100% toast',
              s.fullBatteryNotify,
              (v) => _save(
                MonitorSettings(
                  mode: s.mode,
                  lowBatteryPercent: s.lowBatteryPercent,
                  lowBatteryNotify: s.lowBatteryNotify,
                  fullBatteryNotify: v,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toggleRow(
    ZteColors c,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: c.textSecondary, fontSize: 12.5),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: c.accentText,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
