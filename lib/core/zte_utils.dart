library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// Pure protocol / parsing / formatting helpers for the MF935 companion.
///
/// Extracted verbatim from the former `ZteClient` static methods: no Dio,
/// no Flutter, fully unit-tested. `ZteClient` keeps thin static forwarders
/// with identical signatures so existing call sites and tests keep working.

/// Nested hash from the ZTE web UI (service.js login() + util.js
/// `paswordAlgorithmsCookie`, verified against the live firmware):
/// `SHA256( UPPER(SHA256(password)) + LD )`, UPPERCASE hex throughout —
/// the JS SHA256 stringifier uses the upper lookup table (`r=1`).
/// Proven with a live `{"result":"0"}` on this exact device.
String generateAuthHash(String password, String ld) {
  final first = sha256.convert(utf8.encode(password)).toString().toUpperCase();
  return sha256.convert(utf8.encode(first + ld)).toString().toUpperCase();
}

/// Map a numeric PLMN (MCCMNC, e.g. "62120") to a carrier name.
/// Non-numeric provider strings pass through untouched.
String carrierName(String provider) {
  const carriers = {
    '62120': 'Airtel NG',
    '62130': 'MTN NG',
    '62150': 'Glo NG',
    '62160': '9mobile NG',
  };
  final name = carriers[provider.trim()];
  if (name != null) return name;
  if (RegExp(r'^\d{5,6}$').hasMatch(provider.trim())) {
    return 'PLMN ${provider.trim()}';
  }
  return provider;
}

/// Normalize a USSD code: strip spaces, ensure it starts with '*'
/// and ends with '#'. Every network USSD code has that shape.
String normalizeUssd(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\s+'), '');
  if (!s.startsWith('*')) s = '*$s';
  if (!s.endsWith('#')) s = '$s#';
  return s;
}

/// Plausible USSD: *...# with at least one digit, digits/* only inside.
bool isValidUssd(String code) =>
    RegExp(r'^\*[0-9*]+#$').hasMatch(code.trim());

/// Human label for a terminal ussd_write_flag value (stock service.js).
String ussdFlagLabel(String flag) {
  switch (flag) {
    case '1':
      return 'No service (ussd_no_service).';
    case '2':
      return 'Network terminated the session.';
    case '3':
    case '4':
      return 'USSD timed out — try again.';
    case '10':
      return 'USSD retry — try again.';
    case '41':
      return 'Operation not supported.';
    case '99':
      return 'USSD not supported on this network.';
    default:
      return 'USSD failed (flag=$flag).';
  }
}

/// Balance USSD per carrier: MTN answers data balance on *323*4#
/// while Airtel (and unknown carriers) use *323*1#. Distinguishing the
/// two avoids sending MTN users down Airtel's menu tree.
String balanceUssdForProvider(String provider) {
  final p = provider.trim().toLowerCase();
  if (p.contains('mtn') || p == '62130' || p.contains('62130')) {
    return '*323*4#';
  }
  return '*323*1#';
}

/// Priority layers (never blank — quota is guaranteed):
/// 1. Structured bundles: `Name: 2.5GB till/expires <date>`.
/// 2. No structure? Sum every `<amount> UNIT` in the reply as "Data
///    left" (balance texts list remaining quotas, not usage).
/// 3. No amounts at all? Empty bundles — the card then shows the raw
///    reply so the user still sees the answer.
/// Expiry attaches per-bundle when named, else the first date found
/// anywhere in the reply (best-effort, always verifiable in raw).
DataBalance resolveDataBalance(String raw, DateTime fetchedAt) {
  final structured = sortBundles(parseDataBundles(raw));
  if (structured.isNotEmpty) {
    final looseDate = structured.any((b) => b.expiry != null)
        ? null
        : scanModemDate(raw);
    final bundles = looseDate == null
        ? structured
        : structured
              .map(
                (b) => b.expiry != null
                    ? b
                    : DataBundle(name: b.name, mb: b.mb, expiry: looseDate),
              )
              .toList();
    return DataBalance(bundles: bundles, raw: raw, fetchedAt: fetchedAt);
  }
  final amounts = extractDataAmounts(raw);
  if (amounts.isNotEmpty) {
    return DataBalance(
      bundles: sortBundles([
        DataBundle(
          name: 'Data left',
          mb: amounts.fold(0.0, (a, b) => a + b),
          expiry: scanModemDate(raw),
        ),
      ]),
      raw: raw,
      fetchedAt: fetchedAt,
    );
  }
  return DataBalance(bundles: const [], raw: raw, fetchedAt: fetchedAt);
}

