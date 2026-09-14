import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// Outcome of a LOGIN attempt, with the router's raw reply attached so the
/// UI can show exactly what the device said (wrong password vs unreachable
/// vs unexpected firmware response).
class LoginResult {
  final bool success;
  final String message;
  final String raw;

  const LoginResult(this.success, this.message, [this.raw = '']);

  @override
  String toString() => 'LoginResult($success, $message, $raw)';
}

/// Outcome of a USSD transaction: [text] is the decoded reply, [action]
// "1" means the network waits for a reply (interactive menu).
class UssdResult {
  final bool success;
  final String text;
  final String action;
  final String flag;
  final String error;

  const UssdResult(this.success, this.text, this.action, this.flag, this.error);

  bool get needsReply => success && action == '1';
}

/// One SMS from the modem store. [content] is decoded to readable text.
class SmsMessage {
  final String id;
  final String number;
  final String content;
  final String tag;
  final String date;
  final String draftGroupId;

  const SmsMessage({
    required this.id,
    required this.number,
    required this.content,
    required this.tag,
    required this.date,
    required this.draftGroupId,
  });

  bool get isNew => tag == '1';
  /// "26,09,13,14,44,04,+4" -> "26/09/13 14:44:04".
  String get displayDate {
    final parts = date.split(',');
    if (parts.length < 6) return date;
    return '${parts[0]}/${parts[1]}/${parts[2]} '
        '${parts[3].padLeft(2, '0')}:${parts[4].padLeft(2, '0')}:${parts[5].padLeft(2, '0')}';
  }
}

/// Group messages by sender, first-seen order preserved. Single grouping
/// path for inbox + tests (SSOT).
List<MapEntry<String, List<SmsMessage>>> groupSmsBySender(
    List<SmsMessage> msgs) {
  final groups = <String, List<SmsMessage>>{};
  for (final m in msgs) {
    groups.putIfAbsent(m.number, () => []).add(m);
  }
  return groups.entries.toList();
}

/// One attached station from station_list.
class AttachedDevice {
  final String mac;
  final String hostname;
  final String ip;

  const AttachedDevice(
      {required this.mac, required this.hostname, required this.ip});
}

/// One carrier data bundle. [expiry] is best-effort: when the reply
/// names no date, the first date seen anywhere in the reply is attached
/// (balance texts only ever mention expiry dates) — still inspectable
/// via the raw reply shown under the card.
class DataBundle {
  final String name;
  final double mb;
  final DateTime? expiry;

  const DataBundle({required this.name, required this.mb, this.expiry});

  /// Days until expiry (negative = expired). Null when unknown.
  int? get daysLeft =>
      expiry == null ? null : expiry!.difference(DateTime.now()).inDays;

  Map<String, dynamic> toJson() => {
        'name': name,
        'mb': mb,
        'expiry': expiry?.toIso8601String(),
      };

  factory DataBundle.fromJson(Map<String, dynamic> j) => DataBundle(
        name: '${j['name'] ?? ''}',
        mb: (j['mb'] as num?)?.toDouble() ?? 0,
        expiry: j['expiry'] == null
            ? null
            : DateTime.tryParse('${j['expiry']}'),
      );
}

/// Persisted data-balance snapshot: survives SMS deletion, app restarts,
/// anything. Refreshed by dialing *323*1# (see [ZteClient.fetchDataBalance]).
class DataBalance {
  final List<DataBundle> bundles;
  final String raw;
  final DateTime fetchedAt;

  const DataBalance(
      {required this.bundles, required this.raw, required this.fetchedAt});

  double get totalMb => bundles.fold(0, (a, b) => a + b.mb);

  /// Soonest-dated bundle still in the future (the one that matters).
  DataBundle? get nextExpiry {
    final dated = bundles.where((b) => b.expiry != null).toList()
      ..sort((a, b) => a.expiry!.compareTo(b.expiry!));
    if (dated.isEmpty) return null;
    final now = DateTime.now();
    return dated.firstWhere((b) => b.expiry!.isAfter(now),
        orElse: () => dated.last);
  }

