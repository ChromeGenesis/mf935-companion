import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zte_mf935_app/main.dart';
import 'package:zte_mf935_app/core/device_store.dart';
import 'package:zte_mf935_app/core/monitor_modes.dart';
import 'package:zte_mf935_app/core/ndt7_client.dart';
import 'package:zte_mf935_app/core/signal_locator.dart';
import 'package:zte_mf935_app/core/smart_alerts.dart';
import 'package:zte_mf935_app/core/speed_history.dart';
import 'package:zte_mf935_app/core/speed_test.dart';
import 'package:zte_mf935_app/core/widgets.dart';
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
}