/// Display order: live bundles by soonest expiry first, dateless live
/// next, exhausted last. Deterministic everywhere (SSOT).
List<DataBundle> sortBundles(List<DataBundle> bundles) {
  int rank(DataBundle b) {
    if (b.exhausted) return 2;
    if (b.expiry == null) return 1;
    return 0;
  }

  bundles.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    if (a.expiry != null && b.expiry != null) {
      return a.expiry!.compareTo(b.expiry!);
    }
    return b.mb.compareTo(a.mb);
  });
  return bundles;
}

/// Plan window in days inferred from the bundle name. Drives the
/// dashboard countdown pill only — never displayed as fact, the exact
/// countdown is.
int expiryWindowDays(String name) {
  final n = name.toLowerCase();
  if (n.contains('daily')) return 1;
  if (n.contains('weekly')) return 7;
  if (n.contains('monthly')) return 30;
  if (n.contains('yearly') || n.contains('annual')) return 365;
  return 30;
}

/// Every `<amount> KB|MB|GB` in free text, converted to MB.
List<double> extractDataAmounts(String text) {
  final re = RegExp(r'([\d.]+)\s*(KB|MB|GB)\b', caseSensitive: false);
  return re.allMatches(text).map((m) {
    final amount = double.tryParse(m.group(1) ?? '') ?? 0;
    switch ((m.group(2) ?? 'MB').toUpperCase()) {
      case 'GB':
        return amount * 1024;
      case 'KB':
        return amount / 1024;
      default:
        return amount;
    }
  }).toList();
}

/// First modem date ("dd-MM-yyyy [HH:mm:ss]" or slashes) in free text.
DateTime? scanModemDate(String text) {
  final re = RegExp(r'(\d{2}[-/]\d{2}[-/]\d{4}(?:\s+\d{2}:\d{2}:\d{2})?)');
  final m = re.firstMatch(text);
  return m == null ? null : parseModemDate(m.group(1));
}

/// Parse a balance reply into bundles. Handles both carrier shapes:
/// - Airtel: "Weekly Bundle: 29990.35MB till 28-09-2026 02:09:12"
/// - MTN:    "Daily: 20.59MB @N1.0/MB expires 14/09/2026"
/// Menu prompts without an amount ("YouTube Night:*n Next",
/// "InstaTop: NO.", point balances without units) are skipped.
List<DataBundle> parseDataBundles(String text) {
  final out = <DataBundle>[];
  // Alternation (skip-till-date | nothing): a bare optional group would
  // let the lazy skip match empty and succeed without the date, so the
  // date branch is attempted FIRST and must match whole or fail.
  final re = RegExp(
    r'([^:*#,\n]+?)\s*:\s*([\d.]+)\s*(KB|MB|GB)\b(?:[^\n,]*?(?:till|expires?)\s*(\d{2}[-/]\d{2}[-/]\d{4}(?:\s+\d{2}:\d{2}:\d{2})?)|)',
    caseSensitive: false,
  );
  for (final m in re.allMatches(text)) {
    final amount = double.tryParse(m.group(2) ?? '') ?? 0;
    final unit = (m.group(3) ?? 'MB').toUpperCase();
    final mb = unit == 'GB'
        ? amount * 1024
        : unit == 'KB'
        ? amount / 1024
        : amount;
    // Carriers append "(Expired)" after the amount for dead allocations
    // (e.g. "YouTube Night: 1973.04MB (Expired)") — keep the row for
    // transparency but exclude it from active totals.
    final tailEnd = (m.end + 12).clamp(0, text.length);
    final tail = text.substring(m.end, tailEnd).toLowerCase();
    final carrierExpired = tail.contains('(expired)');
    out.add(
      DataBundle(
        name: (m.group(1) ?? '').trim(),
        mb: mb,
        expiry: parseModemDate(m.group(4)),
        carrierExpired: carrierExpired,
      ),
    );
  }
  return out;
}

