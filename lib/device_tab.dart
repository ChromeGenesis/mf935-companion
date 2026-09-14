import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';
import 'zte_client.dart';

/// Device tab: power-save, reboot/shutdown (confirmed), connected clients.
class DeviceTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;

  const DeviceTab(
      {super.key,
      required this.client,
      required this.connected,
      required this.log});

  @override
  State<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<DeviceTab> {
  List<AttachedDevice> _devices = [];
  String _powerSave = '';
  final _powerCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.connected) _load();
  }

  @override
  void didUpdateWidget(DeviceTab old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _load();
  }

  @override
  void dispose() {
    _powerCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final results = await Future.wait([
        widget.client.getConnectedDevices(),
        widget.client.getPowerSave(),
      ]);
      if (!mounted) return;
      setState(() {
        _devices = results[0] as List<AttachedDevice>;
        _powerSave = results[1] as String;
        _powerCtrl.text = _powerSave;
      });
      widget.log('devices: ${_devices.length}, power-save="$_powerSave"');
    } catch (e) {
      widget.log('device tab load failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPowerSave() async {
    try {
      final ok =
          await widget.client.setPowerSave(_powerCtrl.text.trim());
      widget.log(ok ? 'power-save saved' : 'power-save refused');
    } catch (e) {
      widget.log('power-save failed: $e');
    }
    _load();
  }

  Future<void> _powerAction(String kind) async {
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
    final c = context.zc;
    if (!widget.connected) {
      return Center(
          child: Text('Log in to manage the device.',
              style: TextStyle(color: c.textMuted)));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SectionLabel('Connected devices'),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _busy ? null : _load,
                      icon: Icon(Icons.refresh,
                          color: c.accentText, size: 20),
                    ),
                  ],
                ),
                if (_busy && _devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                        child: Text('No stations reported.',
                            style: TextStyle(color: c.textMuted))),
                  )
                else
                  ..._devices.map((d) => Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(Icons.devices_outlined,
                                size: 16, color: c.accentText),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(d.hostname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: c.textPrimary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                            ),
                            Text(d.ip,
                                style: TextStyle(
                                    color: c.textSecondary,
                                    fontSize: 12)),
                            const SizedBox(width: 10),
                            Text(d.mac,
                                style: TextStyle(
                                    color: c.textMuted, fontSize: 11)),
                          ],
                        ),
                      )),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SectionLabel('Power save'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _powerCtrl,
                        decoration: InputDecoration(
                          labelText: 'auto_power_save (current: '
                              '${_powerSave.isEmpty ? '—' : _powerSave})',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _applyPowerSave(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _busy ? null : _applyPowerSave,
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _powerAction('reboot'),
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('Reboot MiFi'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _powerAction('shutdown'),
                    icon: Icon(Icons.power_settings_new,
                        size: 16, color: c.danger),
                    label: Text('Shut down',
                        style: TextStyle(color: c.danger)),
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
