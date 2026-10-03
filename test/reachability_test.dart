import 'package:flutter_test/flutter_test.dart';
import 'package:zte_mf935_app/core/reachability.dart';

ProbeResult probe({
  bool gateway = true,
  bool dns = true,
  bool https = true,
  int? ms = 42,
}) => ProbeResult(
  gatewayOk: gateway,
  dnsOk: dns,
  httpsOk: https,
  httpsMs: ms,
  at: DateTime(2026, 1, 2),
);

void main() {
  test('Reachability verdict names the failing rung, not just "offline"', () {
    // All up.
    final ok = classifyInternet(probe());
    expect(ok.verdict, InternetVerdict.ok);
    expect(ok.headline, contains('OK'));
    expect(ok.detail, contains('42 ms'));

    // Router dead: everything else is untested, not "down".
    final dead = classifyInternet(probe(gateway: false, dns: false, https: false));
    expect(dead.verdict, InternetVerdict.modemUnreachable);
    expect(dead.detail, contains('power and WiFi'));

    // Router fine, DNS dead -> carrier data is not up.
    final noDns = classifyInternet(probe(dns: false, https: false, ms: null));
    expect(noDns.verdict, InternetVerdict.noDns);
    expect(noDns.headline, contains('carrier data'));

    // DNS fine, HTTPS blocked -> captive portal / filtering, NOT a modem
    // problem. This distinction is the whole point of the probe.
    final blocked = classifyInternet(probe(https: false, ms: null));
    expect(blocked.verdict, InternetVerdict.httpsBlocked);
    expect(blocked.detail, contains('captive portal'));
  });

  test('Probe result JSON round-trips its verdict', () {
    final r = probe(https: false, ms: null);
    final back = ProbeResult.fromJson(r.toJson());
    expect(back.dnsOk, r.dnsOk);
    expect(back.httpsOk, r.httpsOk);
    expect(back.verdict, InternetVerdict.httpsBlocked);
    expect(rungLabel(true), 'up');
  });

  test('Unreachable gateway short-circuits without touching sockets', () async {
    // A probe pointed at a dead gateway must not attempt DNS/HTTPS.
    final result = await IoInternetProbe().run(gatewayOk: false);
    expect(result.dnsOk, isFalse);
    expect(result.httpsOk, isFalse);
    expect(result.verdict, InternetVerdict.modemUnreachable);
  });
}