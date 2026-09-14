import 'package:flutter_test/flutter_test.dart';

import 'package:zte_mf935_app/core/capability.dart';
import 'package:zte_mf935_app/core/diagnostics.dart';

void main() {
  test('CapabilityRegistry latches once, never spams', () {
    final r = CapabilityRegistry();
    expect(r.isUnsupported('USSD_PROCESS'), isFalse);
    expect(r.markUnsupported('USSD_PROCESS', 'flag=99'), isTrue);
    expect(r.isUnsupported('USSD_PROCESS'), isTrue);
    expect(r.reasonFor('USSD_PROCESS'), 'flag=99');
    // Second mark is a no-op (caller skips log/notify).
    expect(r.markUnsupported('USSD_PROCESS', 'flag=99'), isFalse);
  });

  test('Known table marks firmware-dependent commands', () {
    expect(
      knownCommands['USSD_PROCESS']!.kind,
      CapabilityKind.firmwareDependent,
    );
    expect(
      knownCommands['SET_AUTO_POWER_SAVE']!.kind,
      CapabilityKind.firmwareDependent,
    );
    expect(knownCommands['SEND_SMS']!.kind, CapabilityKind.writable);
  });

  test('formatCommandFailure names result, command and next action', () {
    final msg = formatCommandFailure(
      command: 'SET_AUTO_POWER_SAVE',
      result: 'error',
    );
    expect(msg, contains('SET_AUTO_POWER_SAVE'));
    expect(msg, contains('result=error'));
    expect(msg, contains('Next:'));
  });

  test('Diagnostic export carries version, firmware, unsupported, log', () {
    final text = buildDiagnosticText(
      appVersion: '1.0.0+1',
      gatewayIp: '192.168.0.1',
      firmware: {'wa_inner_version': 'W1', 'cr_version': 'C1'},
      status: {
        'signalbar': '4',
        'network_type': 'LTE',
        'network_provider': '62130',
        'battery_vol_percent': '80',
        'battery_charging': '0',
      },
      recentLog: ['a', 'b'],
      unsupported: {'USSD_PROCESS': 'flag=99'},
    );
    expect(text, contains('1.0.0+1'));
    expect(text, contains('W1'));
    expect(text, contains('USSD_PROCESS'));
    expect(text, contains('recent_events'));

    final json = buildDiagnosticJson(
      appVersion: '1.0.0+1',
      gatewayIp: '192.168.0.1',
      firmware: {},
      status: {},
      recentLog: List.generate(50, (i) => 'line $i'),
      unsupported: {},
    );
    // Capped at 40 lines.
    expect((json['recent_events'] as List).length, 40);
  });
}
