library;

/// Settings tab (SSOT): the device-management surface. Houses the
/// Connection panel, Appearance (theme), Diagnostics log, Device
/// actions (reboot/shutdown) and Power management — relocated off the
/// Status tab so the dashboard stays read-only + glanceable. Also
/// archives the verbose raw USSD balance replies that used to clutter
/// the primary screen.
import 'package:flutter/material.dart';

import '../core/capability.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';
import '../main.dart' show ZteApp;
import 'advanced_card.dart';
import 'dashboard_panels.dart';
import 'device_intel_card.dart';
import 'incident_card.dart';
import 'monitor_modes_card.dart';
import 'smart_alerts_card.dart';
import 'status_devices.dart';

class SettingsTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;

  // Connection panel state (owned by the shell, shared with Status).
  final TextEditingController ipCtrl;
  final TextEditingController passCtrl;
  final bool busy;
  final int cooldownLeft;
  final String loginMessage;
  final bool? loginOk;
  final VoidCallback onLogin;
  final VoidCallback onTest;
  final VoidCallback onPasswordSubmit;

  // Diagnostics panel state (owned by the shell).
  final List<String> logLines;
  final VoidCallback onClearLog;
  final Future<void> Function() onExportDiagnostics;
  final Map<String, String> unsupported;

  // Raw balance-reply archive (owned by the shell, fed by StatusTab).
  final List<String> balanceRawLog;
  final VoidCallback onClearBalanceLog;

  final void Function(String) log;

  /// Route a native toast (dashboard-owned).
  final Future<void> Function(String title, String body) notify;

  /// Restart polling (monitor mode changed interval/toggles).
  final VoidCallback? onMonitorChanged;

  /// Re-apply the loopback API toggle immediately.
  final VoidCallback? onApiChanged;

  /// Report a firmware rejection once so the shell can latch it in the
  /// capability matrix instead of retrying.
  final void Function(String goformId, String reason)? onUnsupported;

  const SettingsTab({
    super.key,
    required this.client,
    required this.connected,
    required this.ipCtrl,
    required this.passCtrl,
    required this.busy,
    required this.cooldownLeft,
    required this.loginMessage,
    required this.loginOk,
    required this.onLogin,
    required this.onTest,
    required this.onPasswordSubmit,
    required this.logLines,
    required this.onClearLog,
    required this.onExportDiagnostics,
    required this.balanceRawLog,
    required this.onClearBalanceLog,
    required this.log,
    required this.notify,
    this.onMonitorChanged,
    this.onApiChanged,
    this.unsupported = const {},
    this.onUnsupported,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  // Power management (relocated from the Status tab).
  String _powerSave = '';
  String _wifiCoverage = '';
  int? _wifiSleepMinutes; // null = firmware did not report
  bool _powerBusy = false;

  @override
  void initState() {
    super.initState();
    if (widget.connected) _loadPowerSave();
  }

  @override
  void didUpdateWidget(SettingsTab old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _loadPowerSave();
  }

  Future<void> _loadPowerSave() async {
    if (!widget.connected) return;
    try {
      final results = await (
        widget.client.getPowerSave(),
        widget.client.getWifiCoverage(),
        widget.client.getWifiSleepMinutes(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _powerSave = results.$1;
        _wifiCoverage = results.$2;
        _wifiSleepMinutes = results.$3;
      });
    } catch (e) {
      widget.log('power settings load failed: $e');
    }
  }

  /// Apply the full power-management selection: battery saver + Wi-Fi
  /// coverage + Wi-Fi sleep. Each write is capability-safe: a firmware
  /// rejection is latched once via onUnsupported and logged with the
  /// modem result + next action — never retried in a loop.
  Future<void> _applyPowerSave() async {
    if (!widget.connected || _powerBusy) return;
    setState(() => _powerBusy = true);
    try {
      final saverOk = await widget.client.setPowerSave(_powerSave);
      if (!saverOk) {
        widget.onUnsupported?.call(
          'SET_AUTO_POWER_SAVE',
          'result=error on mode "$_powerSave"',
        );
        widget.log(
          formatCommandFailure(
            command: 'SET_AUTO_POWER_SAVE',
            result: 'error',
            next:
                'This firmware may not support power-save writes — '
                'leaving current mode.',
          ),
        );
      } else {
        widget.log('battery saver set to "${batterySaverLabel(_powerSave)}"');
      }

      if (_wifiCoverage.isNotEmpty) {
        final covOk = await widget.client.setWifiCoverage(_wifiCoverage);
        if (!covOk) {
          widget.onUnsupported?.call(
            'SET_WIFI_COVERAGE',
            'result=error on mode "$_wifiCoverage"',
          );
          widget.log(
            formatCommandFailure(
              command: 'SET_WIFI_COVERAGE',
              result: 'error',
              next: 'This firmware may not support coverage writes — '
                  'keep the current mode.',
            ),
          );
        } else {
          widget.log('Wi-Fi coverage set to "$_wifiCoverage"');
        }
      }

      if (_wifiSleepMinutes != null) {
        final sleepOk = await widget.client.setWifiSleep(_wifiSleepMinutes!);
        if (!sleepOk) {
          widget.onUnsupported?.call(
            'SET_WIFI_SLEEP',
            'result=error on ${_wifiSleepMinutes}m',
          );
          widget.log(
            formatCommandFailure(
              command: 'SET_WIFI_SLEEP',
              result: 'error',
              next: 'This firmware may not support sleep writes — '
                  'keep the current timer.',
            ),
          );
        } else {
          widget.log('Wi-Fi sleep set to $_wifiSleepMinutes min');
        }
      }

      // Re-read so the card always shows the firmware's truth.
      await _loadPowerSave();
    } catch (e) {
      widget.log('power settings failed: $e');
    } finally {
      if (mounted) setState(() => _powerBusy = false);
    }
  }

  Future<void> _devicePowerAction(String kind) async {
    final confirm = await confirmAction(
      context,
      icon: kind == 'reboot' ? Icons.restart_alt : Icons.power_settings_new,
      title: kind == 'reboot' ? 'Reboot the MiFi?' : 'Shut down?',
      message: kind == 'reboot'
          ? 'WiFi drops for ~1 minute, then it comes back. The app will keep polling.'
          : 'The MiFi turns OFF. You will need to power it on physically.',
      confirmLabel: kind == 'reboot' ? 'Reboot' : 'Shut down',
    );
    if (!confirm) return;
    try {
      final raw = kind == 'reboot'
          ? await widget.client.reboot()
          : await widget.client.shutdown();
      widget.log('$kind sent. Modem said: $raw');
    } catch (e) {
      // Reboot/shutdown kills the HTTP connection mid-reply — a transport
      // error here usually MEANS it worked.
      widget.log('$kind sent (connection dropped as expected: $e)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ConnectionPanel(
      ipCtrl: widget.ipCtrl,
      passCtrl: widget.passCtrl,
      busy: widget.busy,
      cooldownLeft: widget.cooldownLeft,
      connected: widget.connected,
      loginMessage: widget.loginMessage,
      loginOk: widget.loginOk,
      onLogin: widget.onLogin,
      onTest: widget.onTest,
      onPasswordSubmit: widget.onPasswordSubmit,
    );
    final log = DiagnosticsPanel(
      lines: widget.logLines,
      onClear: widget.onClearLog,
      onExport: widget.onExportDiagnostics,
      unsupported: widget.unsupported,
    );

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final deviceActions = DeviceActionsCard(
            connected: widget.connected,
            onAction: _devicePowerAction,
          );          final power = PowerCard(
            powerSave: _powerSave,
            wifiCoverage: _wifiCoverage,
            wifiSleepMinutes: _wifiSleepMinutes,
            busy: _powerBusy,
            connected: widget.connected,
            onPowerSaveChanged: (v) => setState(() => _powerSave = v),
            onCoverageChanged: (v) => setState(() => _wifiCoverage = v),
            onSleepChanged: (v) => setState(() => _wifiSleepMinutes = v),
            onApply: _applyPowerSave,
          );
          final rawLog = GlassCard(
            padding: const EdgeInsets.all(14),
            child: _BalanceRawLog(
              lines: widget.balanceRawLog,
              onClear: widget.onClearBalanceLog,
            ),
          );
          const appearance = _AppearanceCard();
          final intel = DeviceIntelCard(
            client: widget.client,
            connected: widget.connected,
            log: widget.log,
            notify: widget.notify,
          );
          final monitors = MonitorModesCard(
            onChanged: widget.onMonitorChanged,
          );
          final incident = IncidentCard(
            client: widget.client,
            connected: widget.connected,
            logLines: widget.logLines,
            unsupported: widget.unsupported,
            log: widget.log,
          );
          final advanced = AdvancedCard(
            client: widget.client,
            connected: widget.connected,
            log: widget.log,
            onApiChanged: widget.onApiChanged,
          );

          if (wide) {
            return Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: conn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        children: [
                          deviceActions,
                          const SizedBox(height: 10),
                          power,
                          const SizedBox(height: 10),
                          const SmartAlertsCard(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: intel),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: monitors),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: incident),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: advanced),
                const SizedBox(height: 10),
                const SizedBox(
                  width: double.infinity,
                  child: appearance,
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: rawLog),
                    const SizedBox(width: 10),
                    Expanded(child: SizedBox(height: 280, child: log)),
                  ],
                ),
              ],
            );
          }
          return Column(
            children: [
              conn,
              const SizedBox(height: 10),
              appearance,
              const SizedBox(height: 10),
              deviceActions,
              const SizedBox(height: 10),
              power,
              const SizedBox(height: 10),
              const SmartAlertsCard(),
              const SizedBox(height: 10),
              intel,
              const SizedBox(height: 10),
              monitors,
              const SizedBox(height: 10),
              incident,
              const SizedBox(height: 10),
              advanced,
              const SizedBox(height: 10),
              rawLog,
              const SizedBox(height: 10),
              SizedBox(height: 220, child: log),
            ],
          );
        },
      ),
    );
  }
}