/// "28-09-2026 02:09:12" / "14/09/2026" -> DateTime (local, midnight
/// when no time given). Null when unparseable.
DateTime? parseModemDate(String? s) {
  if (s == null) return null;
  final m = RegExp(
    r'(\d{2})[-/](\d{2})[-/](\d{4})(?:\s+(\d{2}):(\d{2}):(\d{2}))?',
  ).firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(3)!),
    int.parse(m.group(2)!),
    int.parse(m.group(1)!),
    m.group(4) == null ? 0 : int.parse(m.group(4)!),
    m.group(5) == null ? 0 : int.parse(m.group(5)!),
    m.group(6) == null ? 0 : int.parse(m.group(6)!),
  );
}

/// SMS store usage from the modem capacity map: (used, total) for
/// [store] (1 = device, 0 = SIM). Zeros when the firmware reports
/// nothing — callers treat total <= 0 as unknown, never as full.
/// Pure + tested.
(int used, int total) smsStoreUsage(
  Map<String, dynamic> capacity,
  int store,
) {
  int num(String k) => int.tryParse('${capacity[k] ?? ''}') ?? 0;
  if (store == 1) {
    return (num('sms_nv_rev_total'), num('sms_nv_total'));
  }
  return (num('sms_sim_rev_total'), num('sms_sim_total'));
}

/// Ids of the [n] oldest messages (numeric id ascending — the modem
/// hands ids out in arrival order). Pure + tested; drives auto-clean.
List<String> oldestSmsIds(List<SmsMessage> msgs, int n) {
  final sorted = [...msgs]..sort((a, b) {
    final ai = int.tryParse(a.id);
    final bi = int.tryParse(b.id);
    if (ai != null && bi != null) return ai.compareTo(bi);
    return a.id.compareTo(b.id);
  });
  return sorted.take(n).map((m) => m.id).toList();
}

/// "5m ago", "2h ago", "3d ago" for snapshot freshness labels.
String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Human data volume: "812 MB" under 1 GB, "92.4 GB" above.
String formatDataVolume(double mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// Raw byte counter -> MB.
double bytesToMb(dynamic v) =>
    (double.tryParse('$v') ?? 0) / (1024 * 1024);

/// Bytes/sec -> "850 B/s", "1.2 KB/s", "3.4 MB/s".
String formatRate(double bps) {
  if (bps >= 1024 * 1024) {
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
  if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  return '${bps.toStringAsFixed(0)} B/s';
}

/// Seconds online -> "45m", "37h", "2d 4h".
String formatOnlineTime(dynamic seconds) {
  final s = (double.tryParse('$seconds') ?? 0).toInt();
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d ${s % 86400 ~/ 3600}h';
}

// ── SMS text codecs (ports of stock util.js) ──────────────────────
// The modem stores message bodies as upper-hex UCS2-ish: BMP chars are
// 4-digit zero-padded, astral chars are unpadded codepoints. escapeMessage
// is a no-op in stock, so encode = hex only.

/// 'Hello' -> '00480065006C006C006F'.
String encodeSmsBody(String text) {
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
      final lo = text.codeUnitAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        final cp = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
        buf.write(cp.toRadixString(16).toUpperCase());
        i++;
        continue;
      }
    }
    buf.write(c.toRadixString(16).toUpperCase().padLeft(4, '0'));
  }
  return buf.toString();
}

/// Upper-hex body -> readable text (strips 0009/0000 + BOM like stock).
String decodeUcs2Hex(String hex) {
  if (hex.isEmpty) return '';
  final clean = hex.replaceAll('0009', '').replaceAll('0000', '');
  final buf = StringBuffer();
  for (var i = 0; i + 4 <= clean.length; i += 4) {
    final g = int.tryParse(clean.substring(i, i + 4), radix: 16);
    if (g == null) continue;
    if (g <= 0xFFFF) {
      buf.writeCharCode(g);
    } else {
      final v = g - 0x10000;
      buf.writeCharCode(0xD800 | (v >> 10));
      buf.writeCharCode(0xDC00 | (v & 0x3FF));
    }
  }
  final out = buf.toString();
  return out.startsWith('\uFEFF') ? out.substring(1) : out;
}

