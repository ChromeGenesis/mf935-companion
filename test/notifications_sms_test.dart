import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zte_mf935_app/core/models.dart';
import 'package:zte_mf935_app/core/notifications.dart';
import 'package:zte_mf935_app/core/poller.dart';

SmsMessage _msg({
  required String id,
  String number = '',
  String content = '',
  bool isNew = true,
}) => SmsMessage(
  id: id,
  number: number,
  content: content,
  tag: isNew ? '1' : '0',
  date: '',
  draftGroupId: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OTP extraction', () {
    test('finds verification codes, ignores USSD and long numbers', () {
      expect(
        extractOtp('Your verification code is 482910. Do not share it.'),
        '482910',
      );
      expect(extractOtp('Use 1234 to confirm your login'), '1234');
      expect(extractOtp('Your OTP is 77 88 99'), isNull,
          reason: 'spaced groups are not one code');
      // A dial string must never read as a code.
      expect(extractOtp('*939*77*5#'), isNull);
      expect(extractOtp('Dial *323*1# for balance'), isNull);
      // Long numbers without code words are not codes.
      expect(extractOtp('Call 08031234567 now'), isNull);
      expect(extractOtp('Hello there'), isNull);
      expect(extractOtp('Your code is 12'), isNull,
          reason: 'too short');
      expect(extractOtp('Your code is 123456789'), isNull,
          reason: 'too long');
    });

    test('payload round-trips the code', () {
      expect(otpPayload('482910'), 'otp:482910');
    });
  });

  group('fresh SMS selection', () {
    test('only new, unseen, identified messages pass', () {
      final inbox = [
        _msg(id: '1', content: 'a'),
        _msg(id: '2', isNew: false),
        _msg(id: '', content: 'no id'),
        _msg(id: '3', content: 'c'),
      ];
      final fresh = ZtePoller.freshSms(inbox, {'1'});
      expect(fresh.map((m) => m.id), ['3']);
    });

    test('empty inbox and empty seen set', () {
      expect(ZtePoller.freshSms(const [], {}), isEmpty);
      expect(
        ZtePoller.freshSms([_msg(id: '9')], const {}).map((m) => m.id),
        ['9'],
      );
    });
  });

  group('copy action', () {
    test('copies just the code, ignores body taps', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await notificationResponseHandler(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          id: 7,
          actionId: 'copy_otp',
          payload: 'otp:482910',
        ),
      );
      final sets = calls.where((c) => c.method == 'Clipboard.setData');
      expect(sets, hasLength(1));
      expect((sets.single.arguments as Map)['text'], '482910');

      // A body tap carries the same payload but no action: no copy.
      calls.clear();
      await notificationResponseHandler(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          id: 7,
          payload: 'otp:482910',
        ),
      );
      expect(
        calls.where((c) => c.method == 'Clipboard.setData'),
        isEmpty,
      );
    });
  });
}
