import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';
import 'zte_client.dart';

/// Info tab: device information, traffic statistics + reset, data limit.
class InfoTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;

  const InfoTab(
      {super.key,
      required this.client,
      required this.connected,
      required this.log});

  @override
  State<InfoTab> createState() => _InfoTabState();
}

class _InfoTabState extends State<InfoTab> {
  Map<String, dynamic> _info = {};
  Map<String, dynamic> _stats = {};
  bool _busy = false;

  bool _limitOn = false;
  String _limitUnit = 'data';
  final _sizeCtrl = TextEditingController();
  final _alertCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.connected) _load();
  }

  @override
  void didUpdateWidget(InfoTab old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _load();
  }

  @override
  void dispose() {
    _sizeCtrl.dispose();
    _alertCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final results = await Future.wait([
        widget.client.getDeviceInfo(),
        widget.client.getTrafficStats(),
        widget.client.getDataLimit(),
      ]);
      if (!mounted) return;
      final limit = Map<String, dynamic>.from(results[2] as Map);
      setState(() {
        _info = Map<String, dynamic>.from(results[0] as Map);
        _stats = Map<String, dynamic>.from(results[1] as Map);
        _limitOn = '${limit['data_volume_limit_switch'] ?? ''}' == '1';
        final unit = '${limit['data_volume_limit_unit'] ?? ''}';
        _limitUnit = unit == 'time' ? 'time' : 'data';
        _sizeCtrl.text = '${limit['data_volume_limit_size'] ?? ''}';
        _alertCtrl.text = '${limit['data_volume_alert_percent'] ?? ''}';
      });
      widget.log('device info + stats loaded');
    } catch (e) {
      widget.log('info load failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetCounter() async {
    final confirm = await confirmAction(
      context,
      icon: Icons.restart_alt,
      title: 'Reset data counter?',
      message:
          'Monthly up/down counters return to zero. The carrier bill is unaffected.',
      confirmLabel: 'Reset',
      danger: false,
    );
    if (!confirm) return;
    try {
      final ok = await widget.client.resetDataCounter();
      widget.log(ok ? 'data counter reset' : 'counter reset refused');
    } catch (e) {
      widget.log('counter reset failed: $e');
    }
    _load();
  }

  Future<void> _saveLimit() async {
    try {
      final ok = await widget.client.setDataLimit(
        enabled: _limitOn,
        unit: _limitUnit,
        size: _sizeCtrl.text.trim(),
        alertPercent: _alertCtrl.text.trim(),
      );
      widget.log(ok ? 'data limit saved' : 'data limit refused');
    } catch (e) {
      widget.log('data limit failed: $e');
    }
    _load();
  }

  Widget _row(String label, String value) {
    final c = context.zc;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: TextStyle(color: c.textMuted, fontSize: 12.5)),
          ),
          Expanded(
            child: SelectableText(value.isEmpty ? '—' : value,
                style: TextStyle(color: c.textPrimary, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    if (!widget.connected) {
      return Center(
          child: Text('Log in to see device info.',
              style: TextStyle(color: c.textMuted)));
    }
    final rxMb = ZteClient.bytesToMb(_stats['monthly_rx_bytes']);
    final txMb = ZteClient.bytesToMb(_stats['monthly_tx_bytes']);
    final rrx = double.tryParse('${_stats['realtime_rx_thrpt'] ?? ''}') ?? 0;
    final rtx = double.tryParse('${_stats['realtime_tx_thrpt'] ?? ''}') ?? 0;
    final mtime = int.tryParse('${_stats['monthly_time'] ?? ''}') ?? 0;
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
                    const SectionLabel('Device information'),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _busy ? null : _load,
                      icon: Icon(Icons.refresh,
                          color: c.accentText, size: 20),
                    ),
                  ],
                ),
                _row('Model', 'ZTE MF935 (MTN Broadband 4G MiFi)'),
                _row('IMEI', '${_info['imei'] ?? ''}'),
                _row('IMSI', '${_info['sim_imsi'] ?? ''}'),
                _row('Hardware', '${_info['hardware_version'] ?? ''}'),
                _row('Web UI', '${_info['wa_inner_version'] ?? ''}'),
                _row('Firmware', '${_info['cr_version'] ?? ''}'),
                _row('SSID', '${_info['SSID1'] ?? ''}'),
                _row('LAN IP', '${_info['lan_ipaddr'] ?? ''}'),
                _row('WAN IP', '${_info['wan_ipaddr'] ?? ''}'),
                _row('Link', '${_info['ppp_status'] ?? ''}'),
                _row('Network', '${_info['network_type'] ?? ''}'),
                _row('RSSI / RSRP',
                    '${_info['rssi'] ?? ''} / ${_info['lte_rsrp'] ?? ''} dBm'),
                _row('Max clients', '${_info['MAX_Access_num'] ?? ''}'),
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
                Row(
                  children: [
                    const SectionLabel('Traffic statistics'),
                    const Spacer(),
                    TextButton(
                        onPressed: _busy ? null : _resetCounter,
                        child: const Text('Reset counter')),
                  ],
                ),
                _row('Month down', ZteClient.formatDataVolume(rxMb)),
                _row('Month up', ZteClient.formatDataVolume(txMb)),
                _row('Month total',
                    ZteClient.formatDataVolume(rxMb + txMb)),
                _row('Month online',
                    '${(mtime / 3600).toStringAsFixed(1)} h'),
                _row('Live down', '${(rrx / 1024).toStringAsFixed(1)} KB/s'),
                _row('Live up', '${(rtx / 1024).toStringAsFixed(1)} KB/s'),
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
                const SectionLabel('Data limit'),
                Row(
                  children: [
                    Switch(
                        value: _limitOn,
                        onChanged: (v) =>
                            setState(() => _limitOn = v)),
                    Text('Limit enabled',
                        style: TextStyle(
                            color: c.textSecondary, fontSize: 12.5)),
                    const SizedBox(width: 12),
                    PillSwitcher<String>(
                      options: const [
                        PillOption(
                            value: 'data',
                            label: 'Data',
                            icon: Icons.data_usage_outlined),
                        PillOption(
                            value: 'time',
                            label: 'Time',
                            icon: Icons.schedule_outlined),
                      ],
                      selected: _limitUnit,
                      onChanged: (v) =>
                          setState(() => _limitUnit = v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _sizeCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _limitUnit == 'data'
                              ? 'Size (modem units)'
                              : 'Minutes',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _alertCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Alert %', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _busy ? null : _saveLimit,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
