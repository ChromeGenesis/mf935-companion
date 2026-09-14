import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'models.dart';
import 'zte_utils.dart' as zu;

// Compatibility: models + pure helpers moved to dedicated modules, but
// every existing `import 'zte_client.dart'` keeps seeing them (SSOT).
export 'models.dart';
export 'zte_utils.dart';

/// Thin client for the ZTE MF935 localhost web UI (default 192.168.0.1).
///
/// Only two goform endpoints exist:
///  - GET  /goform/goform_get_cmd_process?cmd=...      (status polling)
///  - POST /goform/goform_set_cmd_process              (LOGIN / SEND_SMS / USSD_PROCESS)
///
/// Browser + app share one login session: opening both can kick each other out.
class ZteClient {
  ZteClient({this._gatewayIp = '192.168.0.1', PersistCookieJar? cookieJar}) {
    _dio = Dio(
      BaseOptions(
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
      ),
    );
    _cookieJar = cookieJar ?? PersistCookieJar();
    _dio.interceptors.add(CookieManager(_cookieJar));
    // The stock web UI always sends these; some firmwares reject the
    // goform POST without a same-origin Referer.
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Referer'] =
              'http://${_dio.options.baseUrl.replaceFirst('http://', '')}/index.html';
          options.headers['Origin'] = _dio.options.baseUrl;
          handler.next(options);
        },
      ),
    );
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
          'MiFi API responding at $_gatewayIp (goform OK). Now log in below.',
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
          'Router page reachable at $_gatewayIp (HTTP ${res.statusCode}). Now log in below.',
        );
      }
      final title = RegExp(
        r'<title[^>]*>(.*?)</title>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(body)?.group(1)?.trim();
      return (
        false,
        'That is NOT the MiFi: ${title != null && title.isNotEmpty ? 'page title is "$title"' : 'no ZTE markers in reply'} '
            '(HTTP ${res.statusCode}). Join the MF935 WiFi, or fix the gateway IP.',
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
        data: {'isTest': 'false', 'goformId': 'LOGIN', 'password': credential},
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
              false,
              'Malformed login request (result=1).',
              raw,
            );
          case '3':
            return LoginResult(false, 'Wrong password (result=3).', raw);
          case '2':
            return LoginResult(false, 'Router refused login (result=2).', raw);
          default:
            if (result.isNotEmpty) {
              return LoginResult(
                false,
                'Router rejected login (result=$result).',
                raw,
              );
            }
        }
      }
      // Some firmwares answer 200 with an empty/odd body on success when the
      // session cookie is already valid — verify with a status poll.
      if (res.statusCode == 200) {
        final probe = await getStatus(cmds: const ['battery_vol_percent']);
        if (probe.containsKey('battery_vol_percent')) {
          return LoginResult(
            true,
            'Login accepted (verified with status poll).',
            raw,
          );
        }
        return LoginResult(
          false,
          'Router answered but status poll came back empty — likely still logged out.',
          raw,
        );
      }
      return LoginResult(false, 'Unexpected HTTP ${res.statusCode}.', raw);
    } on DioException catch (e) {
      return LoginResult(
        false,
        _describeDioError(e),
        e.response?.data?.toString() ?? '',
      );
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
      cmds: const ['ussd_data_info'],
      multiData: false,
    );
    return decodeUcs2Hex(
      status['ussd_data']?.toString() ??
          status['ussd_data_info']?.toString() ??
          '',
    );
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
    if (!sent) {
      return const UssdResult(false, '', '', '', 'Modem refused the request.');
    }
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
          cmds: const ['ussd_write_flag'],
          multiData: false,
        );
        flag = '${m['ussd_write_flag'] ?? ''}';
      } catch (e) {
        return UssdResult(false, '', '', '', 'Poll failed: $e');
      }
      if (flag == '15') continue; // still processing
      if (flag == '16') {
        try {
          final m = await getStatus(
            cmds: const ['ussd_data_info'],
            multiData: false,
          );
          final text = decodeUcs2Hex('${m['ussd_data'] ?? ''}');
          return UssdResult(true, text, '${m['ussd_action'] ?? ''}', flag, '');
        } catch (e) {
          return UssdResult(false, '', '', flag, 'Reply fetch failed: $e');
        }
      }
      return UssdResult(false, '', '', flag, ussdFlagLabel(flag));
    }
    return const UssdResult(false, '', '', '', 'Timed out waiting for reply.');
  }

  // ── Pure helpers (SSOT in zte_utils.dart) ─────────────────────────
  // Thin static forwarders: identical signatures, zero behavior change.
  // Existing `ZteClient.xxx(...)` call sites and tests keep working.

  /// Human label for a terminal ussd_write_flag value (stock service.js).
  static String ussdFlagLabel(String flag) => zu.ussdFlagLabel(flag);

  /// Nested hash from the ZTE web UI (see [zu.generateAuthHash]).
  static String generateAuthHash(String password, String ld) =>
      zu.generateAuthHash(password, ld);

  /// Map a numeric PLMN (MCCMNC, e.g. "62120") to a carrier name.
  /// Non-numeric provider strings pass through untouched.
  static String carrierName(String provider) => zu.carrierName(provider);

  /// Normalize a USSD code: strip spaces, ensure it starts with '*'
  /// and ends with '#'. Every network USSD code has that shape.
  static String normalizeUssd(String raw) => zu.normalizeUssd(raw);

  /// Plausible USSD: *...# with at least one digit, digits/* only inside.
  static bool isValidUssd(String code) => zu.isValidUssd(code);

  /// Priority layers (never blank — quota is guaranteed). See
  /// [zu.resolveDataBalance] for the full contract.
  static DataBalance resolveDataBalance(String raw, DateTime fetchedAt) =>
      zu.resolveDataBalance(raw, fetchedAt);

  /// Plan window in days inferred from the bundle name. Drives the header
  /// fuse ring only — never displayed as fact, the exact countdown is.
  static int expiryWindowDays(String name) => zu.expiryWindowDays(name);

  /// Every `<amount> KB|MB|GB` in free text, converted to MB.
  static List<double> extractDataAmounts(String text) =>
      zu.extractDataAmounts(text);

  /// First modem date ("dd-MM-yyyy [HH:mm:ss]" or slashes) in free text.
  static DateTime? scanModemDate(String text) => zu.scanModemDate(text);

  /// Parse a balance reply into bundles (Airtel + MTN shapes).
  /// Menu prompts without an amount are skipped.
  static List<DataBundle> parseDataBundles(String text) =>
      zu.parseDataBundles(text);

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
  static String timeAgo(DateTime t) => zu.timeAgo(t);

  /// Human data volume: "812 MB" under 1 GB, "92.4 GB" above.
  static String formatDataVolume(double mb) => zu.formatDataVolume(mb);

  /// Raw byte counter -> MB.
  static double bytesToMb(dynamic v) => zu.bytesToMb(v);

  /// Bytes/sec -> "850 B/s", "1.2 KB/s", "3.4 MB/s".
  static String formatRate(double bps) => zu.formatRate(bps);

  /// Seconds online -> "45m", "37h", "2d 4h".
  static String formatOnlineTime(dynamic seconds) =>
      zu.formatOnlineTime(seconds);

  // ── SMS text codecs (SSOT in zte_utils.dart) ──────────────────────

  /// 'Hello' -> '00480065006C006C006F'.
  static String encodeSmsBody(String text) => zu.encodeSmsBody(text);

  /// Upper-hex body -> readable text (strips 0009/0000 + BOM like stock).
  static String decodeUcs2Hex(String hex) => zu.decodeUcs2Hex(hex);

  /// 'GSM7_default' when every char is in the GSM7 table, else 'UNICODE'.
  static String smsEncodeType(String text) => zu.smsEncodeType(text);

  /// Stock getCurrentTimeString: "YY;MM;DD;HH;MM;SS;TZ" e.g. "26;09;13;14;05;33;+1".
  static String smsTimeString([DateTime? now]) => zu.smsTimeString(now);

  /// Parse a data-balance reply like "2.3GB remaining" / "450MB left".
  /// Returns MB, or null when no match. Adjust the regex per carrier.
  static double? parseDataBalanceMb(String ussdText) =>
      zu.parseDataBalanceMb(ussdText);

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
  Future<Map<String, dynamic>> getSmsCapacity() =>
      getStatus(cmds: const ['sms_capacity_info'], multiData: false);

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
      cmds: const ['sms_parameter_info'],
      multiData: false,
    );
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
  Future<Map<String, dynamic>> getDeviceInfo() => getStatus(
    cmds: const [
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
    ],
  );

  /// Realtime + monthly traffic counters.
  Future<Map<String, dynamic>> getTrafficStats() => getStatus(
    cmds: const [
      'realtime_tx_bytes',
      'realtime_rx_bytes',
      'realtime_time',
      'realtime_tx_thrpt',
      'realtime_rx_thrpt',
      'monthly_rx_bytes',
      'monthly_tx_bytes',
      'monthly_time',
      'date_month',
    ],
  );

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
  Future<Map<String, dynamic>> getDataLimit() => getStatus(
    cmds: const [
      'data_volume_limit_switch',
      'data_volume_limit_unit',
      'data_volume_limit_size',
      'data_volume_alert_percent',
    ],
  );

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
    final m = await getStatus(cmds: const ['station_list'], multiData: false);
    final raw = m['station_list'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) {
      final map = Map<String, dynamic>.from(e);
      final host = '${map['hostname'] ?? ''}';
      DateTime? connectedAt;
      final ctime = int.tryParse('${map['ctime'] ?? ''}');
      if (ctime != null && ctime > 0) {
        connectedAt = DateTime.fromMillisecondsSinceEpoch(ctime * 1000);
      }
      return AttachedDevice(
        mac: '${map['mac_addr'] ?? ''}',
        hostname: host.isEmpty ? 'unknown' : host,
        ip: '${map['ip_addr'] ?? ''}',
        connectedAt: connectedAt,
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
