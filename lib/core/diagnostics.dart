library;

import 'capability.dart';

/// Phase 0: lightweight diagnostic export (SSOT). Pure Dart so it is
/// unit-testable. Callers pass the app log + status snapshot; passwords,
/// cookies, SMS bodies and device identifiers are never included.
String buildDiagnosticText({
  required String appVersion,
  required String gatewayIp,
  required Map<String, dynamic> firmware,
  required Map<String, dynamic> status,
  required List<String> recentLog,
  required Map<String, String> unsupported,
  DateTime? now,
}) {
  final t = (now ?? DateTime.now()).toIso8601String();
  final buf = StringBuffer()
    ..writeln('MiFi Companion diagnostic export')
    ..writeln('exported_at: $t')
    ..writeln('app_version: $appVersion')
    ..writeln('gateway_ip: $gatewayIp')
    ..writeln(
      'firmware: wa_inner_version=${firmware['wa_inner_version'] ?? 'n/a'} '
      'cr_version=${firmware['cr_version'] ?? 'n/a'}',
    )
    ..writeln(
      'signal: signalbar=${status['signalbar'] ?? 'n/a'} '
      'network_type=${status['network_type'] ?? 'n/a'} '
      'provider=${status['network_provider'] ?? 'n/a'}',
    )
    ..writeln(
      'battery: ${status['battery_vol_percent'] ?? 'n/a'}% '
      'charging=${status['battery_charging'] ?? 'n/a'}',
    );
  if (unsupported.isEmpty) {
    buf.writeln('unsupported_commands: none recorded');
  } else {
    buf.writeln('unsupported_commands:');
    for (final e in unsupported.entries) {
      buf.writeln('  - ${e.key}: ${e.value}');
    }
  }
  buf.writeln('recent_events (last ${recentLog.length}):');
  final tail = recentLog.length > 40
      ? recentLog.sublist(recentLog.length - 40)
      : recentLog;
  for (final line in tail) {
    buf.writeln('  $line');
  }
  return buf.toString();
}

/// JSON twin of [buildDiagnosticText] for issue reports / copy-paste.
Map<String, dynamic> buildDiagnosticJson({
  required String appVersion,
  required String gatewayIp,
  required Map<String, dynamic> firmware,
  required Map<String, dynamic> status,
  required List<String> recentLog,
  required Map<String, String> unsupported,
  DateTime? now,
}) {
  final tail = recentLog.length > 40
      ? recentLog.sublist(recentLog.length - 40)
      : List<String>.from(recentLog);
  return {
    'app': 'MiFi Companion',
    'app_version': appVersion,
    'exported_at': (now ?? DateTime.now()).toIso8601String(),
    'gateway_ip': gatewayIp,
    'firmware': {
      'wa_inner_version': '${firmware['wa_inner_version'] ?? ''}',
      'cr_version': '${firmware['cr_version'] ?? ''}',
    },
    'signal': {
      'signalbar': '${status['signalbar'] ?? ''}',
      'network_type': '${status['network_type'] ?? ''}',
      'network_provider': '${status['network_provider'] ?? ''}',
    },
    'battery': {
      'vol_percent': '${status['battery_vol_percent'] ?? ''}',
      'charging': '${status['battery_charging'] ?? ''}',
    },
    'unsupported_commands': Map<String, String>.from(unsupported),
    'recent_events': tail,
  };
}

/// Known firmware-dependent ids for the capability matrix UI.
List<String> firmwareDependentIds() => knownCommands.entries
    .where((e) => e.value.kind == CapabilityKind.firmwareDependent)
    .map((e) => e.key)
    .toList();
