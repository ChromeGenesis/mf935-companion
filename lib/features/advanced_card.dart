library;

/// Advanced card (SSOT): best time-of-day, scheduled diagnostics,
/// read-only capability discovery, safe scheduled reboot, loopback
/// API toggle, and backup/restore. Self-contained prefs I/O + live
/// probes; calls [onApiChanged] after the API toggle so the shell
/// can start/stop the loopback server immediately.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/advanced.dart';
import '../core/dialogs.dart';
import '../core/speed_history.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_client.dart';

const _diagHours = <int>[1, 7, 13, 19];

String _hourLabel(int h) => switch (h) {
  1 => 'Night 1h',
  7 => 'Morning 7h',
  13 => 'Midday 13h',
  _ => 'Evening 19h',
};

class AdvancedCard extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String line) log;
  final VoidCallback? onApiChanged;

  const AdvancedCard({
    super.key,
    required this.client,
    required this.connected,
    required this.log,
    this.onApiChanged,
  });

  @override
  State<AdvancedCard> createState() => _AdvancedCardState();
}

class _AdvancedCardState extends State<AdvancedCard> {
  ({int hour, double avgDown, int count})? _best;
  int _historyCount = 0;
  ScheduledDiag _diag = const ScheduledDiag();
  ScheduledReboot _reboot = const ScheduledReboot();
  DiscoveryResult? _discovery;
  LocalApiSettings _api = const LocalApiSettings();
  bool _busy = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await (
        SpeedHistory.load(),
        ScheduledDiag.load(),
        ScheduledReboot.load(),
        DiscoveryResult.load(),
        LocalApiSettings.load(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _historyCount = results.$1.records.length;
        _best = bestTimeOfDay(results.$1.records);
        _diag = results.$2;
        _reboot = results.$3;
        _discovery = results.$4;
        _api = results.$5;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  Future<void> _probe() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final reply = await widget.client.getStatus(cmds: discoveryProbeKeys);
      final split = splitDiscovery(reply);
      final res = DiscoveryResult(
        at: DateTime.now(),
        supported: split.supported,
        silent: split.silent,
      );
      await res.save();
      if (!mounted) return;
      setState(() => _discovery = res);
      widget.log(
        'capability discovery: ${split.supported.length}/'
        '${discoveryProbeKeys.length} keys answer',
      );
    } catch (e) {
      widget.log('capability discovery failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scheduleReboot(Duration after) async {
    final ok = await confirmAction(
      context,
      icon: Icons.restart_alt,
      title: 'Schedule a reboot?',
      danger: true,
      message:
          'The MiFi reboots once, WiFi drops ~1 minute. The schedule '
          'clears itself after firing — it never repeats. You can cancel '
          'any time before then.',
      confirmLabel: 'Schedule',
    );
    if (!ok) return;
    final r = ScheduledReboot(at: DateTime.now().add(after));
    await r.save();
    if (!mounted) return;
    setState(() => _reboot = r);
    widget.log('reboot scheduled for ${r.at}');
  }

  Future<void> _cancelReboot() async {
    const r = ScheduledReboot();
    await r.save();
    if (mounted) setState(() => _reboot = r);
    widget.log('scheduled reboot cancelled');
  }

  Future<void> _exportBackup() async {
    try {
      final raw = await buildBackup();
      await Clipboard.setData(ClipboardData(text: raw));
      widget.log('backup exported (${raw.length} chars, plaintext JSON)');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup copied (plaintext JSON)')),
        );
      }
    } catch (e) {
      widget.log('backup export failed: $e');
    }
  }