const _gsm7 = {
  '000A',
  '000C',
  '000D',
  '0020',
  '0021',
  '0022',
  '0023',
  '0024',
  '0025',
  '0026',
  '0027',
  '0028',
  '0029',
  '002A',
  '002B',
  '002C',
  '002D',
  '002E',
  '002F',
  '0030',
  '0031',
  '0032',
  '0033',
  '0034',
  '0035',
  '0036',
  '0037',
  '0038',
  '0039',
  '003A',
  '003B',
  '003C',
  '003D',
  '003E',
  '003F',
  '0040',
  '0041',
  '0042',
  '0043',
  '0044',
  '0045',
  '0046',
  '0047',
  '0048',
  '0049',
  '004A',
  '004B',
  '004C',
  '004D',
  '004E',
  '004F',
  '0050',
  '0051',
  '0052',
  '0053',
  '0054',
  '0055',
  '0056',
  '0057',
  '0058',
  '0059',
  '005A',
  '005B',
  '005C',
  '005D',
  '005E',
  '005F',
  '0061',
  '0062',
  '0063',
  '0064',
  '0065',
  '0066',
  '0067',
  '0068',
  '0069',
  '006A',
  '006B',
  '006C',
  '006D',
  '006E',
  '006F',
  '0070',
  '0071',
  '0072',
  '0073',
  '0074',
  '0075',
  '0076',
  '0077',
  '0078',
  '0079',
  '007A',
  '007B',
  '007C',
  '007D',
  '007E',
  '00A0',
  '00A1',
  '00A3',
  '00A4',
  '00A5',
  '00A7',
  '00BF',
  '00C4',
  '00C5',
  '00C6',
  '00C7',
  '00C9',
  '00D1',
  '00D6',
  '00D8',
  '00DC',
  '00DF',
  '00E0',
  '00E4',
  '00E5',
  '00E6',
  '00E8',
  '00E9',
  '00EC',
  '00F1',
  '00F2',
  '00F6',
  '00F8',
  '00F9',
  '00FC',
  '0393',
  '0394',
  '0398',
  '039B',
  '039E',
  '03A0',
  '03A3',
  '03A6',
  '03A8',
  '03A9',
  '20AC',
};

/// 'GSM7_default' when every char is in the GSM7 table, else 'UNICODE'.
String smsEncodeType(String text) {
  for (var i = 0; i < text.length; i++) {
    final h = text
        .codeUnitAt(i)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(4, '0');
    if (!_gsm7.contains(h)) return 'UNICODE';
  }
  return 'GSM7_default';
}

/// Stock getCurrentTimeString: "YY;MM;DD;HH;MM;SS;TZ" e.g. "26;09;13;14;05;33;+1".
String smsTimeString([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int v) => v < 10 ? '0$v' : '$v';
  // Mirror JS getTimezoneOffset(): minutes to ADD to local to get UTC.
  final jsOffset = -t.timeZoneOffset.inMinutes;
  final tzHours = -jsOffset / 60;
  final tzBody = tzHours % 1 == 0 ? tzHours.toStringAsFixed(0) : '$tzHours';
  final tz = '${jsOffset < 0 ? '+' : ''}$tzBody';
  return '${'${t.year}'.substring(2)};${two(t.month)};${two(t.day)};'
      '${two(t.hour)};${two(t.minute)};${two(t.second)};$tz';
}

/// Parse a data-balance reply like "2.3GB remaining" / "450MB left".
/// Returns MB, or null when no match. Adjust the regex per carrier.
double? parseDataBalanceMb(String ussdText) {
  final gb = RegExp(
    r'(\d+(?:\.\d+)?)\s*GB',
    caseSensitive: false,
  ).firstMatch(ussdText);
  if (gb != null) return double.parse(gb.group(1)!) * 1024;
  final mb = RegExp(
    r'(\d+(?:\.\d+)?)\s*MB',
    caseSensitive: false,
  ).firstMatch(ussdText);
  if (mb != null) return double.parse(mb.group(1)!);
  return null;
}
