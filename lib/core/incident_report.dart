library;

/// Phase 8 Incident Reports (SSOT): one-tap evidence bundle for
/// carrier tickets and debugging — firmware, network, signal,
/// session counters, recent speed tests, smart-alert history, device
/// episodes, capability rejections, recent log.
///
/// Redaction (roadmap): passwords/cookies/message bodies are never
/// collected in the first place; IMEI/IMSI/MSISDN/ICCID keys are
/// dropped; MACs are truncated to their last 4 hex chars (enough to
/// correlate, not enough to identify). Pure Dart, unit-tested.
import 'dart:convert';

/// Status/device-info keys that must never appear in a report.
const _droppedKeys = <String>{
  'imei',
  'sim_imsi',
  'imsi',
  'iccid',
  'ussd_msisdn',
  'msisdn',
  'phone',
  'password',
  'passwd',
  'pwd',
  'cookie',
  'auth',
  'LD',
  'RD',
};

/// Scrub one snapshot map: drop sensitive keys (case-insensitive).
/// Pure + tested.
Map<String, String> scrubSnapshot(Map<String, dynamic> src) {
  final out = <String, String>{};
  for (final e in src.entries) {
    if (_droppedKeys.contains(e.key.toLowerCase())) continue;
    out[e.key] = '${e.value}';
  }
  return out;
}

/// Truncate a MAC to its last 4 hex chars (`…A1B2`). Pure + tested.
String maskMac(String mac) {
  final hex = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (hex.length < 4) return '…????';
  return '…${hex.substring(hex.length - 4).toUpperCase()}';
}

/// Everything a report is built from. All maps are raw modem replies;
/// scrubbing happens inside the builders.
class IncidentInput {
  final String appVersion;
  final String gatewayIp;
  final Map<String, dynamic> status;
  final Map<String, dynamic> deviceInfo;
  final Map<String, dynamic> traffic;
  final List<Map<String, dynamic>> speedTests; // SpeedRecord JSON, newest first
  final List<Map<String, dynamic>> alerts; // SmartAlert JSON, newest first
  final List<Map<String, dynamic>> deviceEvents; // DeviceEvent JSON
  final Map<String, String> unsupported;
  final List<String> logLines;

  const IncidentInput({
    required this.appVersion,
    required this.gatewayIp,
    this.status = const {},
    this.deviceInfo = const {},
    this.traffic = const {},
    this.speedTests = const [],
    this.alerts = const [],
    this.deviceEvents = const [],
    this.unsupported = const {},
    this.logLines = const [],
  });
}

/// Short human summary for a carrier ticket: signal, network,
/// battery, last speed, recent trouble. Never claims more than the
/// data supports. Pure + tested.
String buildIncidentSummary(IncidentInput input, {DateTime? now}) {
  final t = (now ?? DateTime.now()).toIso8601String().substring(0, 16);
  final s = input.status;
  final bars = '${s['signalbar'] ?? '?'}';
  final net = '${s['network_type'] ?? 'unknown network'}';
  final prov = '${s['network_provider'] ?? 'carrier'}';
  final batt = '${s['battery_vol_percent'] ?? '?'}';
  final last = input.speedTests.isNotEmpty ? input.speedTests.first : null;
  final speed = last == null
      ? 'no recent speed test'
      : 'last test ${last['downMbps'] ?? '?'} Mbps down / '
            '${last['upMbps'] ?? '?'} Mbps up '
            '(${last['latencyMs'] ?? '?'} ms)';
  final trouble = input.alerts.isEmpty
      ? 'no smart alerts fired recently'
      : '${input.alerts.length} recent alert(s), latest: '
          '${input.alerts.first['title'] ?? 'unknown'}';
  return 'MiFi issue reported $t. Signal $bars/5 on $net ($prov), '
      'battery $batt%. $speed. $trouble. Full evidence attached below.';
}