/// Raw USSD/balance reply archive: verbose modem chatter lives here, out
/// of the primary screen. Only parsed results surface on Status.
class _BalanceRawLog extends StatelessWidget {
  final List<String> lines;
  final VoidCallback onClear;

  const _BalanceRawLog({required this.lines, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(child: SectionLabel('Raw data log')),
            InkWell(
              onTap: lines.isEmpty ? null : onClear,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  'clear',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
            ),
          ],
        ),
        if (lines.isEmpty)
          Text(
            'No raw replies yet — every balance dial (MTN *323*4#, '
            'Airtel *323*1#) is archived here, '
            'full modem text, newest first. The Status card shows only '
            'parsed results.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          )
        else ...[
          Text(
            '${lines.length} entr${lines.length == 1 ? 'y' : 'ies'} — newest first.',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: SelectableText(
                lines.join('\n\n'),
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11.5,
                  height: 1.55,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Appearance card: Light / Dark / Auto theme switcher. Relocated
/// here from the top header, where the chip competed with the system
/// status-bar tap area on phones. Defaults to Auto (follows system).
/// The switcher drops below the label on narrow phones so the
/// "Appearance" title never wraps.
class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    // No saved choice yet → Auto. Fresh installs follow the system.
    final mode = ZteApp.maybeMode(context) ?? ThemeMode.system;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
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
            switch (mode) {
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
              _ => Icons.brightness_auto_outlined,
            },
            size: 17,
            color: c.accentText,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Appearance',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                switch (mode) {
                  ThemeMode.light => 'Light theme',
                  ThemeMode.dark => 'Dark theme',
                  _ => 'Auto · follows system',
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (ctx, cons) {
          // Narrow (<400px): stack the switcher full-width underneath
          // so it never squeezes the title onto two lines.
          if (cons.maxWidth < 400) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                label,
                const SizedBox(height: 10),
                _ThemeSwitcher(selected: mode),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: label),
              const SizedBox(width: 8),
              Expanded(child: _ThemeSwitcher(selected: mode)),
            ],
          );
        },
      ),
    );
  }
}

/// Theme switcher shell: resolves [ZteApp.setThemeMode] with the real
/// context at tap time (a const switcher subtree cannot).
class _ThemeSwitcher extends StatelessWidget {
  final ThemeMode selected;

  const _ThemeSwitcher({required this.selected});

  @override
  Widget build(BuildContext context) {
    return PillSwitcher<ThemeMode>(
      expanded: true,
      options: const [
        PillOption(
          value: ThemeMode.light,
          label: 'Light',
          icon: Icons.light_mode_outlined,
        ),
        PillOption(
          value: ThemeMode.dark,
          label: 'Dark',
          icon: Icons.dark_mode_outlined,
        ),
        PillOption(
          value: ThemeMode.system,
          label: 'Auto',
          icon: Icons.brightness_auto_outlined,
        ),
      ],
      selected: selected,
      onChanged: (m) => ZteApp.setThemeMode(context, m),
    );
  }
}
