import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:zte_mf935_app/main.dart';
import 'package:zte_mf935_app/core/widgets.dart';
import 'package:zte_mf935_app/core/zte_client.dart';

void main() {
  testWidgets('Dashboard renders login form', (WidgetTester tester) async {
    // App enforces a 980x700 minimum window — render at supported size.
    tester.view.physicalSize = const Size(980, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ZteApp());

    expect(find.text('MF935 Companion'), findsWidgets);
    expect(find.text('Login & poll'), findsOneWidget);
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

  test('Countdown formatter', () {
    expect(
      formatCountdown(
        const Duration(days: 13, hours: 4, minutes: 12, seconds: 33),
      ),
      '13d 04:12:33',
    );
    expect(formatCountdown(const Duration(hours: 5)), '05:00:00');
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
}
