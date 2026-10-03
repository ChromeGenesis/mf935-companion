import 'package:flutter_test/flutter_test.dart';
import 'package:zte_mf935_app/core/ussd_steps.dart';
import 'package:zte_mf935_app/core/zte_client.dart';
import 'package:zte_mf935_app/features/ussd_saved.dart';

/// Menu double: opens with a menu, then answers N steps and finally goes
/// terminal (or keeps asking, for the exhaustion case).
class _MenuClient extends ZteClient {
  _MenuClient(this.menu, this.replies);

  final String menu;
  final List<String> replies;

  /// Set when the network keeps asking after the scripted steps.
  bool neverFinishes = false;

  bool rejectAt = false;
  final List<String> answers = [];

  @override
  Future<void> cancelUssd() async {}

  @override
  Future<UssdResult> runUssd(
    String code, {
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async => UssdResult(true, menu, '1', '16', '');

  @override
  Future<bool> replyUssd(String text) async {
    answers.add(text);
    if (rejectAt && answers.length == 1) return false;
    return true;
  }

  @override
  Future<UssdResult> waitUssdReply({
    Duration pollEvery = const Duration(seconds: 1),
    int maxPolls = 45,
  }) async {
    final i = answers.length - 1;
    final text = i < replies.length ? replies[i] : 'Done.';
    // The menu keeps asking until the scripted replies run out.
    final stillAsking = neverFinishes || answers.length < replies.length;
    return UssdResult(true, text, stillAsking ? '1' : '', '16', '');
  }
}

void main() {
  test('Shortcut steps parse from free text, bounded and gap-free', () {
    expect(UssdShortcut.parseSteps('3, 1'), ['3', '1']);
    expect(UssdShortcut.parseSteps('  3 ,1  '), ['3', '1']);
    expect(UssdShortcut.parseSteps('1 2 3'), ['1', '2', '3']);
    expect(UssdShortcut.parseSteps(''), isEmpty);
    // Blank entries are dropped, never dialled as an empty answer.
    expect(UssdShortcut.parseSteps('3,, ,1'), ['3', '1']);
    expect(UssdShortcut.parseSteps('1 2 3 4 5 6 7 8').length, 6);
    expect(
      UssdShortcut.stepsToField(['3', '1']),
      '3, 1',
    );
  });

  test('A scripted shortcut walks the menu and stops when it closes', () async {
    final client = _MenuClient('1 Balance\n2 Data', ['Select plan', 'Done.']);
    final run = await runUssdShortcut(
      client,
      UssdShortcut('*312#', ['3', '1']),
    );
    expect(client.answers, ['3', '1']);
    expect(run.stepsSent, 2);
    expect(run.stop, UssdStop.completed);
    expect(run.needsManualReply, isFalse);
    expect(run.finalReply.text, 'Done.');
  });

  test('A shortcut never types into a menu that stopped asking', () async {
    // The modem goes terminal after the first answer, so the scripted
    // second step must NOT be sent into whatever is on screen now.
    final client = _MenuClient('1 Balance', ['Closed.']);
    final run = await runUssdShortcut(
      client,
      UssdShortcut('*312#', ['3', '1']),
    );
    expect(client.answers, ['3']);
    expect(run.stop, UssdStop.completed);
    expect(run.needsManualReply, isFalse);
  });

  test('An exhausted step list says the menu is still open', () async {
    final client = _MenuClient('1 Balance', ['Still asking'])
      ..neverFinishes = true;
    final run = await runUssdShortcut(client, UssdShortcut('*312#', ['3']));
    expect(run.stop, UssdStop.stepsExhausted);
    expect(run.needsManualReply, isTrue);
    expect(describeUssdRun(UssdShortcut('*312#', ['3']), run),
        contains('still open'));
  });

  test('A rejected answer stops the run and names the reason', () async {
    final client = _MenuClient('1 Balance', [])..rejectAt = true;
    final run = await runUssdShortcut(client, UssdShortcut('*312#', ['3']));
    expect(run.stop, UssdStop.rejected);
    expect(describeUssdRun(UssdShortcut('*312#'), run),
        contains('stopped'));
  });

  test('Saved shortcuts keep their steps through JSON and auto-remember', () {
    final saved = UssdSaved(code: '*312#', label: 'My plan', steps: const ['3', '1']);
    final back = UssdSaved.fromJson(saved.toJson());
    expect(back.steps, ['3', '1']);
    expect(back.isMultiStep, isTrue);
    expect(saved.shortcut.flowLabel, '*312# \u2192 3 \u2192 1');

    // Auto-remembering a sent code must not wipe the script the user wrote.
    final remembered = rememberUssdCode([saved], '*312#');
    expect(remembered.first.steps, ['3', '1']);
    // A plain shortcut stays plain.
    expect(UssdSaved(code: '*100#').isMultiStep, isFalse);
  });
}