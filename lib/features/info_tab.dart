import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

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
  DateTime? _updatedAt;

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

  Future<void> _load() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final results = await Future.wait([
        widget.client.getDeviceInfo(),
        widget.client.getTrafficStats(),
      ]);
      if (!mounted) return;
      setState(() {
        _info = Map<String, dynamic>.from(results[0] as Map);
        _stats = Map<String, dynamic>.from(results[1] as Map);
        _updatedAt = DateTime.now();
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

  /// dBm → 0..5 bars + plain-English quality. -1 when unknown.
  (int, String) _signalQuality() {
    final rssi = int.tryParse('${_info['rssi'] ?? ''}');
    if (rssi == null) return (-1, 'unknown');
    if (rssi >= -70) return (5, 'Excellent');
    if (rssi >= -80) return (4, 'Good');
    if (rssi >= -90) return (3, 'Fair');
    if (rssi >= -100) return (2, 'Weak');
    return (1, 'Barely there');
  }

  Widget _miniStat(ZteColors c, String value, String caption) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(70),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 1),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _liveRow(ZteColors c, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c.live, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: c.textMuted, fontSize: 12.5)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {IconData? icon, Color? valueColor}) {
    final c = context.zc;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: icon == null
                ? const SizedBox.shrink()
                : Icon(icon, size: 16, color: c.textMuted),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: Text(label,
                style: TextStyle(color: c.textMuted, fontSize: 12.5)),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                color: valueColor ?? c.textPrimary,
                fontSize: 12.5,
                fontWeight: valueColor != null ? FontWeight.w700 : null,
              ),
            ),
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
    final (bars, quality) = _signalQuality();

    final deviceCard = GlassCard(
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
                icon: Icon(Icons.refresh, color: c.accentText, size: 20),
              ),
            ],
          ),
          _row('Model', 'ZTE MF935 (MTN Broadband 4G MiFi)',
              icon: Icons.memory_outlined),
          _row('IMEI', '${_info['imei'] ?? ''}', icon: Icons.fingerprint),
          _row('IMSI', '${_info['sim_imsi'] ?? ''}', icon: Icons.sim_card_outlined),
          _row('Hardware', '${_info['hardware_version'] ?? ''}',
              icon: Icons.developer_board_outlined),
          _row('Web UI', '${_info['wa_inner_version'] ?? ''}',
              icon: Icons.web_outlined),
          _row('Firmware', '${_info['cr_version'] ?? ''}',
              icon: Icons.cable_outlined),
          _row('SSID', '${_info['SSID1'] ?? ''}', icon: Icons.wifi),
          _row('LAN IP', '${_info['lan_ipaddr'] ?? ''}',
              icon: Icons.router_outlined),
          _row('WAN IP', '${_info['wan_ipaddr'] ?? ''}',
              icon: Icons.public_outlined),
          _row('Link', '${_info['ppp_status'] ?? ''}', icon: Icons.link),
          _row('Network', '${_info['network_type'] ?? ''}',
              icon: Icons.network_cell_outlined),
          _row('RSSI / RSRP',
              '${_info['rssi'] ?? ''} / ${_info['lte_rsrp'] ?? ''} dBm',
              icon: Icons.signal_cellular_alt,
              valueColor: bars >= 3 ? c.live : c.accentText),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 18, height: 18),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: Text('Signal',
                      style: TextStyle(color: c.textMuted, fontSize: 12.5)),
                ),
                SignalBars(level: bars, height: 16),
                const SizedBox(width: 8),
                Text(
                  quality,
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ],
            ),
          ),
          _row('Max clients', '${_info['MAX_Access_num'] ?? ''}',
              icon: Icons.language_outlined),
        ],
      ),
    );

    final trafficCard = GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SectionLabel('Traffic statistics'),
              const Spacer(),
              if (_updatedAt != null)
                Text(
                  'refreshed ${ZteClient.timeAgo(_updatedAt!)}',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: _busy ? null : _resetCounter,
                  child: const Text('Reset counter')),
            ],
          ),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 2.7,
            children: [
              _miniStat(c, ZteClient.formatDataVolume(rxMb), 'month down'),
              _miniStat(c, ZteClient.formatDataVolume(txMb), 'month up'),
              _miniStat(
                  c, ZteClient.formatDataVolume(rxMb + txMb), 'month total'),
              _miniStat(c, '${(mtime / 3600).toStringAsFixed(1)} h',
                  'month online'),
            ],
          ),
          const SizedBox(height: 8),
          _liveRow(c, 'Live down', ZteClient.formatRate(rrx)),
          _liveRow(c, 'Live up', ZteClient.formatRate(rtx)),
          const SizedBox(height: 8),
          _liveRow(c, 'Live total', ZteClient.formatRate(rrx + rtx)),
          _liveRow(c, 'Daily average down',
              "${(rxMb / (DateTime.now().day)).toStringAsFixed(1)} MB"),
        ],
      ),
    );

    // Two columns when the tab earns the width, stacked on narrow.
    // Stretch-to-bottom uses the ConstrainedBox(minHeight) + IntrinsicHeight
    // pattern so both cards share equal height on desktop.
    return LayoutBuilder(
      builder: (_, cons) {
        if (cons.maxWidth <= 720) {
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                deviceCard,
                const SizedBox(height: 10),
                trafficCard,
              ],
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: cons.maxHeight - 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 11, child: deviceCard),
                  const SizedBox(width: 10),
                  Expanded(flex: 10, child: trafficCard),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
