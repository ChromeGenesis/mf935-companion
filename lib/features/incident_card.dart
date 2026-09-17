library;

/// Incident-report card (SSOT): one tap gathers firmware, network,
/// signal, session counters, recent speed tests, smart-alert history,
/// device episodes, capability rejections and log into a redacted
/// bundle — text + JSON copy actions plus a carrier-ticket summary.
/// Self-contained: fetches live modem data itself.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/device_store.dart';
import '../core/incident_report.dart';
import '../core/smart_alerts.dart';
import '../core/speed_history.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_client.dart';

class IncidentCard extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final List<String> logLines;
  final Map<String, String> unsupported;
  final void Function(String line) log;

  const IncidentCard({
    super.key,
    required this.client,
    required this.connected,
    required this.logLines,
    required this.unsupported,
    required this.log,
  });

  @override
  State<IncidentCard> createState() => _IncidentCardState();
}

class _IncidentCardState extends State<IncidentCard> {
  bool _busy = false;
  String? _text;
  String? _json;

  Future<void> _build() async {
    if (!widget.connected || _busy) return;
    setState(() {
      _busy = true;
      _text = null;
      _json = null;
    });
    try {
      final results = await (
        widget.client.getStatus(),
        widget.client.getDeviceInfo(),
        widget.client.getTrafficStats(),
        SpeedHistory.load(),
        SmartAlertStore.loadHistory(),
        DeviceStore.load(),
      ).wait;
      final input = IncidentInput(
        appVersion: '1.0.0+1',
        gatewayIp: widget.client.gatewayIp,
        status: results.$1,
        deviceInfo: results.$2,
        traffic: results.$3,
        speedTests: [
          for (final r in results.$4.records) r.toJson(),
        ],
        alerts: [for (final a in results.$5) a.toJson()],
        deviceEvents: [
          for (final e in results.$6.events) e.toJson(),
        ],
        unsupported: widget.unsupported,
        logLines: widget.logLines,
      );
      final text = buildIncidentText(input);
      final json = encodeIncidentJson(buildIncidentJson(input));
      if (!mounted) return;
      setState(() {
        _text = text;
        _json = json;
      });
      widget.log('incident report built (${text.length} chars)');
    } catch (e) {
      widget.log('incident report failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String? value, String what) async {
    if (value == null) return;
    await Clipboard.setData(ClipboardData(text: value));
    widget.log('incident report $what copied (${value.length} chars)');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Incident report ($what) copied')),
      );
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
                  Icons.medical_information_outlined,
                  size: 17,
                  color: c.accentText,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SectionLabel('Incident report')),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                onPressed: !widget.connected || _busy ? null : _build,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.build_outlined, size: 15),
                label: Text(_busy ? 'Building…' : 'Create'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Redacted by construction: no passwords, cookies, message '
            'bodies, IMEI/IMSI — MACs truncated. Safe to paste into a '
            'carrier ticket.',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
          if (_text != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.chip,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.borderSubtle),
              ),
              child: SelectableText(
                _text!.split('\n').first,
                style: TextStyle(color: c.textPrimary, fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(_text, 'text'),
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('Copy text'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(_json, 'JSON'),
                    icon: const Icon(Icons.data_object, size: 15),
                    label: const Text('Copy JSON'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
