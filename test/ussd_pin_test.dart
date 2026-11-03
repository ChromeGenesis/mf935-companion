import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zte_mf935_app/core/ussd_steps.dart';
import 'package:zte_mf935_app/features/ussd_saved.dart';

UssdHistoryEntry _entry({String request = '*939#', String reply = 'ok'}) =>
    UssdHistoryEntry(
      request: request,
      reply: reply,
      ok: true,
      at: DateTime(2026, 1, 1),
    );

void main() {
  group('PIN detection', () {
    test('spot the prompt phrasings', () {
      expect(
        UssdShortcut.isPinPrompt(
          'Enter PIN to BUY Smartcash AWOOF Data 6.5GB @ N1000',
        ),
        isTrue,
      );
      expect(
        UssdShortcut.isPinPrompt('Please enter your PIN to continue'),
        isTrue,
      );
      expect(UssdShortcut.isPinPrompt('Type PIN to confirm'), isTrue);
      expect(
        UssdShortcut.isPinPrompt('Transaction Successful. Thank you.'),
        isFalse,
      );
      expect(
        UssdShortcut.isPinPrompt('Dial *939*0# to confirm your cash back'),
        isFalse,
      );
      expect(UssdShortcut.isPinPrompt('No service (ussd_no_service).'),
          isFalse);
    });

    test('PIN-shaped answers only', () {
      expect(UssdShortcut.looksLikePin('1234'), isTrue);
      expect(UssdShortcut.looksLikePin('123456'), isTrue);
      expect(UssdShortcut.looksLikePin(' 5678 '), isTrue);
      expect(UssdShortcut.looksLikePin('3'), isFalse,
          reason: 'single menu digits are answers, not PINs');
      expect(UssdShortcut.looksLikePin(''), isFalse);
      expect(UssdShortcut.looksLikePin('12a4'), isFalse);
      expect(UssdShortcut.looksLikePin('1234567'), isFalse);
    });

    test('saved flows never print a PIN', () {
      expect(
        UssdShortcut('*939#', ['1234']).safeFlowLabel,
        '*939# → ••••',
      );
      expect(
        UssdShortcut('*312#', ['3', '1']).safeFlowLabel,
        '*312# → 3 → 1',
      );
    });
  });

  group('history scrubbing', () {
    test('prompts are dropped, typed PINs dotted out', () {
      expect(
        scrubPinEntry(
          _entry(reply: 'Enter PIN to BUY data'),
          pinExpected: true,
        ),
        isNull,
      );
      final redacted = scrubPinEntry(
        _entry(request: '↳ 1234', reply: 'Processing…'),
        pinExpected: true,
      );
      expect(redacted, isNotNull);
      expect(redacted!.request, '↳ ••••');
      expect(redacted.reply, 'Processing…');
      // Single-digit menu answers pass through untouched.
      final menu = scrubPinEntry(
        _entry(request: '↳ 3', reply: 'Pick a bundle'),
        pinExpected: true,
      );
      expect(menu!.request, '↳ 3');
      // Nothing PIN-like, nothing expected: untouched.
      final plain = scrubPinEntry(
        _entry(request: '*312#', reply: 'Balance is 5GB'),
        pinExpected: false,
      );
      expect(plain!.request, '*312#');
    });
  });

  group('saved PIN prefs', () {
    test('round-trips, rejects junk, forgets', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadSavedPin(), isNull);
      await saveSavedPin('4321');
      expect(await loadSavedPin(), '4321');
      await clearSavedPin();
      expect(await loadSavedPin(), isNull);
    });

    test('invalid stored values read as none', () async {
      SharedPreferences.setMockInitialValues({'ussd_saved_pin': '12'});
      expect(await loadSavedPin(), isNull);
    });
  });
}
