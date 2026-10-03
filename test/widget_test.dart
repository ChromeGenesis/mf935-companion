import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zte_mf935_app/main.dart';
import 'package:zte_mf935_app/core/advanced.dart';
import 'package:zte_mf935_app/features/ussd_saved.dart';
import 'package:zte_mf935_app/core/device_store.dart';
import 'package:zte_mf935_app/core/incident_report.dart';
import 'package:zte_mf935_app/core/log_store.dart';
import 'package:zte_mf935_app/core/monitor_modes.dart';
import 'package:zte_mf935_app/core/ndt7_client.dart';
import 'package:zte_mf935_app/core/session_recovery.dart';
import 'package:zte_mf935_app/core/signal_locator.dart';
import 'package:zte_mf935_app/core/smart_alerts.dart';
import 'package:zte_mf935_app/core/speed_history.dart';
import 'package:zte_mf935_app/core/speed_test.dart';
import 'package:zte_mf935_app/core/theme.dart';
import 'package:zte_mf935_app/core/widgets.dart';
import 'package:zte_mf935_app/features/status_tab.dart';
import 'package:zte_mf935_app/features/ussd_tab.dart';
import 'package:zte_mf935_app/core/zte_client.dart';

void main() {
  testWidgets('Dashboard renders login form', (WidgetTester tester) async {
    // Prefs have no platform channel in widget tests — in-memory mock.
    SharedPreferences.setMockInitialValues({});
    // App enforces a 980x700 minimum window — render at supported size.
    tester.view.physicalSize = const Size(980, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ZteApp(initialMode: ThemeMode.dark));

    expect(find.text('MiFi Companion'), findsWidgets);
    // Connection lives exclusively in Settings (Status is read-only).
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    // Gateway field = the Connection panel. (The login button itself
    // may read "Login & poll" or "Wait Ns" — in-test the auth flow
    // really runs against no modem and starts its lockout cooldown.)
    expect(find.text('Gateway IP'), findsOneWidget);
  });

  test('USSD balance parsing handles GB and MB', () {
    expect(
      ZteClient.parseDataBalanceMb('Your balance is 2.3GB remaining'),
      2.3 * 1024,
    );
    expect(ZteClient.parseDataBalanceMb('450MB left'), 450);
    expect(ZteClient.parseDataBalanceMb('no match here'), isNull);
  });

  test('Carrier mapping + data volume formatting', () {
    expect(ZteClient.carrierName('62120'), 'Airtel NG');
    expect(ZteClient.carrierName('62130'), 'MTN NG');
    expect(ZteClient.carrierName('99999'), 'PLMN 99999');
    expect(ZteClient.carrierName('Airtel'), 'Airtel');
    expect(ZteClient.formatDataVolume(92357), '90.2 GB');
    expect(ZteClient.formatDataVolume(812), '812 MB');
    expect(ZteClient.formatDataVolume(4.3), '4.3 MB');
  });

  test('Auth hash matches firmware scheme SHA256(SHA256(pw) + LD)', () {
    // Uppercase throughout (firmware JS stringifier uses the upper table).
    // Vector cross-checked with .NET SHA256 + proven live result=0:
    // pw="admin", LD="ABCDEF123456".
    expect(
      ZteClient.generateAuthHash('admin', 'ABCDEF123456'),
      'C074D032E42BB20CCFEE15A1D15EEB999D0813BA8F0E9D358827A772D4280E34',
    );
    // Different salts must give different credentials.
    expect(
      ZteClient.generateAuthHash('admin', 'OTHER'),
      isNot(ZteClient.generateAuthHash('admin', 'ABCDEF123456')),
    );
  });

  test('SMS UCS2 codec round-trips (stock util.js scheme)', () {
    expect(ZteClient.encodeSmsBody('Hello'), '00480065006C006C006F');
    expect(ZteClient.decodeUcs2Hex('00480065006C006C006F'), 'Hello');
    // Live capture: Airtel menu fragment.
    expect(
      ZteClient.decodeUcs2Hex('00310020004D0079002000410069007200740065006C'),
      '1 My Airtel',
    );
    // BOM prefix + NUL terminator stripped like stock decodeMessage.
    expect(
      ZteClient.decodeUcs2Hex('FEFF0043007200650064006900740000'),
      'Credit',
    );
    // Astral chars: stock encodeMessage emits the combined codepoint
    // (unpadded), while real network UCS2 arrives as surrogate pairs —
    // both are handled the way the firmware does.
    expect(ZteClient.encodeSmsBody('\u{1F600}'), '1F600');
    expect(ZteClient.decodeUcs2Hex('D83DDE00'), '\u{1F600}');
    expect(ZteClient.smsEncodeType('Hello 123 *#'), 'GSM7_default');
    expect(ZteClient.smsEncodeType('Crédit €'), 'GSM7_default'); // in table
    expect(ZteClient.smsEncodeType('Привет'), 'UNICODE');
    expect(ZteClient.smsEncodeType('你好'), 'UNICODE');
  });

  test('SMS time string matches stock format', () {
    final s = ZteClient.smsTimeString(DateTime(2026, 9, 13, 14, 5, 33));
    expect(s, matches(RegExp(r'^26;09;13;14;05;33;[+-]?[\d.]+$')));
  });

  test('USSD flag labels cover terminal states', () {
    expect(ZteClient.ussdFlagLabel('1'), contains('No service'));
    expect(ZteClient.ussdFlagLabel('2'), contains('terminated'));
    expect(ZteClient.ussdFlagLabel('99'), contains('not supported'));
    expect(ZteClient.ussdFlagLabel('77'), contains('77'));
  });

  test('USSD normalize + validity (*...# always)', () {
    expect(ZteClient.normalizeUssd('*312#'), '*312#');
    expect(ZteClient.normalizeUssd('312'), '*312#');
    expect(ZteClient.normalizeUssd('*312'), '*312#');
    expect(ZteClient.normalizeUssd('312#'), '*312#');
    expect(ZteClient.normalizeUssd('  * 3 1 2 # '), '*312#');
    expect(ZteClient.isValidUssd('*312#'), isTrue);
    expect(ZteClient.isValidUssd('*#'), isFalse);
    expect(ZteClient.isValidUssd('312'), isFalse);
    expect(ZteClient.isValidUssd('*abc#'), isFalse);
  });

  test('USSD reply sanitizer repairs cable-eating line breaks', () {
    // Live Airtel *312# plans menu: items 3-9 run together behind a
    // ':' glued to the next item number (see bug screenshot).
    const menu =
        '1 My Airtel Offer\n2 Data Plans\n3 4GB @ N100:4 10GB @N300:5 '
        '4GB @N150:6 3GB @N75:7 1GB @N50:8 2GB @ N60:9 8GB @N250:* Next';
    final fixed = ZteClient.sanitizeUssdText(menu);
    expect(fixed.split('\n').length, 10, reason: 'one line per menu item');
    expect(fixed, contains('\n4 10GB @N300'));
    expect(fixed, contains('\n9 8GB @N250'));
    expect(fixed, endsWith('\n* Next'));

    // Captured Airtel *323*1# balance reply: one break collapsed to the
    // bullet, one mangled into a stray 'n'.
    const balance =
        'Your Balances Are:*Binge Bundle: 0.00MB till 15-09-2026 05:09:18,\n'
        'Weekly Bundle: 29990.35MB till 28-09-2026 02:09:12,\n'
        'YouTube Night:*n Next';
    final cleaned = ZteClient.sanitizeUssdText(balance);
    expect(cleaned, contains('Are:\n*Binge Bundle'));
    expect(cleaned, contains('Night:\n* Next'));
    // Real newline and clock colons survive untouched.
    expect(cleaned, contains('05:09:18,\nWeekly Bundle'));

    // Literal escape text becomes a break; stray controls are dropped.
    expect(ZteClient.sanitizeUssdText('a\\nb\u0007c'), 'a\nbc');
    // Clean replies pass through unchanged (no phantom line breaks).
    expect(ZteClient.sanitizeUssdText('Balance: 2.3GB'), 'Balance: 2.3GB');
    expect(ZteClient.sanitizeUssdText('Ready by 12:30 pm'),
        'Ready by 12:30 pm');
    expect(ZteClient.sanitizeUssdText(''), '');
  });

  test('USSD history roundtrip + cap (survives restarts)', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadUssdHistory(), isEmpty);

    final now = DateTime.now();
    var h = <UssdHistoryEntry>[];
    for (var i = 0; i < 35; i++) {
      h = pushUssdHistory(
        h,
        UssdHistoryEntry(
          request: '*312*$i#',
          reply: 'reply $i',
          ok: true,
          at: now.add(Duration(minutes: i)),
        ),
      );
    }
    expect(h.length, 30, reason: 'history caps at 30');
    await saveUssdHistory(h);
    final loaded = await loadUssdHistory();
    expect(loaded.length, 30);
    expect(loaded.first.request, h.first.request);
    expect(loaded.first.ok, isTrue);
    // Timestamps round-trip at millisecond precision (JSON encoding).
    expect(loaded.last.at.millisecondsSinceEpoch,
        h.last.at.millisecondsSinceEpoch);
  });

  test('SMS auto-clean opt-out: defaults on, migrates legacy once', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadSmsAutoCleanOff(), isFalse,
        reason: 'auto-clean is always on by default');

    // Legacy opt-in key flips once into the new inverted key.
    SharedPreferences.setMockInitialValues({'sms_autoclean': false});
    expect(await loadSmsAutoCleanOff(), isTrue);
    expect(await loadSmsAutoCleanOff(), isTrue,
        reason: 'migration persisted — stable across restarts');

    SharedPreferences.setMockInitialValues({'sms_autoclean': true});
    expect(await loadSmsAutoCleanOff(), isFalse);

    // New key wins over any legacy value.
    SharedPreferences.setMockInitialValues(
        {'sms_autoclean': false, 'sms_autoclean_off': false});
    expect(await loadSmsAutoCleanOff(), isFalse);
    await saveSmsAutoCleanOff(true);
    expect(await loadSmsAutoCleanOff(), isTrue);
  });

  test('Rate + online-time formatters', () {
    expect(ZteClient.formatRate(500), '500 B/s');
    expect(ZteClient.formatRate(2048), '2 KB/s');
    expect(ZteClient.formatRate(2.5 * 1024 * 1024), '2.5 MB/s');
    expect(ZteClient.formatOnlineTime('1500'), '25m');
    expect(ZteClient.formatOnlineTime(7200), '2h');
    expect(ZteClient.formatOnlineTime(133200), '1d 13h');
    expect(ZteClient.formatOnlineTime('190800'), '2d 5h');
    expect(ZteClient.formatOnlineTime(null), '0m');
  });

  test('Data bundle parsing (*323*1# reply shape)', () {
    const reply =
        'Your Balances Are:*Binge Bundle: 0.00MB till '
        '15-09-2026 05:09:18,\nWeekly Bundle: 29990.35MB till '
        '28-09-2026 02:09:12,\nYouTube Night:*n Next';
    final bundles = ZteClient.parseDataBundles(reply);
    expect(bundles.length, 2);
    // Display order is parse order here (sorting happens in resolve).
    expect(bundles[0].name, 'Binge Bundle');
    expect(bundles[0].mb, 0);
    expect(bundles[0].exhausted, isTrue);
    expect(bundles[0].expiry, DateTime(2026, 9, 15, 5, 9, 18));
    expect(bundles[1].name, 'Weekly Bundle');
    expect(bundles[1].mb, closeTo(29990.35, 0.01));
    expect(bundles[1].expiry, DateTime(2026, 9, 28, 2, 9, 12));
    // Resolved snapshot: live first, exhausted last, countdown skips
    // the exhausted bundle even though it expires sooner.
    final snap0 = ZteClient.resolveDataBalance(reply, DateTime.now());
    expect(snap0.bundles[0].name, 'Weekly Bundle');
    expect(snap0.bundles[1].name, 'Binge Bundle');
    expect(snap0.nextExpiry?.name, 'Weekly Bundle');
    // GB/KB units convert; menu prompts without amounts are skipped.
    final units = ZteClient.parseDataBundles(
      'A: 1.5GB till 01-01-2030 00:00:00, B: 512KB',
    );
    expect(units[0].mb, 1536);
    expect(units[1].mb, 0.5);
    expect(units[1].expiry, isNull);
    // MTN shape: @rate noise, "expires", slash dates without times,
    // unit-less lines skipped.
    const mtn =
        'Your data balances:\nDaily: 20.59MB @N1.0/MB expires '
        '14/09/2026\nPulse point balance: 187.50. Expires 31/12/2026\n'
        'InstaTop: NO.\nEnjoy comedy. Dial *306*15#.';
    final mb = ZteClient.parseDataBundles(mtn);
    expect(mb.length, 1);
    expect(mb[0].name, 'Daily');
    expect(mb[0].mb, closeTo(20.59, 0.001));
    expect(mb[0].expiry, DateTime(2026, 9, 14));
    // Fallback layers: unstructured amounts still yield a quota, and a
    // reply with no amounts at all keeps its raw text (never blank).
    final loose = ZteClient.resolveDataBalance(
      'Data: 500MB left, hurry.',
      DateTime.now(),
    );
    expect(loose.bundles.length, 1);
    expect(loose.bundles[0].mb, 500);
    expect(loose.bundles[0].expiry, isNull);
    final weird = ZteClient.resolveDataBalance(
      'Hello, quota plenty, dial 123.',
      DateTime.now(),
    );
    expect(weird.bundles, isEmpty);
    expect(weird.raw, isNotEmpty);
    expect(weird.totalMb, 0);
    final snap = DataBalance(
      bundles: bundles,
      raw: reply,
      fetchedAt: DateTime(2026, 9, 13),
    );
    final back = DataBalance.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(snap.toJson())) as Map),
    );
    expect(back.totalMb, closeTo(snap.totalMb, 0.01));
    expect(back.bundles.length, 2);
  });

  test('Countdown formatter — whole days above 24h, clock under a day', () {
    // Above 24h: whole days only, no clock component.
    expect(
      formatCountdown(
        const Duration(days: 11, hours: 4, minutes: 24, seconds: 53),
      ),
      '11 days',
    );
    expect(formatCountdown(const Duration(days: 1, hours: 2)), '1 day');
    // Under a day: HH:mm:ss only.
    expect(formatCountdown(const Duration(hours: 5)), '05:00:00');
    expect(
      formatCountdown(
        const Duration(hours: 14, minutes: 22, seconds: 31),
      ),
      '14:22:31',
    );
    expect(formatCountdown(const Duration(seconds: 90)), '00:01:30');
    expect(formatCountdown(Duration.zero), 'expired');
    expect(formatCountdown(const Duration(seconds: -5)), 'expired');
  });

  test('SMS grouping keeps first-seen sender order', () {
    SmsMessage m(String id, String n) => SmsMessage(
      id: id,
      number: n,
      content: 'x',
      tag: '0',
      date: '',
      draftGroupId: '',
    );
    final groups = groupSmsBySender([
      m('1', 'Airtel'),
      m('2', 'SmartCash'),
      m('3', 'Airtel'),
    ]);
    expect(groups.map((g) => g.key).toList(), ['Airtel', 'SmartCash']);
    expect(groups.first.value.map((x) => x.id).toList(), ['1', '3']);
    expect(groupSmsBySender([]), isEmpty);
  });

  test('SmsMessage date + AttachedDevice models', () {
    const m = SmsMessage(
      id: '2670',
      number: 'Airtel',
      content: 'hi',
      tag: '1',
      date: '26,09,13,14,44,04,+4',
      draftGroupId: '',
    );
    expect(m.isNew, isTrue);
    expect(m.displayDate, '26/09/13 14:44:04');
  });

  test('Fuse-ring plan window inference (best-effort, never shown)', () {
    expect(ZteClient.expiryWindowDays('Weekly Bundle'), 7);
    expect(ZteClient.expiryWindowDays('MONTHLY data'), 30);
    expect(ZteClient.expiryWindowDays('Daily Binge'), 1);
    expect(ZteClient.expiryWindowDays('Annual pack'), 365);
    expect(ZteClient.expiryWindowDays('Airtel NG'), 30);
    expect(ZteClient.expiryWindowDays(''), 30);
  });

  test('Balance USSD is carrier-aware (MTN *323*4#, Airtel *323*1#)', () {
    expect(ZteClient.balanceUssdForProvider('MTN NG'), '*323*4#');
    expect(ZteClient.balanceUssdForProvider('mtn ng'), '*323*4#');
    expect(ZteClient.balanceUssdForProvider('62130'), '*323*4#');
    expect(ZteClient.balanceUssdForProvider('Airtel NG'), '*323*1#');
    expect(ZteClient.balanceUssdForProvider('62120'), '*323*1#');
    expect(ZteClient.balanceUssdForProvider(''), '*323*1#');
  });

  test('Overall signal score averages reported bands, ignores gaps', () {
    SignalSample at({int? rsrp, int? rsrq, int? sinr}) => SignalSample(
      at: DateTime(2026, 1, 1),
      rsrp: rsrp,
      rsrq: rsrq,
      sinr: sinr,
    );
    // -81 RSRP = 4? No: >= -80 is 5, so -81 scores 4; -8 RSRQ scores 5;
    // 15 SINR scores 4 → mean 13/3.
    expect(
      signalOverallScore(at(rsrp: -81, rsrq: -8, sinr: 15)),
      closeTo(13 / 3, 0.001),
    );
    // Missing bands never drag the average: single metric stands alone.
    expect(signalOverallScore(at(rsrp: -95)), 3.0);
    expect(signalOverallScore(at()), isNull);
    expect(overallLabel(5.0), 'Excellent');
    expect(overallLabel(4.0), 'Good');
    expect(overallLabel(3.0), 'Fair');
    expect(overallLabel(1.0), 'Poor');
    expect(overallLabel(null), 'Waiting');
  });

  test('Signal parser tries SINR aliases, decimals, sentinels', () {
    final at = DateTime(2026, 1, 1);
    // Primary alias wins.
    var s = parseSignalSample({
      'lte_rsrp': '-95',
      'lte_rsrq': '-11',
      'lte_sinr': '14',
      'lte_snr': '3',
      'rssi': '-70',
      'rscp': '-80',
      'ecio': '-7',
    }, at);
    expect(s.rsrp, -95);
    expect(s.rsrq, -11);
    expect(s.sinr, 14); // lte_sinr beats stale lte_snr
    expect(s.rssi, -70);
    expect(s.rscp, -80);
    expect(s.ecio, -7);
    // Fallback alias when the primary key is absent.
    s = parseSignalSample({'lte_snr': '9', 'rssi': '-70'}, at);
    expect(s.sinr, 9);
    expect(s.rsrp, isNull);
    // Decimal firmware answers round instead of failing.
    s = parseSignalSample(
      {'lte_rsrp': '-95.0', 'lte_rsrq': '-11.5', 'rssi': '-70'},
      at,
    );
    expect(s.rsrp, -95);
    expect(s.rsrq, -12);
    // Sentinels and garbage stay null, never invented.
    s = parseSignalSample(
      {'lte_rsrp': '0', 'lte_rsrq': '', 'lte_sinr': 'abc', 'rssi': '5'},
      at,
    );
    expect(s.rsrp, isNull);
    expect(s.rsrq, isNull);
    expect(s.sinr, isNull);
    expect(s.rssi, isNull); // positive dBm is implausible
    // Empty reply: all null, score null, honest labels.
    s = parseSignalSample({}, at);
    expect(signalOverallScore(s), isNull);
    expect(rsrqLabel(s.rsrq), 'not reported');
    expect(sinrLabel(s.sinr), 'not reported');
    expect(rssiLabel(s.rssi), 'not reported');
    expect(rssiScore(s.rssi), -1);
  });

  test('RSSI substitute bands for dead LTE quality', () {
    expect(rssiLabel(-60), 'Excellent');
    expect(rssiLabel(-70), 'Good');
    expect(rssiLabel(-80), 'Fair');
    expect(rssiLabel(-90), 'Poor');
    expect(rssiScore(-60), 5);
    expect(rssiScore(-70), 4);
    expect(rssiScore(-80), 3);
    expect(rssiScore(-90), 2);
    expect(rssiScore(-100), 1);
    expect(rssiScore(null), -1);
  });

  test('Speed test math: median + throughput', () {    expect(medianOf([3.0]), 3.0);
    expect(medianOf([1.0, 3.0, 2.0]), 2.0);
    expect(medianOf([1.0, 2.0, 3.0, 4.0]), 2.5);
    expect(() => medianOf([]), throwsArgumentError);
    expect(throughputBps(1024, 1.0), 1024.0);
    expect(throughputBps(512, 0.5), 1024.0);
    expect(throughputBps(512, 0), 0);
    expect(throughputBps(512, -1), 0);
    // Parallel batch: summed streams over shared wall-clock.
    expect(batchThroughputBps([512, 512], 1.0), 1024.0);
    expect(batchThroughputBps([1024, 1024, 1024, 1024], 2.0), 2048.0);
    expect(batchThroughputBps([], 1.0), 0);
    expect(batchThroughputBps([512], 0), 0);
  });

  test('SMS auto-clean: usage parsing + oldest-first ids', () {
    const cap = {
      'sms_nv_rev_total': '82',
      'sms_nv_total': '100',
      'sms_sim_rev_total': '3',
      'sms_sim_total': '50',
    };
    expect(smsStoreUsage(cap, 1), (82, 100));
    expect(smsStoreUsage(cap, 0), (3, 50));
    expect(smsStoreUsage({}, 1), (0, 0));
    SmsMessage m(String id) => SmsMessage(
      id: id,
      number: 'x',
      content: 'y',
      tag: '0',
      date: '',
      draftGroupId: '',
    );
    final msgs = [m('9'), m('3'), m('7'), m('1')];
    expect(oldestSmsIds(msgs, 2), ['1', '3']);
    expect(oldestSmsIds(msgs, 99).length, 4);
    expect(oldestSmsIds([], 50), isEmpty);
  });

  test('ndt7 locate parsing prefers wss, skips incomplete', () {
    final locate = {
      'results': [
        {
          'machine': 'mlab1-xyz.mlab-oti.measurement-lab.org',
          'location': {'city': 'Lagos', 'country': 'NG'},
          'urls': {
            'wss:///ndt/v7/download':
                'wss://ndt-mlab1-xyz.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=abc',
            'wss:///ndt/v7/upload':
                'wss://ndt-mlab1-xyz.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=abc',
          },
        },
        {
          // Missing upload: skipped, never offered to the dialer.
          'machine': 'mlab2-broken',
          'location': {'city': 'Nowhere', 'country': 'XX'},
          'urls': {'wss:///ndt/v7/download': 'wss://x/download'},
        },
      ],
    };
    final servers = selectNdt7Servers(locate);
    expect(servers.length, 1);
    expect(servers.first.city, 'Lagos');
    expect(servers.first.label, 'Lagos, NG');
    expect(servers.first.downloadUrl, contains('access_token=abc'));
    expect(selectNdt7Servers(null), isEmpty);
    expect(selectNdt7Servers({'results': 'junk'}), isEmpty);
    expect(selectNdt7Servers({}), isEmpty);
  });

  test('ndt7 measurement parsing + throughput math', () {
    const msg =
        '{"TCPInfo": {"BytesReceived": 1000000, "ElapsedTime": 2000000, '
        '"MinRTT": 45000}, "Test": "upload"}';
    final m = parseNdt7Measurement(msg);
    expect(m, isNotNull);
    expect(m!.tcpBytes, 1000000);
    expect(m.tcpElapsedUs, 2000000);
    expect(m.minRttUs, 45000);
    // AppInfo / malformed text never parses.
    expect(parseNdt7Measurement('{"AppInfo": {}}'), isNull);
    expect(parseNdt7Measurement('not json'), isNull);
    expect(parseNdt7Measurement('{"TCPInfo": {"MinRTT": 1}}'), isNull);
    // Negative MinRTT (unknown) drops the sample, keeps the counters.
    final neg = parseNdt7Measurement(
      '{"TCPInfo": {"BytesReceived": 5, "ElapsedTime": 5, "MinRTT": -1}}',
    );
    expect(neg, isNotNull);
    expect(neg!.minRttUs, isNull);
    // Upload delta: 1 MB over the middle 8 s of socket life.
    const first = Ndt7ServerMeasurement(tcpBytes: 100, tcpElapsedUs: 1000000);
    const last = Ndt7ServerMeasurement(
      tcpBytes: 1000100,
      tcpElapsedUs: 9000000,
    );
    expect(ndt7UploadThroughputBps([first, last]), closeTo(125000, 0.5));
    expect(ndt7UploadThroughputBps([first]), 0);
    expect(ndt7UploadThroughputBps([]), 0);
    // Client goodput over the message window.
    expect(ndt7ClientThroughputBps(1000000, 0, 8000000), closeTo(125000, 0.5));
    expect(ndt7ClientThroughputBps(0, 0, 1), 0);
    expect(ndt7ClientThroughputBps(100, 5, 5), 0);
    // Jitter = mean absolute deviation from the median.
    expect(SpeedTestRunner.jitterOf([10, 10, 10, 10]), 0);
    expect(
      SpeedTestRunner.jitterOf([10.0, 12.0, 10.0, 14.0]),
      closeTo(1.5, 0.001),
    );
    expect(() => SpeedTestRunner.jitterOf([]), throwsArgumentError);
  });

  test('Speed history decode/add round-trips, caps at 100', () {
    expect(SpeedHistory.decode(null).records, isEmpty);
    expect(SpeedHistory.decode('garbage').records, isEmpty);
    expect(SpeedHistory.decode('{"a":1}').records, isEmpty);
    var h = const SpeedHistory();
    for (var i = 0; i < 105; i++) {
      h = h.added(
        SpeedRecord(
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          downMbps: i.toDouble(),
        ),
      );
    }
    expect(h.records.length, SpeedHistory.maxEntries);
    expect(h.records.first.downMbps, 104.0); // newest first
    final back = SpeedHistory.decode(h.encode());
    expect(back.records.length, SpeedHistory.maxEntries);
    expect(back.records.first.downMbps, 104.0);
    expect(back.records.first.at, DateTime(2026, 1, 1, 1, 44));
  });

  test('Smart alerts: ranks, degradation, fallback, outage, quiet', () {
    expect(networkRank('LTE'), 3);
    expect(networkRank('4G'), 3);
    expect(networkRank('WCDMA'), 2);
    expect(networkRank('HSPA+'), 2);
    expect(networkRank('EDGE'), 1);
    expect(networkRank('5G NR'), 4);
    expect(networkRank(''), -1);
    expect(networkRank('mystery'), -1);

    final settings = SmartAlertSettings.defaults();
    var now = DateTime(2026, 1, 1, 12, 0);
    DateTime step(int mins) => now = now.add(Duration(minutes: mins));

    // Placement degradation: baseline 4-5, then collapse to 1.
    final eng = SmartAlertEngine();
    for (var i = 0; i < 6; i++) {
      expect(
        eng.tick(
          reachable: true,
          bars: 4,
          networkType: 'LTE',
          settings: settings,
          now: step(1),
        ),
        isEmpty,
      );
    }
    final fired = eng.tick(
      reachable: true,
      bars: 1,
      networkType: 'LTE',
      settings: settings,
      now: step(1),
    );
    expect(
      fired.where((a) => a.id == SmartAlertId.placementDegraded).length,
      1,
    );
    expect(fired.first.body, contains('4/5'));
    // Same episode re-fires nothing (quiet period + streak latch).
    expect(
      eng.tick(
        reachable: true,
        bars: 1,
        networkType: 'LTE',
        settings: settings,
        now: step(1),
      ).where((a) => a.id == SmartAlertId.placementDegraded),
      isEmpty,
    );

    // Network fallback LTE -> WCDMA carries both names as evidence.
    final eng2 = SmartAlertEngine();
    eng2.tick(
      reachable: true,
      bars: 3,
      networkType: 'LTE',
      settings: settings,
      now: now,
    );
    final fb = eng2.tick(
      reachable: true,
      bars: 3,
      networkType: 'WCDMA',
      settings: settings,
      now: step(1),
    );
    expect(
      fb.where((a) => a.id == SmartAlertId.networkFallback).length,
      1,
    );
    expect(fb.first.body, contains('LTE'));
    expect(fb.first.body, contains('WCDMA'));

    // Repeated outage: 3 unreachable→recovery episodes in 30 min.
    final eng3 = SmartAlertEngine();
    List<SmartAlert> out = [];
    for (var i = 0; i < 3; i++) {
      eng3.tick(reachable: false, settings: settings, now: step(5));
      out = eng3.tick(
        reachable: true,
        bars: 3,
        networkType: 'LTE',
        settings: settings,
        now: step(1),
      );
    }
    expect(
      out.where((a) => a.id == SmartAlertId.repeatedOutage).length,
      1,
    );
    expect(out.first.body, contains('3×'));

    // Disabled alert never fires.
    final off = SmartAlertSettings(
      enabled: {for (final id in SmartAlertId.values) id: false},
      quietMinutes: 0,
    );
    final eng4 = SmartAlertEngine();
    for (var i = 0; i < 6; i++) {
      eng4.tick(
        reachable: true,
        bars: 4,
        networkType: 'LTE',
        settings: off,
        now: step(1),
      );
    }
    expect(
      eng4.tick(
        reachable: true,
        bars: 1,
        networkType: 'LTE',
        settings: off,
        now: step(1),
      ),
      isEmpty,
    );

    // History decode skips corrupt rows, never throws.
    expect(SmartAlertStore.decodeHistory(null), isEmpty);
    expect(SmartAlertStore.decodeHistory('junk'), isEmpty);
    final ok = SmartAlert(
      id: SmartAlertId.networkFallback,
      title: 't',
      body: 'b',
      at: now,
    );
    final back2 = SmartAlertStore.decodeHistory(
      '[{"id":"networkFallback","title":"t","body":"b",'
      '"at":"${now.toIso8601String()}"},{"id":"nope"}]',
    );
    expect(back2.length, 1);
    expect(back2.first.title, ok.title);
  });

  test('Device store: joins, two-miss leaves, names, decode', () {
    AttachedDevice dev(String mac, [String host = 'h']) => AttachedDevice(
      mac: mac,
      hostname: host,
      ip: '192.168.0.2',
    );
    final t0 = DateTime(2026, 1, 1, 12, 0);
    var m = const DeviceStore().merge(
      [dev('AA', 'laptop')],
      now: t0,
    );
    expect(m.events.length, 1);
    expect(m.events.first.joined, isTrue);
    expect(m.store.present().length, 1);

    // One missed snapshot: still present (flap grace), no event.
    m = m.store.merge([], now: t0.add(const Duration(minutes: 5)));
    expect(m.events, isEmpty);
    expect(m.store.present().length, 1);

    // Second miss: left event fires.
    m = m.store.merge([], now: t0.add(const Duration(minutes: 10)));
    expect(m.events.length, 1);
    expect(m.events.first.joined, isFalse);
    expect(m.store.present(), isEmpty);

    // Rename + star persist through copyWith and round-trip.
    final d = m.store.known['AA']!;
    final named = d.copyWith(customName: 'Work laptop', important: true);
    expect(named.displayName('laptop'), 'Work laptop');
    var store = m.store.withDevice(named);
    final back3 = DeviceStore.decode(jsonEncode(store.toJson()));
    expect(back3.known['AA']!.customName, 'Work laptop');
    expect(back3.known['AA']!.important, isTrue);
    expect(back3.events.length, 2); // join + leave preserved
    expect(DeviceStore.decode('junk').known, isEmpty);
    expect(DeviceStore.decode(null).events, isEmpty);
  });

  test('Monitor settings decode + drain math', () {
    expect(const MonitorSettings().mode, MonitorMode.desk);
    expect(monitorInterval(MonitorMode.travel), const Duration(seconds: 90));
    expect(monitorInterval(MonitorMode.desk), const Duration(seconds: 30));
    final d = MonitorSettings.decode('{"mode":"travel","lowBatteryPercent":15}');
    expect(d.mode, MonitorMode.travel);
    expect(d.lowBatteryPercent, 15);
    expect(MonitorSettings.decode('junk').lowBatteryPercent, 20);
    expect(
      MonitorSettings.decode('{"lowBatteryPercent":99}').lowBatteryPercent,
      20,
    );

    BatterySample s(int mins, int pct, [bool c = false]) => BatterySample(
      at: DateTime(2026, 1, 1, 12, 0).add(Duration(minutes: mins)),
      percent: pct,
      charging: c,
    );
    // 10% over 60 min unplugged → 10%/h.
    expect(drainPerHour([s(0, 80), s(30, 75), s(60, 70)]), closeTo(10, 0.01));
    // Charging samples never count.
    expect(drainPerHour([s(0, 80), s(60, 100, true)]), isNull);
    // Too thin (< 5 min span) → null, not a fake number.
    expect(drainPerHour([s(0, 80), s(2, 79)]), isNull);
    expect(drainPerHour([s(0, 80)]), isNull);
    expect(drainPerHour([]), isNull);
    // Ring caps at 60, oldest evicted.
    var ring = <BatterySample>[];
    for (var i = 0; i < 65; i++) {
      ring = BatterySamples.added(ring, s(i, 80));
    }
    expect(ring.length, BatterySamples.maxSamples);
    expect(BatterySamples.decode('junk'), isEmpty);
  });

  test('Incident report: summary, scrub, MAC masking', () {
    expect(maskMac('AA:BB:CC:DD:EE:FF'), '…EEFF');
    expect(maskMac('short'), '…????');
    final scrubbed = scrubSnapshot({
      'signalbar': '3',
      'imei': '12345',
      'SIM_IMSI': 'x',
      'network_type': 'LTE',
    });
    expect(scrubbed.containsKey('imei'), isFalse);
    expect(scrubbed.containsKey('SIM_IMSI'), isFalse);
    expect(scrubbed['signalbar'], '3');

    final input = IncidentInput(
      appVersion: '1.0.0+1',
      gatewayIp: '192.168.0.1',
      status: {'signalbar': '2', 'network_type': 'WCDMA', 'imei': 'leak?'},
      deviceEvents: [
        {
          'mac': 'AA:BB:CC:11:22:33',
          'name': 'laptop',
          'joined': false,
          'at': '2026-01-01T12:00:00',
        },
      ],
      unsupported: {'USSD_PROCESS': 'flag=41'},
    );
    final text = buildIncidentText(
      input,
      now: DateTime(2026, 1, 1, 12, 30),
    );
    expect(text, contains('Signal 2/5 on WCDMA'));
    expect(text, contains('…2233'));
    expect(text, isNot(contains('AA:BB:CC')));
    expect(text, isNot(contains('leak?')));
    expect(text, contains('USSD_PROCESS'));
    final json = buildIncidentJson(input, now: DateTime(2026, 1, 1, 12, 30));
    expect(json['summary'], contains('Signal 2/5'));
    expect((json['device_episodes'] as List).first['mac'], '…2233');
    expect((json['network'] as Map).containsKey('imei'), isFalse);
  });

  test('Advanced: best-time, schedules, discovery split', () {
    SpeedRecord rec(int hour, double down) => SpeedRecord(
      at: DateTime(2026, 1, 5, hour, 10),
      downMbps: down,
    );
    // Evenings win: two 18–20h samples beat a single noon spike.
    final best = bestTimeOfDay([
      rec(18, 20),
      rec(19, 24),
      rec(12, 60),
      rec(3, 5),
      rec(4, 6),
    ]);
    expect(best, isNotNull);
    expect(best!.hour, 18); // 18:00–20:00 bucket
    expect(best.avgDown, closeTo(22, 0.01));
    expect(best.count, 2);
    expect(bestTimeLabel(best), contains('18:00'));
    // Single-sample buckets never qualify.
    expect(bestTimeOfDay([rec(12, 60)]), isNull);
    expect(bestTimeOfDay([]), isNull);

    // Scheduled diag fires once per day at its hour.
    const diag = ScheduledDiag(enabled: true, hour: 7);
    expect(diag.dueAt(DateTime(2026, 1, 1, 7, 5)), isTrue);
    expect(diag.dueAt(DateTime(2026, 1, 1, 8, 0)), isFalse);
    const done = ScheduledDiag(
      enabled: true,
      hour: 7,
      lastRunDay: '2026-01-01',
    );
    expect(done.dueAt(DateTime(2026, 1, 1, 7, 30)), isFalse);
    expect(
      const ScheduledDiag(enabled: false, hour: 7).dueAt(
        DateTime(2026, 1, 1, 7, 0),
      ),
      isFalse,
    );
    expect(ScheduledDiag.dayKey(DateTime(2026, 3, 4, 5, 6)), '2026-03-04');

    // One-shot reboot: due from its time on, disarmed when empty.
    final rb = ScheduledReboot(at: DateTime(2026, 1, 1, 12, 0));
    expect(rb.dueAt(DateTime(2026, 1, 1, 11, 59)), isFalse);
    expect(rb.dueAt(DateTime(2026, 1, 1, 12, 1)), isTrue);
    expect(const ScheduledReboot().dueAt(DateTime(2026, 1, 1)), isFalse);
    expect(const ScheduledReboot().armed, isFalse);

    // Discovery split honors the probe list only.
    final split = splitDiscovery({'signalbar': '3', 'lte_rsrp': '-100'});
    expect(split.supported, containsAll(['signalbar', 'lte_rsrp']));
    expect(split.silent, contains('network_type'));
    expect(
      split.supported.length + split.silent.length,
      discoveryProbeKeys.length,
    );

    // Restore validation rejects garbage before touching prefs.
    expect(restoreBackup('not json'), throwsFormatException);
    expect(
      restoreBackup('{"app":"other","data":{}}'),
      throwsFormatException,
    );
  });

  test('Session recovery policy: hollow polls + polite retry cadence', () {
    // A logged-in poll carries firmware fields; a rebooted router answers
    // with nothing (or a lone result code).
    expect(
      looksAuthenticated({'battery_vol_percent': '82', 'network_type': 'LTE'}),
      isTrue,
    );
    expect(looksAuthenticated({'battery_vol_percent': '0'}), isTrue);
    expect(looksAuthenticated({}), isFalse);
    expect(looksAuthenticated({'result': '1'}), isFalse);
    expect(looksHollow({'network_type': ''}), isTrue);

    // Only *unreachable* failures keep the watchdog alive: retrying a
    // wrong password would burn the firmware's attempt budget.
    expect(const LoginResult.unreachable('connect timeout').reachable, isFalse);
    expect(shouldKeepWatching(const LoginResult.unreachable('timeout')), isTrue);
    expect(
      shouldKeepWatching(const LoginResult(false, 'Wrong password (result=3).')),
      isFalse,
    );
    expect(shouldKeepWatching(const LoginResult(true, 'ok')), isFalse);
    expect(const LoginResult(true, 'ok').reachable, isTrue);

    // First minutes retry fast (a rebooting MF935 is back quickly), then
    // settle so an off router is not hammered.
    expect(recoveryProbeDelay(1), const Duration(seconds: 5));
    expect(recoveryProbeDelay(6), const Duration(seconds: 5));
    expect(recoveryProbeDelay(7), const Duration(seconds: 15));
    expect(recoveryProbeDelay(99), const Duration(seconds: 15));
  });

  // ── USSD console: layout + menu-mode interactions ──────────────────

  Future<void> pumpUssd(WidgetTester tester, ZteClient client) async {
    tester.view.physicalSize = const Size(836, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildZteTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: UssdTab(client: client, connected: true, log: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('USSD keypad hugs its action row (no dead space)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpUssd(tester, ZteClient());

    final grid = tester.getRect(find.byKey(const Key('ussd-keypad')));
    final actions = tester.getRect(find.byKey(const Key('ussd-action-row')));
    // The action row is welded to the last key row (2dp spacer).
    expect(actions.top - grid.bottom, lessThan(8));
    // Four 58dp rows + the action row: the whole pad stays compact.
    expect(actions.bottom - grid.top, lessThan(320));
    // `* 0 #` sits in that last row, above the actions.
    final star = tester.getRect(find.text('*'));
    expect(star.bottom, lessThanOrEqualTo(actions.top + 1));
  });

  testWidgets('USSD entry field is glass, not the Material black fill', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpUssd(tester, ZteClient());
    final field = tester.widget<TextField>(
      find.byKey(const Key('ussd-code-field')),
    );
    // The app theme fills inputs opaque black; the dialer display opts
    // out and leans on its own translucent glass tile instead.
    expect(field.decoration?.filled, isFalse);
    expect(field.decoration?.hintText, contains('*312#'));
  });

  testWidgets('USSD keypad survives large system text scales', (tester) async {
    // Fixed key rows must track the system text size, otherwise every
    // key overflows its tile (10px per key at 1.6x before the fix).
    for (final scale in [1.3, 1.6, 2.0]) {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildZteTheme(brightness: Brightness.dark),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(
              ctx,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: UssdTab(client: ZteClient(), connected: true, log: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The keypad is clamped at 1.5x: it grows, but never past a size
      // that stops fitting the phone.
      final grid = tester.getRect(find.byKey(const Key('ussd-keypad')));
      expect(grid.height, lessThanOrEqualTo(58 * 1.5 * 4 + 1));
      expect(find.byKey(const Key('ussd-action-row')), findsOneWidget);
    }
  });

  testWidgets('USSD console survives a small phone and a desktop window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeUssdClient();
    // Small phone: menu mode must still fit without overflows (the test
    // framework fails on RenderFlex overflow exceptions).
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildZteTheme(brightness: Brightness.light),
        home: Scaffold(
          body: UssdTab(client: client, connected: true, log: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ussd-code-field')), '*312#');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.call));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ussd-code-field')), findsNothing);
    expect(find.byKey(const Key('ussd-reply-send')), findsOneWidget);

    // Wide desktop window: two-column layout stays intact.
    tester.view.physicalSize = const Size(2400, 1400);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ussd-keypad')), findsOneWidget);
    expect(find.textContaining('HISTORY'), findsOneWidget);
  });

  testWidgets('USSD menu mode: field yields, * and # answer, inline send', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeUssdClient();
    await pumpUssd(tester, client);

    await tester.enterText(find.byKey(const Key('ussd-code-field')), '*312#');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.call));
    await tester.pumpAndSettle();

    // Interactive menu: the primary entry field yields to the session
    // banner so multi-line menu text gets the height instead.
    expect(find.byKey(const Key('ussd-code-field')), findsNothing);
    expect(find.textContaining('MENU AWAITS REPLY'), findsOneWidget);
    // (The same text also lands in the history card below the console.)
    expect(
      find.descendant(
        of: find.byKey(const Key('ussd-response-box')),
        matching: find.textContaining('1 My Airtel Offer'),
      ),
      findsOneWidget,
    );
    final box = tester.getRect(find.byKey(const Key('ussd-response-box')));
    expect(box.height, lessThanOrEqualTo(232.5));

    // Navigation symbols are answer keys now, not dead keys.
    await tester.tap(find.text('*'));
    await tester.tap(find.text('#'));
    await tester.pump();
    expect(find.textContaining('Reply: *#'), findsOneWidget);

    // Inline Send submits without scrolling to the dial circle.
    await tester.tap(find.byKey(const Key('ussd-reply-send')));
    await tester.pumpAndSettle();
    expect(client.lastReply, '*#');
    expect(client.replyCalls, 1);
    // Second level arrived: still a menu, reply buffer cleared.
    expect(find.textContaining('MENU AWAITS REPLY'), findsOneWidget);
  });

  testWidgets('USSD saved strip + history scroll in bounded containers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ussd_saved': jsonEncode([
        for (var i = 0; i < 10; i++) {'code': '*93$i#', 'label': ''},
      ]),
      'ussd_history_v1': jsonEncode([
        for (var i = 0; i < 14; i++)
          {
            'request': '*312*$i#',
            'reply': 'reply $i line one\nline two',
            'ok': true,
            'at': 1700000000000,
          },
      ]),
    });
    await pumpUssd(tester, ZteClient());

    // Chips: one fixed-height row that scrolls sideways instead of
    // wrapping to a second row (the old container pushed the dialer down).
    final strip = tester.getRect(find.byKey(const Key('ussd-saved-strip')));
    expect(strip.height, lessThanOrEqualTo(34));
    expect(find.text('*930#'), findsOneWidget);
    final stripScroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('ussd-saved-strip')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(stripScroll.maxScrollExtent, greaterThan(0));

    // History: capped viewport that scrolls itself, page never grows.
    final list = tester.getRect(find.byKey(const Key('ussd-history-list')));
    expect(list.height, lessThanOrEqualTo(320));
    final listScroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('ussd-history-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(listScroll.maxScrollExtent, greaterThan(0));
  });

  testWidgets("USSD shows the modem's raw reply when repair had to guess", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeUssdClient();
    await pumpUssd(tester, client);
    await tester.enterText(find.byKey(const Key('ussd-code-field')), '*312#');
    await tester.tap(find.byIcon(Icons.call));
    await tester.pumpAndSettle();

    // The repaired text is what renders by default.
    expect(find.textContaining('1 My Airtel Offer'), findsWidgets);
    // Raw differs here, so the toggle is offered — and a clean reply
    // would not offer it.
    final toggle = find.byKey(const Key('ussd-raw-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // The untouched text is one cable-eaten line: no inserted breaks.
    final box = tester.widgetList<SelectableText>(find.byType(SelectableText));
    expect(
      box.map((w) => w.data ?? '').any((t) => t.contains('Offer\r2 Data')),
      isTrue,
      reason: 'raw view must show what the modem sent, unaltered',
    );

    // Copy is always available (evidence for a carrier chatbot).
    expect(find.byKey(const Key('ussd-copy-reply')), findsOneWidget);
  });

  testWidgets('USSD 0 key: long-press delivers the advertised +', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpUssd(tester, ZteClient());
    await tester.tap(find.text('0').last);
    await tester.pumpAndSettle();
    // The dialer echoes the typed digit, so target the keypad tile.
    await tester.longPress(find.text('0').last);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('ussd-code-field')),
    );
    expect(field.controller!.text, contains('+'));
    expect(field.controller!.text, contains('0'));
  });

  // ── Persisted session log + stale-data honesty ─────────────────────

  test('Session log persists across restarts and rotates oldest-first', () async {
    final backend = MemoryLogBackend();
    final store = LogStore(backend: backend, maxEvents: 3);
    store.append(
      LogKind.login,
      'LOGIN ok @ 192.168.0.1',
      at: DateTime(2026, 1, 2, 3, 4, 5),
    );
    store.append(
      LogKind.sessionLost,
      'status poll came back empty — session lost',
      at: DateTime(2026, 1, 2, 3, 5, 5),
    );
    // Newest first, and formatted locale-independently so a restored
    // log reads the same everywhere.
    expect(store.events.first.kind, LogKind.sessionLost);
    expect(
      formatLogLine(store.events.last),
      '03:04:05  LOGIN ok @ 192.168.0.1',
    );
    await store.flush();

    // Rotation: only the newest [maxEvents] survive a long session.
    for (var i = 0; i < 6; i++) {
      store.append(LogKind.info, 'poll $i', at: DateTime(2026, 1, 2, 4, i));
    }
    await store.flush();
    expect(store.events.length, 3);
    expect(store.events.first.message, 'poll 5');

    // Survives a restart — this is the whole point (a reboot incident
    // used to die with the window).
    final reopened = LogStore(backend: backend, maxEvents: 10);
    final loaded = await reopened.load();
    expect(loaded.length, 3);
    expect(loaded.first.message, 'poll 5');

    // Incident reports want events, not routine progress.
    expect(
      notableEvents(store.events).map((e) => e.kind),
      everyElement(isNot(LogKind.info)),
    );
    expect(store.exportText(), contains('[info]'));

    // A corrupt payload reads as empty — a broken log never blocks launch.
    SharedPreferences.setMockInitialValues({logPrefsKey: 'not json'});
    expect(await const PrefsLogBackend().load(), isEmpty);

    // Clearing wipes storage too, so it cannot resurrect on next launch.
    await store.clear();
    expect((await reopened.load()), isEmpty);
  });

  test('Stale data is labelled with its real age, never as live', () {
    final last = DateTime(2026, 1, 2, 14, 3);
    // No snapshot at all: nothing to label.
    expect(trustOf(sessionLive: false), DataTrust.unknown);
    expect(
      staleBannerText(sessionLive: false, lastAt: null),
      isEmpty,
    );
    // Live session: the poller owns the cadence, no banner.
    expect(trustOf(sessionLive: true, lastAt: last), DataTrust.live);
    expect(staleBannerText(sessionLive: true, lastAt: last), isEmpty);

    // Session gone: the numbers stay, but say how old they are.
    expect(
      trustOf(sessionLive: false, lastAt: last),
      DataTrust.cached,
    );
    expect(
      staleBannerText(
        sessionLive: false,
        lastAt: last,
        now: last.add(const Duration(seconds: 30)),
      ),
      contains('14:03'),
    );
    expect(
      staleBannerText(
        sessionLive: false,
        lastAt: last,
        now: last.add(const Duration(minutes: 42)),
      ),
      contains('42 min ago'),
    );
    expect(
      staleBannerText(
        sessionLive: false,
        lastAt: last,
        now: last.add(const Duration(hours: 3)),
      ),
      contains('3h ago'),
    );
  });

  testWidgets('Status tab dims and labels the last poll after session loss', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(980, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final at = DateTime.now().subtract(const Duration(minutes: 12));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildZteTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatusTab(
              client: ZteClient(),
              connected: false,
              status: {
                'battery_vol_percent': '81',
                'network_type': 'LTE',
                'signalbar': '4',
                'network_provider': 'MTN',
              },
              statusAt: at,
              log: (_) {},
              notify: (_, _) async {},
              onRefreshNow: () async {},
              balanceFeed: ValueNotifier<DataBalance?>(null),
              signalFeed: ValueNotifier<SignalSample?>(null),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final banner = find.byKey(const Key('status-stale-banner'));
    expect(banner, findsOneWidget);
    expect(
      find.textContaining('Session lost'),
      findsAtLeastNWidgets(1),
    );
    // The stamp names minutes, not a bare "stale".
    expect(find.textContaining('min ago'), findsOneWidget);
    // The readings are still there — dimmed, not deleted.
    expect(find.textContaining('LTE'), findsWidgets);
  });
}

/// USSD client double: no network, canned menu + reply answers.
class _FakeUssdClient extends ZteClient {
  int replyCalls = 0;
  String? lastReply;
  bool menuOpen = true;

  @override
  Future<void> cancelUssd() async {}

  @override
  Future<UssdResult> runUssd(
    String code, {
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async => const UssdResult(
    true,
    '1 My Airtel Offer\n2 Data Plans\n3 4GB @ N100',
    '1',
    '16',
    '',
    // Raw capture: the cable-eaten line breaks the sanitizer repairs.
    '1 My Airtel Offer\r2 Data Plans\r3 4GB @ N100',
  );

  @override
  Future<bool> replyUssd(String text) async {
    replyCalls++;
    lastReply = text;
    return true;
  }

  @override
  Future<UssdResult> waitUssdReply({
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async => menuOpen
      ? const UssdResult(
          true,
          '9 8GB @N250\n* Next',
          '1',
          '16',
          '',
          '9 8GB @N250\n* Next',
        )
      : const UssdResult(
          true,
          'Purchase successful.',
          '',
          '16',
          '',
          'Purchase successful.',
        );
}