  Future<void> _importBackup() async {
    final raw = await showGlassModal<String>(
      context,
      icon: Icons.restore_outlined,
      title: 'Restore backup',
      subtitle: 'Paste a previously exported backup',
      body: const _PasteForm(),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final n = await restoreBackup(raw.trim());
      widget.log('backup restored ($n keys) — restart the app');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored $n keys — restart the app')),
        );
      }
      _load();
    } catch (e) {
      widget.log('backup restore failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    }
  }

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
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withAlpha(90)),
                ),
                child: Icon(
                  Icons.science_outlined,
                  size: 17,
                  color: c.accentText,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SectionLabel('Advanced')),
            ],
          ),
          if (!_ready)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(),
              ),
            )
          else ...[
            _sectionTitle(c, 'Best time to download'),
            Text(
              _best == null
                  ? _historyCount == 0
                        ? 'No speed tests yet — run a few Full tests at '
                              'different times and this fills in.'
                        : 'Not enough repeat data yet — each 2 h window '
                              'needs 2+ tests.'
                  : bestTimeLabel(_best!),
              style: TextStyle(color: c.textSecondary, fontSize: 12.5),
            ),
            _sectionTitle(c, 'Scheduled diagnostics'),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Daily snapshot',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ),
                Switch(
                  value: _diag.enabled,
                  activeThumbColor: c.accentText,
                  onChanged: (v) async {
                    final next = ScheduledDiag(
                      enabled: v,
                      hour: _diag.hour,
                      autoSpeedTest: _diag.autoSpeedTest,
                      lastRunDay: _diag.lastRunDay,
                    );
                    await next.save();
                    if (mounted) setState(() => _diag = next);
                  },
                ),
              ],
            ),
            if (_diag.enabled) ...[
              PillSwitcher<int>(
                options: [
                  for (final h in _diagHours)
                    PillOption(value: h, label: _hourLabel(h)),
                ],
                selected: _diag.hour,
                onChanged: (h) async {
                  final next = ScheduledDiag(
                    enabled: true,
                    hour: h,
                    autoSpeedTest: _diag.autoSpeedTest,
                    lastRunDay: _diag.lastRunDay,
                  );
                  await next.save();
                  if (mounted) setState(() => _diag = next);
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Include a Quick speed test',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          'Off by default. Uses ~10 MB carrier data.',
                          style: TextStyle(
                            color: c.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _diag.autoSpeedTest,
                    activeThumbColor: c.accentText,
                    onChanged: (v) async {
                      final next = ScheduledDiag(
                        enabled: true,
                        hour: _diag.hour,
                        autoSpeedTest: v,
                        lastRunDay: _diag.lastRunDay,
                      );
                      await next.save();
                      if (mounted) setState(() => _diag = next);
                    },
                  ),
                ],
              ),
            ],
            _sectionTitle(c, 'Scheduled reboot'),
            if (_reboot.armed)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Armed for ${timeAgo(_reboot.at!, allowFuture: true)}',
                      style: TextStyle(
                        color: c.accentText,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _cancelReboot,
                    child: const Text('Cancel'),
                  ),
                ],
              )
            else
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: !widget.connected
                        ? null
                        : () => _scheduleReboot(
                            const Duration(minutes: 30),
                          ),
                    child: const Text('+30m'),
                  ),
                  OutlinedButton(
                    onPressed: !widget.connected
                        ? null
                        : () => _scheduleReboot(const Duration(hours: 1)),
                    child: const Text('+1h'),
                  ),
                  OutlinedButton(
                    onPressed: !widget.connected
                        ? null
                        : () => _scheduleReboot(const Duration(hours: 3)),
                    child: const Text('+3h'),
                  ),
                ],
              ),
            _sectionTitle(c, 'Capability discovery'),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _discovery == null ||
                            _discovery!.at.millisecondsSinceEpoch == 0
                        ? 'One read-only GET maps which status keys this '
                              'firmware answers.'
                        : '${_discovery!.supported.length}/'
                              '${discoveryProbeKeys.length} keys answer '
                              '(${timeAgo(_discovery!.at)})',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: !widget.connected || _busy ? null : _probe,
                  child: Text(_busy ? 'Probing…' : 'Probe'),
                ),
              ],
            ),
            if (_discovery != null && _discovery!.silent.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Silent: ${_discovery!.silent.join(', ')}',
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ],
            _sectionTitle(c, 'Local read-only API'),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'http://127.0.0.1:${_api.port}/snapshot',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        'Loopback only — other apps on this machine, never the LAN.',
                        style: TextStyle(color: c.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _api.enabled,
                  activeThumbColor: c.accentText,
                  onChanged: (v) async {
                    final next = LocalApiSettings(
                      enabled: v,
                      port: _api.port,
                    );
                    await next.save();
                    if (mounted) setState(() => _api = next);
                    widget.onApiChanged?.call();
                    widget.log(
                      'local API ${v ? 'enabled on :${_api.port}' : 'stopped'}',
                    );
                  },
                ),
              ],
            ),
            _sectionTitle(c, 'Backup & restore'),
            Text(
              'Plaintext JSON on your clipboard — includes station names '
              'and history, never the admin password. Encrypted backup '
              'needs a crypto dependency and is not claimed here.',
              style: TextStyle(color: c.textMuted, fontSize: 11.5),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _exportBackup,
                    icon: const Icon(Icons.ios_share, size: 15),
                    label: const Text('Export'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importBackup,
                    icon: const Icon(Icons.restore_outlined, size: 15),
                    label: const Text('Import'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(ZteColors c, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textMuted,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

/// Paste-a-backup dialog body.
class _PasteForm extends StatefulWidget {
  const _PasteForm();

  @override
  State<_PasteForm> createState() => _PasteFormState();
}

class _PasteFormState extends State<_PasteForm> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Paste backup JSON…',
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