  Map<String, dynamic> toJson() => {
        'bundles': bundles.map((b) => b.toJson()).toList(),
        'raw': raw,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory DataBalance.fromJson(Map<String, dynamic> j) {
    final raw = j['bundles'];
    return DataBalance(
      bundles: raw is List
          ? raw
              .whereType<Map>()
              .map((e) =>
                  DataBundle.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : [],
      raw: '${j['raw'] ?? ''}',
      fetchedAt: DateTime.tryParse('${j['fetchedAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Thin client for the ZTE MF935 localhost web UI (default 192.168.0.1).
///
/// Only two goform endpoints exist:
///  - GET  /goform/goform_get_cmd_process?cmd=...      (status polling)
///  - POST /goform/goform_set_cmd_process              (LOGIN / SEND_SMS / USSD_PROCESS)
///
/// Browser + app share one login session: opening both can kick each other out.
class ZteClient {
  ZteClient({String gatewayIp = '192.168.0.1', PersistCookieJar? cookieJar})
      : _gatewayIp = gatewayIp {
    _dio = Dio(BaseOptions(
      baseUrl: 'http://$_gatewayIp',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      // ZTE returns JSON as text/plain sometimes; accept everything.
      responseType: ResponseType.plain,
      headers: {
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      },
    ));
    _cookieJar = cookieJar ?? PersistCookieJar();
    _dio.interceptors.add(CookieManager(_cookieJar));
    // The stock web UI always sends these; some firmwares reject the
    // goform POST without a same-origin Referer.
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['Referer'] = 'http://${_dio.options.baseUrl.replaceFirst('http://', '')}/index.html';
        options.headers['Origin'] = _dio.options.baseUrl;
        handler.next(options);
      },
    ));
  }

  late final Dio _dio;
  late final PersistCookieJar _cookieJar;
  String _gatewayIp;

  String get gatewayIp => _gatewayIp;

  set gatewayIp(String value) {
    _gatewayIp = value;
    _dio.options.baseUrl = 'http://$value';
  }

  /// Reachability check that talks to the goform API itself instead of
  /// sniffing the index page (carrier-branded pages contain no "ZTE"
  /// markers). A JSON map with the requested keys — even with empty
  /// values — proves the MiFi API is alive at [_gatewayIp].
  Future<(bool reachable, String detail)> testConnection() async {
    try {
      final res = await _dio.get(
        '/goform/goform_get_cmd_process',
        queryParameters: {
          'isTest': 'false',
          'cmd': 'wa_inner_version,cr_version',
          'multi_data': 1,
          '_': DateTime.now().millisecondsSinceEpoch,
        },
      );
      final body = _decode(res.data);
      if (body is Map &&
          (body.containsKey('wa_inner_version') ||
              body.containsKey('cr_version'))) {
        return (
          true,
          'MiFi API responding at $_gatewayIp (goform OK). Now log in below.'
        );
      }
    } on DioException catch (e) {
      // Connection-level failure: nothing there at all.
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return (false, _describeDioError(e));
      }
      // Other HTTP errors fall through to the page check below.
    } catch (_) {
      // Fall through to the page check below.
    }
    try {
      final res = await _dio.get(
        '/',
        options: Options(responseType: ResponseType.plain),
      );
      final body = '${res.data}';
      if (body.contains('goform') ||
          body.contains('ZTE') ||
          body.contains('UFI')) {
        return (
          true,
          'Router page reachable at $_gatewayIp (HTTP ${res.statusCode}). Now log in below.'
        );
      }
      final title = RegExp(r'<title[^>]*>(.*?)</title>',
              caseSensitive: false, dotAll: true)
          .firstMatch(body)
          ?.group(1)
          ?.trim();
      return (
        false,
        'That is NOT the MiFi: ${title != null && title.isNotEmpty ? 'page title is "$title"' : 'no ZTE markers in reply'} '
            '(HTTP ${res.statusCode}). Join the MF935 WiFi, or fix the gateway IP.'
      );
    } on DioException catch (e) {
      return (false, _describeDioError(e));
    } catch (e) {
      return (false, 'Unreachable: $e');
    }
  }

  /// Probe firmware auth capabilities (unauthenticated). A non-empty LD/RD
  /// means the firmware uses the token login scheme on top of the password.
  Future<Map<String, dynamic>> getAuthCaps() async {
    try {
      return await getStatus(
        cmds: const ['LD', 'RD', 'wa_inner_version', 'cr_version'],
      );
    } catch (_) {
      return {};
    }
  }

  /// Lockout counters (safe GET, costs no login attempt):
  /// - failsLeft: remaining attempts before 300s lockout (5 fresh).
  /// - lockSecs: seconds until lockout lifts (-1/0 = not locked).
  Future<(int failsLeft, int lockSecs)> getLoginCounters() async {
    try {
      final m = await getStatus(
        cmds: const ['psw_fail_num_str', 'login_lock_time'],
      );
      return (
        int.tryParse('${m['psw_fail_num_str'] ?? ''}') ?? -1,
        int.tryParse('${m['login_lock_time'] ?? ''}') ?? -1,
      );
    } catch (_) {
      return (-1, -1);
    }
  }

  /// LOGIN using the firmware's real scheme (reverse-engineered from the
  /// stock web UI's util.js/service.js, WEB_ATTR_IF_SUPPORT_SHA256=2):
  ///
  ///   password_hash = SHA256( hex(SHA256(password)) + LD )
  ///
  /// where LD is a dynamic salt fetched from the device before every
  /// attempt. If the device reports no LD (older firmware), falls back to
  /// the legacy base64 password.
  Future<LoginResult> login(String password) async {
    String credential;
    try {
      final caps = await getStatus(cmds: const ['LD']);
      final ld = '${caps['LD'] ?? ''}';
      credential = ld.isNotEmpty
          ? generateAuthHash(password, ld)
          : base64Encode(utf8.encode(password));
    } catch (_) {
      credential = base64Encode(utf8.encode(password));
    }
    try {
      final res = await _dio.post(
        '/goform/goform_set_cmd_process',
        // Field order mirrors the stock web UI byte-for-byte:
        // isTest=false&goformId=LOGIN&password=<UPPERCASE_HEX>
        data: {
          'isTest': 'false',
          'goformId': 'LOGIN',
          'password': credential,
        },
      );
      final raw = '${res.data}'.trim();
      final body = _decode(res.data);
      if (body is Map) {
        // Verified semantics on this firmware family: 0 = success,
        // 3 = wrong password, 1 = malformed. Lockout state is NOT in the
        // result — read psw_fail_num_str / login_lock_time instead.
        final result = '${body['result'] ?? ''}';
        switch (result) {
          case '0':
            return LoginResult(true, 'Login accepted by router.', raw);
          case '1':
            return LoginResult(
                false, 'Malformed login request (result=1).', raw);
          case '3':
            return LoginResult(
                false, 'Wrong password (result=3).', raw);
          case '2':
            return LoginResult(
              false,
              'Router refused login (result=2).',
              raw,
            );
          default:
            if (result.isNotEmpty) {
              return LoginResult(false, 'Router rejected login (result=$result).', raw);
            }
        }
      }
      // Some firmwares answer 200 with an empty/odd body on success when the
      // session cookie is already valid — verify with a status poll.
      if (res.statusCode == 200) {
        final probe = await getStatus(cmds: const ['battery_vol_percent']);
        if (probe.containsKey('battery_vol_percent')) {
          return LoginResult(true, 'Login accepted (verified with status poll).', raw);
        }
        return LoginResult(
          false,
          'Router answered but status poll came back empty — likely still logged out.',
          raw,
        );
      }
      return LoginResult(false, 'Unexpected HTTP ${res.statusCode}.', raw);
    } on DioException catch (e) {
      return LoginResult(false, _describeDioError(e), e.response?.data?.toString() ?? '');
    } catch (e) {
      return LoginResult(false, 'Login error: $e', '');
    }
  }

  /// Poll status fields in one GET. Defaults cover the dashboard.
  /// Some table endpoints (sms_data_total, station_list, ussd flags)
  /// return empty when multi_data=1 is present — pass [multiData]=false
  /// for those (matches the stock UI, which omits it there).
  Future<Map<String, dynamic>> getStatus({
    List<String> cmds = const [
      'battery_vol_percent',
      'battery_charging',
      'signalbar',
      'network_provider',
      'network_type',
      'sms_unread_num',
      'monthly_rx_bytes',
      'monthly_tx_bytes',
      'monthly_time',
      'realtime_rx_thrpt',
      'realtime_tx_thrpt',
      'ussd_data_info',
    ],
    Map<String, dynamic> extra = const {},
    bool multiData = true,
  }) async {
    final query = <String, dynamic>{
      'isTest': 'false',
      'cmd': cmds.join(','),
      ...extra,
      '_': DateTime.now().millisecondsSinceEpoch,
    };
    if (multiData) query['multi_data'] = 1;
    final res = await _dio.get(
      '/goform/goform_get_cmd_process',
      // Same shape as the stock UI: isTest=false + millis cache-buster.
      queryParameters: query,
    );
    final body = _decode(res.data);
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    return {};
  }

  /// Send a USSD code (e.g. `*312#`). Correct wire shape per stock
  /// service.js + live verification: POST USSD_send_number with
  /// USSD_operator=ussd_send. Use [runUssd] to send AND wait for reply.
  /// Returns true when the modem accepted the request (result=success).
  Future<bool> sendUssd(String ussdString) async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'USSD_PROCESS',
        'USSD_operator': 'ussd_send',
        'USSD_send_number': ussdString,
      },
    );
    final body = _decode(res.data);
    if (body is Map && body['result'] != null) {
      final r = '${body['result']}';
      return r == 'success' || r == '0';
    }
    return res.statusCode == 200;
  }

  /// Reply to an interactive USSD menu (stock: USSD_reply_number with
  /// USSD_operator=ussd_reply, verified live).
  Future<bool> replyUssd(String text) async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'USSD_PROCESS',
        'USSD_operator': 'ussd_reply',
        'USSD_reply_number': text,
      },
    );
    final body = _decode(res.data);
    if (body is Map && body['result'] != null) {
      final r = '${body['result']}';
      return r == 'success' || r == '0';
    }
    return res.statusCode == 200;
  }

  /// Cancel a stale USSD session before starting a new one, exactly like
  /// the stock UI does (captured): GET goform_set_cmd_process with
  /// goformId=USSD_PROCESS & USSD_operator=ussd_cancel.
  Future<void> cancelUssd() async {
    await _dio.get(
      '/goform/goform_set_cmd_process',
      queryParameters: {
        'goformId': 'USSD_PROCESS',
        'USSD_operator': 'ussd_cancel',
        '_': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  /// Poll the async USSD reply text (empty while the network is processing).
  /// Prefer [runUssd], which follows the full write_flag state machine.
  Future<String> getUssdResult() async {
    final status = await getStatus(
        cmds: const ['ussd_data_info'], multiData: false);
    return decodeUcs2Hex(status['ussd_data']?.toString() ??
        status['ussd_data_info']?.toString() ??
        '');
  }

  /// Full USSD transaction: send [code], then follow ussd_write_flag until
  /// the reply arrives (16) or a terminal state hits. State table from
  /// stock service.js, verified live on this device.
  Future<UssdResult> runUssd(
    String code, {
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async {
    bool sent;
    try {
      sent = await sendUssd(code);
    } catch (e) {
      return UssdResult(false, '', '', '', 'Send failed: $e');
    }
    if (!sent) return const UssdResult(false, '', '', '', 'Modem refused the request.');
    return waitUssdReply(pollEvery: pollEvery, maxPolls: maxPolls);
  }

  /// Wait for the reply to an already-sent USSD request (or reply).
  Future<UssdResult> waitUssdReply({
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async {
    for (var i = 0; i < maxPolls; i++) {
      await Future.delayed(pollEvery);
      String flag;
      try {
        final m = await getStatus(
            cmds: const ['ussd_write_flag'], multiData: false);
        flag = '${m['ussd_write_flag'] ?? ''}';
      } catch (e) {
        return UssdResult(false, '', '', '', 'Poll failed: $e');
      }
      if (flag == '15') continue; // still processing
      if (flag == '16') {
        try {
          final m = await getStatus(
              cmds: const ['ussd_data_info'], multiData: false);
          final text = decodeUcs2Hex('${m['ussd_data'] ?? ''}');
          return UssdResult(
              true, text, '${m['ussd_action'] ?? ''}', flag, '');
        } catch (e) {
          return UssdResult(false, '', '', flag, 'Reply fetch failed: $e');
        }
      }
      return UssdResult(false, '', '', flag, ussdFlagLabel(flag));
    }
    return const UssdResult(false, '', '', '', 'Timed out waiting for reply.');
  }

  /// Human label for a terminal ussd_write_flag value (stock service.js).
  static String ussdFlagLabel(String flag) {
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

  /// Nested hash from the ZTE web UI (service.js login() + util.js
  /// `paswordAlgorithmsCookie`, verified against the live firmware):
  /// `SHA256( UPPER(SHA256(password)) + LD )`, UPPERCASE hex throughout —
  /// the JS SHA256 stringifier uses the upper lookup table (`r=1`).
  /// Proven with a live `{"result":"0"}` on this exact device.
  static String generateAuthHash(String password, String ld) {
    final first =
        sha256.convert(utf8.encode(password)).toString().toUpperCase();
    return sha256.convert(utf8.encode(first + ld)).toString().toUpperCase();
  }

  /// Map a numeric PLMN (MCCMNC, e.g. "62120") to a carrier name.
  /// Non-numeric provider strings pass through untouched.
  static String carrierName(String provider) {
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
  static String normalizeUssd(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (!s.startsWith('*')) s = '*$s';
    if (!s.endsWith('#')) s = '$s#';
    return s;
  }

  /// Plausible USSD: *...# with at least one digit, digits/* only inside.
  static bool isValidUssd(String code) =>
      RegExp(r'^\*[0-9*]+#$').hasMatch(code.trim());

  /// Priority layers (never blank — quota is guaranteed):
  /// 1. Structured bundles: "Name: 2.5GB till/expires <date>".
  /// 2. No structure? Sum every "<amount> UNIT" in the reply as "Data
  ///    left" (balance texts list remaining quotas, not usage).
  /// 3. No amounts at all? Empty bundles — the card then shows the raw
  ///    reply so the user still sees the answer.
  /// Expiry attaches per-bundle when named, else the first date found
  /// anywhere in the reply (best-effort, always verifiable in raw).
  static DataBalance resolveDataBalance(String raw, DateTime fetchedAt) {
    final structured = parseDataBundles(raw);
    if (structured.isNotEmpty) {
      final looseDate =
          structured.any((b) => b.expiry != null) ? null : scanModemDate(raw);
      final bundles = looseDate == null
          ? structured
          : structured
              .map((b) => b.expiry != null
                  ? b
                  : DataBundle(name: b.name, mb: b.mb, expiry: looseDate))
              .toList();
      return DataBalance(bundles: bundles, raw: raw, fetchedAt: fetchedAt);
    }
    final amounts = extractDataAmounts(raw);
    if (amounts.isNotEmpty) {
      return DataBalance(
        bundles: [
          DataBundle(
            name: 'Data left',
            mb: amounts.fold(0.0, (a, b) => a + b),
            expiry: scanModemDate(raw),
          ),
        ],
        raw: raw,
        fetchedAt: fetchedAt,
      );
    }
    return DataBalance(bundles: const [], raw: raw, fetchedAt: fetchedAt);
  }

  /// Every "<amount> KB|MB|GB" in free text, converted to MB.
  static List<double> extractDataAmounts(String text) {
    final re =
        RegExp(r'([\d.]+)\s*(KB|MB|GB)\b', caseSensitive: false);
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
  static DateTime? scanModemDate(String text) {
    final re = RegExp(
        r'(\d{2}[-/]\d{2}[-/]\d{4}(?:\s+\d{2}:\d{2}:\d{2})?)');
    final m = re.firstMatch(text);
    return m == null ? null : _parseModemDate(m.group(1));
  }

  /// Parse a balance reply into bundles. Handles both carrier shapes:
  /// - Airtel: "Weekly Bundle: 29990.35MB till 28-09-2026 02:09:12"
  /// - MTN:    "Daily: 20.59MB @N1.0/MB expires 14/09/2026"
  /// Menu prompts without an amount ("YouTube Night:*n Next",
  /// "InstaTop: NO.", point balances without units) are skipped.
  static List<DataBundle> parseDataBundles(String text) {
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
      out.add(DataBundle(
        name: (m.group(1) ?? '').trim(),
        mb: mb,
        expiry: _parseModemDate(m.group(4)),
      ));
    }
    return out;
  }

  /// "28-09-2026 02:09:12" / "14/09/2026" -> DateTime (local, midnight
  /// when no time given). Null when unparseable.
  static DateTime? _parseModemDate(String? s) {
    if (s == null) return null;
    final m =
        RegExp(r'(\d{2})[-/](\d{2})[-/](\d{4})(?:\s+(\d{2}):(\d{2}):(\d{2}))?')
            .firstMatch(s.trim());
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

  /// Dial *323*1#, follow "Next" pages (reply "n", up to [maxPages]),
  /// return the parsed snapshot. Throws on modem failure.
  Future<DataBalance> fetchDataBalance({int maxPages = 3}) async {
    try {
      await cancelUssd();
    } catch (_) {}
    var r = await runUssd('*323*1#');
    if (!r.success) throw Exception(r.error.isEmpty ? 'USSD failed' : r.error);
    var raw = r.text;
    var pages = 1;
    while (r.needsReply && pages < maxPages) {
      final sent = await replyUssd('n');
      if (!sent) break;
      r = await waitUssdReply();
      if (!r.success) break;
      raw = '$raw\n${r.text}';
      pages++;
    }
    try {
      await cancelUssd();
    } catch (_) {}
    return resolveDataBalance(raw, DateTime.now());
  }

  /// "5m ago", "2h ago", "3d ago" for snapshot freshness labels.
  static String timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// Human data volume: "812 MB" under 1 GB, "92.4 GB" above.
  static String formatDataVolume(double mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  /// Raw byte counter -> MB.
  static double bytesToMb(dynamic v) =>
      (double.tryParse('$v') ?? 0) / (1024 * 1024);

  /// Bytes/sec -> "850 B/s", "1.2 KB/s", "3.4 MB/s".
  static String formatRate(double bps) {
    if (bps >= 1024 * 1024) {
      return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  /// Seconds online -> "45m", "37h", "2d 4h".
  static String formatOnlineTime(dynamic seconds) {
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
  static String encodeSmsBody(String text) {
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
  static String decodeUcs2Hex(String hex) {
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

  static const _gsm7 = {
    '000A', '000C', '000D', '0020', '0021', '0022', '0023', '0024',
    '0025', '0026', '0027', '0028', '0029', '002A', '002B', '002C',
    '002D', '002E', '002F', '0030', '0031', '0032', '0033', '0034',
    '0035', '0036', '0037', '0038', '0039', '003A', '003B', '003C',
    '003D', '003E', '003F', '0040', '0041', '0042', '0043', '0044',
    '0045', '0046', '0047', '0048', '0049', '004A', '004B', '004C',
    '004D', '004E', '004F', '0050', '0051', '0052', '0053', '0054',
    '0055', '0056', '0057', '0058', '0059', '005A', '005B', '005C',
    '005D', '005E', '005F', '0061', '0062', '0063', '0064', '0065',
    '0066', '0067', '0068', '0069', '006A', '006B', '006C', '006D',
    '006E', '006F', '0070', '0071', '0072', '0073', '0074', '0075',
    '0076', '0077', '0078', '0079', '007A', '007B', '007C', '007D',
    '007E', '00A0', '00A1', '00A3', '00A4', '00A5', '00A7', '00BF',
    '00C4', '00C5', '00C6', '00C7', '00C9', '00D1', '00D6', '00D8',
    '00DC', '00DF', '00E0', '00E4', '00E5', '00E6', '00E8', '00E9',
    '00EC', '00F1', '00F2', '00F6', '00F8', '00F9', '00FC', '0393',
    '0394', '0398', '039B', '039E', '03A0', '03A3', '03A6', '03A8',
    '03A9', '20AC',
  };

  /// 'GSM7_default' when every char is in the GSM7 table, else 'UNICODE'.
  static String smsEncodeType(String text) {
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
  static String smsTimeString([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    // Mirror JS getTimezoneOffset(): minutes to ADD to local to get UTC.
    final jsOffset = -t.timeZoneOffset.inMinutes;
    final tzHours = -jsOffset / 60;
    final tzBody = tzHours % 1 == 0
        ? tzHours.toStringAsFixed(0)
        : '$tzHours';
    final tz = '${jsOffset < 0 ? '+' : ''}$tzBody';
    return '${'${t.year}'.substring(2)};${two(t.month)};${two(t.day)};'
        '${two(t.hour)};${two(t.minute)};${two(t.second)};$tz';
  }
  /// Parse a data-balance reply like "2.3GB remaining" / "450MB left".
  /// Returns MB, or null when no match. Adjust the regex per carrier.
  static double? parseDataBalanceMb(String ussdText) {
    final gb = RegExp(r'(\d+(?:\.\d+)?)\s*GB', caseSensitive: false)
        .firstMatch(ussdText);
    if (gb != null) return double.parse(gb.group(1)!) * 1024;
    final mb = RegExp(r'(\d+(?:\.\d+)?)\s*MB', caseSensitive: false)
        .firstMatch(ussdText);
    if (mb != null) return double.parse(mb.group(1)!);
    return null;
  }

  /// Send an SMS. Wire shape from stock service.js (NOT the old
  /// sms_param/sms_text guess — that was never real): Number +
  /// UCS2-hex MessageBody + encode_type + sms_time + ID.
  Future<bool> sendSms(String phoneNumber, String message) async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'SEND_SMS',
        'Number': phoneNumber,
        'MessageBody': encodeSmsBody(message),
        'ID': '',
        'encode_type': smsEncodeType(message),
        'sms_time': smsTimeString(),
      },
    );
    final body = _decode(res.data);
    if (body is Map && body['result'] != null) {
      final r = '${body['result']}';
      return r == 'success' || r == '0';
    }
    return res.statusCode == 200;
  }

  /// List SMS from a store: memStore 1 = device, 0 = SIM. tags '10' = all.
  /// NOTE: no multi_data (the modem returns empty with it) — verified live.
  Future<List<SmsMessage>> listSms({
    int page = 0,
    int perPage = 100,
    int memStore = 1,
    String tags = '10',
  }) async {
    final m = await getStatus(
      cmds: const ['sms_data_total'],
      extra: {
        'page': page,
        'data_per_page': perPage,
        'mem_store': memStore,
        'tags': tags,
        'order_by': 'order by id desc',
      },
      multiData: false,
    );
    final raw = m['messages'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) {
      final map = Map<String, dynamic>.from(e);
      return SmsMessage(
        id: '${map['id'] ?? ''}',
        number: '${map['number'] ?? ''}',
        content: decodeUcs2Hex('${map['content'] ?? ''}'),
        tag: '${map['tag'] ?? ''}',
        date: '${map['date'] ?? ''}',
        draftGroupId: '${map['draft_group_id'] ?? ''}',
      );
    }).toList();
  }

  /// Storage counters: sms_nv_total, sms_sim_total, *_rev_total etc.
  Future<Map<String, dynamic>> getSmsCapacity() => getStatus(
        cmds: const ['sms_capacity_info'],
        multiData: false,
      );

  /// Delete messages by id (DELETE_SMS, ids joined "1;2;").
  Future<bool> deleteSms(List<String> ids) async {
    if (ids.isEmpty) return true;
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'DELETE_SMS',
        'msg_id': '${ids.join(';')};',
      },
    );
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  /// Mark messages read (SET_MSG_READ, tag 0).
  Future<bool> markSmsRead(List<String> ids) async {
    if (ids.isEmpty) return true;
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'SET_MSG_READ',
        'msg_id': '${ids.join(';')};',
        'tag': 0,
      },
    );
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  /// SMS settings: centerNumber, memStore, deliveryReport, validity label.
  Future<Map<String, String>> getSmsSettings() async {
    final m = await getStatus(
        cmds: const ['sms_parameter_info'], multiData: false);
    const validityLabels = {
      '143': 'twelve_hours',
      '167': 'one_day',
      '173': 'one_week',
      '244': 'largest',
      '255': 'largest',
    };
    final v = '${m['sms_para_validity_period'] ?? ''}';
    return {
      'centerNumber': '${m['sms_para_sca'] ?? ''}',
      'memStore': '${m['sms_para_mem_store'] ?? ''}',
      'deliveryReport': '${m['sms_para_status_report'] ?? ''}',
      'validity': validityLabels[v] ?? 'twelve_hours',
    };
  }

  /// Save SMS settings (SET_MESSAGE_CENTER).
  Future<bool> setSmsSettings({
    required String centerNumber,
    required String validity,
    required String deliveryReport,
  }) async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'SET_MESSAGE_CENTER',
        'MessageCenter': centerNumber,
        'save_time': validity,
        'status_save': deliveryReport,
        'save_location': 'native',
      },
    );
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  // ── Information / statistics ──────────────────────────────────────

  /// Device information screen (29-key stock request).
  Future<Map<String, dynamic>> getDeviceInfo() => getStatus(cmds: const [
        'wifi_coverage',
        'm_ssid_enable',
        'imei',
        'web_version',
        'hardware_version',
        'MAX_Access_num',
        'wa_inner_version',
        'SSID1',
        'm_SSID',
        'm_HideSSID',
        'm_MAX_Access_num',
        'lan_ipaddr',
        'mac_address',
        'ussd_msisdn',
        'LocalDomain',
        'wan_ipaddr',
        'ipv6_wan_ipaddr',
        'pdp_type',
        'opms_wan_mode',
        'ppp_status',
        'sim_imsi',
        'rssi',
        'rscp',
        'lte_rsrp',
        'network_type',
      ]);

  /// Realtime + monthly traffic counters.
  Future<Map<String, dynamic>> getTrafficStats() => getStatus(cmds: const [
        'realtime_tx_bytes',
        'realtime_rx_bytes',
        'realtime_time',
        'realtime_tx_thrpt',
        'realtime_rx_thrpt',
        'monthly_rx_bytes',
        'monthly_tx_bytes',
        'monthly_time',
        'date_month',
      ]);

  /// Reset the data counter (RESET_DATA_COUNTER, option=curr_total_month).
  Future<bool> resetDataCounter() async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'RESET_DATA_COUNTER',
        'option': 'curr_total_month',
      },
    );
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  /// Data limit settings (raw keys: switch/unit/size/alert_percent).
  Future<Map<String, dynamic>> getDataLimit() => getStatus(cmds: const [
        'data_volume_limit_switch',
        'data_volume_limit_unit',
        'data_volume_limit_size',
        'data_volume_alert_percent',
      ]);

  /// Set the data limit. When [enabled] is false only the switch is sent.
  Future<bool> setDataLimit({
    required bool enabled,
    String unit = 'data',
    String size = '',
    String alertPercent = '',
  }) async {
    final data = <String, dynamic>{
      'isTest': 'false',
      'goformId': 'DATA_LIMIT_SETTING',
      'data_volume_limit_switch': enabled ? '1' : '0',
    };
    if (enabled) {
      data['data_volume_limit_unit'] = unit;
      data['data_volume_limit_size'] = size;
      data['data_volume_alert_percent'] = alertPercent;
    }
    final res = await _dio.post('/goform/goform_set_cmd_process', data: data);
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  /// Attached Wi-Fi stations (station_list, no multi_data — verified live).
  Future<List<AttachedDevice>> getConnectedDevices() async {
    final m = await getStatus(
        cmds: const ['station_list'], multiData: false);
    final raw = m['station_list'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) {
      final map = Map<String, dynamic>.from(e);
      final host = '${map['hostname'] ?? ''}';
      return AttachedDevice(
        mac: '${map['mac_addr'] ?? ''}',
        hostname: host.isEmpty ? 'unknown' : host,
        ip: '${map['ip_addr'] ?? ''}',
      );
    }).toList();
  }

  // ── Device management (safe subset) ───────────────────────────────

  Future<String> getPowerSave() async {
    final m = await getStatus(cmds: const ['auto_power_save']);
    return '${m['auto_power_save'] ?? ''}';
  }

  Future<bool> setPowerSave(String mode) async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {
        'isTest': 'false',
        'goformId': 'SET_AUTO_POWER_SAVE',
        'auto_power_save': mode,
      },
    );
    return _okResult(res.data) ?? res.statusCode == 200;
  }

  /// Reboot the MiFi. Returns the raw reply (connection will drop).
  Future<String> reboot() async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {'isTest': 'false', 'goformId': 'REBOOT_DEVICE'},
    );
    return '${res.data}';
  }

  /// Shut the MiFi down. Returns the raw reply (connection will drop).
  Future<String> shutdown() async {
    final res = await _dio.post(
      '/goform/goform_set_cmd_process',
      data: {'isTest': 'false', 'goformId': 'SHUTDOWN_DEVICE'},
    );
    return '${res.data}';
  }

  /// result=success/0 -> true, result=error/fail -> false, else null.
  bool? _okResult(dynamic data) {
    final body = _decode(data);
    if (body is Map && body['result'] != null) {
      final r = '${body['result']}';
      if (r == 'success' || r == '0') return true;
      return false;
    }
    return null;
  }

  String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Timed out reaching $_gatewayIp. Are you on the MiFi WiFi?';
      case DioExceptionType.connectionError:
        final inner = e.error;
        if (inner is SocketException) {
          return 'Cannot reach $_gatewayIp (${inner.osError?.message ?? inner.message}). '
              'Join the MF935 WiFi first, or fix the gateway IP.';
        }
        return 'Connection failed to $_gatewayIp: ${e.message}';
      case DioExceptionType.badResponse:
        return 'Router answered HTTP ${e.response?.statusCode}. Body: ${e.response?.data}';
      default:
        return 'Network error: ${e.message}';
    }
  }

  dynamic _decode(dynamic data) {
    if (data is Map) return data;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return {'raw': data};
      }
    }
    return {'raw': data.toString()};
  }
}
