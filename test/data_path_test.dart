import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zte_mf935_app/core/reachability.dart';
import 'package:zte_mf935_app/core/theme.dart';
import 'package:zte_mf935_app/features/internet_check_card.dart';

class _FakeProbe implements InternetProbe {
  int runs = 0;

  @override
  Future<ProbeResult> run({required bool gatewayOk}) async {
    runs++;
    return ProbeResult(
      gatewayOk: gatewayOk,
      dnsOk: true,
      httpsOk: true,
      at: DateTime(2026, 1, 1),
    );
  }
}

Future<void> _pumpCard(
  WidgetTester tester,
  _FakeProbe probe, {
  required bool balanceBusy,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildZteTheme(brightness: Brightness.dark),
      home: Scaffold(
        body: InternetCheckCard(
          connected: true,
          probe: probe,
          log: (_) {},
          balanceBusy: balanceBusy,
        ),
      ),
    ),
  );
}

void main() {
  group('Data path vs balance contention', () {
    testWidgets('probe waits for the balance op, then fires once',
        (tester) async {
      final probe = _FakeProbe();
      await _pumpCard(tester, probe, balanceBusy: true);
      await tester.pump();
      expect(probe.runs, 0);

      // Balance clears → the queued probe fires exactly once.
      await _pumpCard(tester, probe, balanceBusy: false);
      await tester.pumpAndSettle();
      expect(probe.runs, 1);
    });

    testWidgets('no contention: probes immediately', (tester) async {
      final probe = _FakeProbe();
      await _pumpCard(tester, probe, balanceBusy: false);
      await tester.pumpAndSettle();
      expect(probe.runs, 1);
    });

    testWidgets('manual tap while busy queues instead of racing',
        (tester) async {
      final probe = _FakeProbe();
      await _pumpCard(tester, probe, balanceBusy: true);
      await tester.pump();
      expect(probe.runs, 0);
      await tester.tap(find.byKey(const Key('data-path-test')));
      await tester.pump();
      await tester.pump();
      expect(probe.runs, 0);

      // Balance clears → the queued tap fires exactly once.
      await _pumpCard(tester, probe, balanceBusy: false);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(probe.runs, 1);
    });
  });
}