/// Full plain-text report. Pure + tested (redaction assertions).
String buildIncidentText(IncidentInput input, {DateTime? now}) {
  final t = (now ?? DateTime.now()).toIso8601String();
  final buf = StringBuffer()
    ..writeln(buildIncidentSummary(input, now: now))
    ..writeln()
    ..writeln('=== incident report ===')
    ..writeln('exported_at: $t')
    ..writeln('app_version: ${input.appVersion}')
    ..writeln('gateway: ${input.gatewayIp}');
  final fw = scrubSnapshot(input.deviceInfo);
  buf.writeln(
    'firmware: wa_inner_version=${fw['wa_inner_version'] ?? 'n/a'} '
    'cr_version=${fw['cr_version'] ?? 'n/a'} '
    'hardware=${fw['hardware_version'] ?? 'n/a'} '
    'web=${fw['web_version'] ?? 'n/a'}',
  );
  final st = scrubSnapshot(input.status);
  buf.writeln(
    'network: type=${st['network_type'] ?? 'n/a'} '
    'provider=${st['network_provider'] ?? 'n/a'} '
    'signalbar=${st['signalbar'] ?? 'n/a'} '
    'rssi=${st['rssi'] ?? 'n/a'} rscp=${st['rscp'] ?? 'n/a'} '
    'lte_rsrp=${st['lte_rsrp'] ?? 'n/a'}',
  );
  buf.writeln(
    'battery: ${st['battery_vol_percent'] ?? 'n/a'}% '
    'charging=${st['battery_charging'] ?? 'n/a'}',
  );
  final tr = scrubSnapshot(input.traffic);
  buf.writeln(
    'session: realtime=${tr['realtime_time'] ?? 'n/a'}s '
    'rx=${tr['realtime_rx_bytes'] ?? 'n/a'}B '
    'tx=${tr['realtime_tx_bytes'] ?? 'n/a'}B '
    'month_rx=${tr['monthly_rx_bytes'] ?? 'n/a'}B '
    'month_tx=${tr['monthly_tx_bytes'] ?? 'n/a'}B',
  );
  buf.writeln('recent_speed_tests (${input.speedTests.length}):');
  for (final r in input.speedTests.take(10)) {
    buf.writeln(
      '  - ${r['at'] ?? '?'}: ${r['downMbps'] ?? '?'} down / '
      '${r['upMbps'] ?? '?'} up Mbps, ${r['latencyMs'] ?? '?'} ms '
      'via ${r['server'] ?? '?'}',
    );
  }
  buf.writeln('recent_alerts (${input.alerts.length}):');
  for (final a in input.alerts.take(10)) {
    buf.writeln('  - ${a['at'] ?? '?'} [${a['title'] ?? '?'}] ${a['body'] ?? ''}');
  }
  buf.writeln('device_episodes (${input.deviceEvents.length}):');
  for (final e in input.deviceEvents.take(10)) {
    final mac = maskMac('${e['mac'] ?? ''}');
    buf.writeln(
      '  - ${e['at'] ?? '?'} ${e['joined'] == true ? 'joined' : 'left'} '
      '${e['name'] ?? '?'} ($mac)',
    );
  }
  if (input.unsupported.isEmpty) {
    buf.writeln('unsupported_commands: none recorded');
  } else {
    buf.writeln('unsupported_commands:');
    for (final e in input.unsupported.entries) {
      buf.writeln('  - ${e.key}: ${e.value}');
    }
  }
  final tail = input.logLines.length > 40
      ? input.logLines.sublist(input.logLines.length - 40)
      : input.logLines;
  buf.writeln('recent_log (${tail.length}):');
  for (final line in tail) {
    buf.writeln('  $line');
  }
  return buf.toString();
}

/// JSON twin for issue trackers. MACs masked, sensitive keys dropped.
/// Pure + tested.
Map<String, dynamic> buildIncidentJson(IncidentInput input, {DateTime? now}) {
  final tail = input.logLines.length > 40
      ? input.logLines.sublist(input.logLines.length - 40)
      : List<String>.from(input.logLines);
  return {
    'app': 'MiFi Companion',
    'app_version': input.appVersion,
    'exported_at': (now ?? DateTime.now()).toIso8601String(),
    'gateway_ip': input.gatewayIp,
    'summary': buildIncidentSummary(input, now: now),
    'firmware': scrubSnapshot(input.deviceInfo),
    'network': scrubSnapshot(input.status),
    'traffic': scrubSnapshot(input.traffic),
    'recent_speed_tests': input.speedTests.take(10).toList(),
    'recent_alerts': input.alerts.take(10).toList(),
    'device_episodes': [
      for (final e in input.deviceEvents.take(10))
        {...Map<String, dynamic>.from(e), 'mac': maskMac('${e['mac'] ?? ''}')},
    ],
    'unsupported_commands': Map<String, String>.from(input.unsupported),
    'recent_log': tail,
  };
}

/// JSON-encode helper for the copy-JSON action.
String encodeIncidentJson(Map<String, dynamic> j) =>
    const JsonEncoder.withIndent('  ').convert(j);
