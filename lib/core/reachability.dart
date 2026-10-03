library;

/// Internet reachability (SSOT): is the problem the modem, the WiFi link
/// to the modem, or the carrier's data path?
///
/// The dashboard can only see the router's own web API, so "the MiFi is
/// unreachable" and "the MiFi is fine but the internet behind it is dead"
/// look identical from the status screen — both are "no data". Users
/// waste hours on that ambiguity, and carriers ask about it first. This
/// module probes *past* the modem, one step at a time:
///
///  1. gateway (the router's own API — already known from polling),
///  2. DNS resolution (proves the modem handed out a working resolver),
///  3. HTTPS to a fixed 204 endpoint (proves real traffic gets out).
///
/// Each rung localises the fault, and [classifyInternet] turns the three
/// booleans into one sentence a human can act on. Classification is pure
/// and tested; the socket work is behind [InternetProbe] so tests and
/// previews never touch the network.
import 'dart:async';
import 'dart:io';

/// Tiny, stable, no-content endpoint used for the HTTPS rung. Google's
/// generate_204 answers with 204 and an empty body, costs no data, and
/// is the same target connectivity checks use everywhere.
const internetProbeUrl = 'https://www.gstatic.com/generate_204';

/// Per-rung timeout. Short on purpose: this probe runs next to the
/// dashboard, and a hung DNS lookup is itself the answer.
const internetProbeTimeout = Duration(seconds: 4);

/// One probe run: which rungs answered, and how long the slow one took.
class ProbeResult {
  final bool gatewayOk;

  /// Did a hostname resolve? False includes "no resolver configured",
  /// which is itself a finding.
  final bool dnsOk;

  /// Did a real HTTPS request complete? False with DNS true points at a
  /// captive portal, a blocked port, or carrier filtering.
  final bool httpsOk;

  /// Round-trip time of the HTTPS rung (null when it never completed).
  final int? httpsMs;

  final DateTime at;

  const ProbeResult({
    required this.gatewayOk,
    required this.dnsOk,
    required this.httpsOk,
    this.httpsMs,
    required this.at,
  });

  InternetVerdict get verdict => classifyInternet(this).verdict;

  /// Headline + detail for the same run (see [classifyInternet]).
  InternetVerdictInfo get info => classifyInternet(this);

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'gateway': gatewayOk,
    'dns': dnsOk,
    'https': httpsOk,
    'ms': httpsMs,
    'verdict': verdict.name,
  };

  factory ProbeResult.fromJson(Map<String, dynamic> j) => ProbeResult(
    gatewayOk: j['gateway'] == true,
    dnsOk: j['dns'] == true,
    httpsOk: j['https'] == true,
    httpsMs: (j['ms'] as num?)?.toInt(),
    at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
  );
}

/// Where the fault is, in the order a user should check it.
enum InternetVerdict {
  /// Everything answered.
  ok,

  /// The router itself is not answering — power, WiFi, or a reboot.
  modemUnreachable,

  /// The router answers but nothing resolves: no SIM data session, or
  /// the carrier's resolver never came up.
  noDns,

  /// Names resolve but traffic does not complete: captive portal,
  /// blocked port, or carrier filtering.
  httpsBlocked,

  /// The modem was unreachable when this probe ran (kept distinct from
  /// "the modem answered but the internet is dead").
  unknown,
}

/// A verdict plus the sentence that explains it.
class InternetVerdictInfo {
  final InternetVerdict verdict;
  final String headline;
  final String detail;

  const InternetVerdictInfo(this.verdict, this.headline, this.detail);
}

/// One-line verdict + what to do about it. Pure + tested.
InternetVerdictInfo classifyInternet(ProbeResult r) {
  if (!r.gatewayOk) {
    return const InternetVerdictInfo(
      InternetVerdict.modemUnreachable,
      'MiFi unreachable',
      'The router is not answering at all. Check power and WiFi before '
          'blaming the SIM.',
    );
  }
  if (r.dnsOk && r.httpsOk) {
    return InternetVerdictInfo(
      InternetVerdict.ok,
      'Internet OK',
      r.httpsMs == null
          ? 'Router, DNS and HTTPS all answered.'
          : 'Router, DNS and HTTPS all answered (${r.httpsMs} ms).',
    );
  }
  if (r.dnsOk) {
    return const InternetVerdictInfo(
      InternetVerdict.httpsBlocked,
      'DNS works, HTTPS does not',
      'The modem hands out working name resolution but real traffic never '
          'completes — typical of a captive portal, a blocked port or '
          'carrier filtering.',
    );
  }
  return const InternetVerdictInfo(
    InternetVerdict.noDns,
    'No DNS — carrier data is not up',
    'The router answers but no name resolves. Usually no data session on '
        'the SIM (no credit, expired plan, or not yet attached).',
  );
}

/// Probe seam: the app runs [IoInternetProbe], tests inject a fake.
abstract class InternetProbe {
  Future<ProbeResult> run({required bool gatewayOk});
}

/// Real socket probe. Two short rungs, never a long hang, and each
/// failure is recorded rather than thrown — a failed DNS lookup is data,
/// not an error.
class IoInternetProbe implements InternetProbe {
  /// Hostname resolved to prove the resolver works.
  final String dnsHost;

  /// Endpoint fetched to prove traffic gets out.
  final Uri url;

  IoInternetProbe({
    this.dnsHost = 'dns.google',
    Uri? url,
  }) : url = url ?? Uri.parse(internetProbeUrl);

  @override
  Future<ProbeResult> run({required bool gatewayOk}) async {
    final at = DateTime.now();
    if (!gatewayOk) {
      return ProbeResult(
        gatewayOk: false,
        dnsOk: false,
        httpsOk: false,
        at: at,
      );
    }
    var dnsOk = false;
    var httpsOk = false;
    int? ms;
    try {
      final lookup = await InternetAddress.lookup(dnsHost).timeout(
        internetProbeTimeout,
      );
      dnsOk = lookup.isNotEmpty && lookup.first.rawAddress.isNotEmpty;
    } catch (_) {
      dnsOk = false;
    }
    if (dnsOk) {
      final sw = Stopwatch()..start();
      try {
        final client = HttpClient()
          ..connectionTimeout = internetProbeTimeout;
        try {
          final req = await client
              .getUrl(url)
              .timeout(internetProbeTimeout);
          req.headers.set(HttpHeaders.userAgentHeader, 'MiFiCompanion/1.0');
          final res = await req.close().timeout(internetProbeTimeout);
          // Any completed exchange proves the path works: 204 is the
          // expected one, but a captive portal's 302 is still an answer
          // (and is why a bare "did we get bytes" test is not enough).
          httpsOk = res.statusCode > 0;
          await res.drain<void>();
        } finally {
          client.close(force: true);
        }
        ms = sw.elapsedMilliseconds;
      } catch (_) {
        httpsOk = false;
      }
    }
    return ProbeResult(
      gatewayOk: true,
      dnsOk: dnsOk,
      httpsOk: httpsOk,
      httpsMs: ms,
      at: at,
    );
  }
}

/// Human label for one rung of the ladder.
String rungLabel(bool ok) => ok ? 'up' : 'down';