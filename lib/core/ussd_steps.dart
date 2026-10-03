library;

/// Multi-step USSD shortcuts (SSOT): running a carrier menu as one
/// deliberate action instead of four remembered taps.
///
/// `*312#` → `3` → `1` is the classic case — a balance check or a bundle
/// toggle buried two levels deep in an interactive menu. Today that means
/// dialing the code, reading the menu, typing an option, reading again,
/// typing again, while the session times out if you look away.
///
/// The shortcut stores the code *and* the steps, and [runUssdShortcut]
/// walks them. Deliberate constraints:
///
///  - it is never fire-and-forget: the caller drives it step by step so
///    the UI can show every intermediate menu (a scripted sequence that
///    guessed wrong must be visibly wrong, not silently destructive);
///  - it stops the moment the modem stops asking: once a reply no longer
///    needs an answer, the remaining steps are dropped rather than typed
///    into whatever screen happens to be open;
///  - every stop has a reason, and "the menu is still open" is reported
///    as such instead of pretending the shortcut succeeded.
import 'zte_client.dart';

/// Hard ceiling on scripted steps. Real menus are shallow; anything
/// longer is a loop the network is inviting.
const maxUssdShortcutSteps = 6;

/// Why a scripted shortcut stopped. Every exit names itself — a shortcut
/// that reports "done" when the menu is still open is worse than none.
enum UssdStop {
  /// The last reply was terminal: the shortcut completed.
  completed,

  /// The modem refused the answer (session expired, wrong option).
  rejected,

  /// All scripted steps were used and the menu is still asking.
  stepsExhausted,

  /// A send or poll threw.
  error,
}

/// One executed step: the answer that was typed and the reply it drew.
class UssdStepResult {
  final int index;
  final String answer;
  final UssdResult reply;

  const UssdStepResult(this.index, this.answer, this.reply);
}

/// Everything a run produced: the opening reply, each step, and why it
/// stopped.
class UssdRunResult {
  final UssdResult opening;
  final List<UssdStepResult> steps;
  final UssdStop stop;
  final String? message;

  const UssdRunResult({
    required this.opening,
    required this.steps,
    required this.stop,
    this.message,
  });

  /// The reply the user should be looking at: the deepest one reached.
  UssdResult get finalReply =>
      steps.isEmpty ? opening : steps.last.reply;

  /// The menu is still waiting for an answer — the shortcut did not
  /// finish and manual input is required.
  bool get needsManualReply =>
      stop != UssdStop.completed && finalReply.needsReply;

  int get stepsSent => steps.length;
}

/// A saved shortcut: the code plus the menu answers to feed it.
class UssdShortcut {
  final String code;
  final List<String> steps;

  UssdShortcut(this.code, [List<String>? steps])
    : steps = List.unmodifiable(steps ?? const []);

  bool get isMultiStep => steps.isNotEmpty;

  /// `*312# → 3 → 1` — how the chip and the confirmation sheet read.
  String get flowLabel =>
      [code.trim(), ...steps.map((s) => s.trim())].join(' \u2192 ');

  Map<String, dynamic> toJson() => {
    'code': code,
    if (steps.isNotEmpty) 'steps': steps,
  };

  factory UssdShortcut.fromJson(Map<String, dynamic> j) => UssdShortcut(
    '${j['code'] ?? ''}',
    (j['steps'] as List?)?.map((e) => '$e').toList(),
  );

  /// Parse a user-typed step list ("3, 1" or "3 1"). Empty entries are
  /// dropped rather than dialled as a blank answer. Pure + tested.
  static List<String> parseSteps(String text) => text
      .split(RegExp(r'[,\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .take(maxUssdShortcutSteps)
      .toList();

  /// Flattened persistence form.
  static String stepsToField(List<String> steps) => steps.join(', ');
}

/// Walk a scripted shortcut against a live session.
///
/// [onStep] is called after every answered step so the caller can render
/// the intermediate menu as it arrives; returning `false` from
/// [shouldContinue] aborts the run and reports [UssdStop.rejected] with
/// the caller's message. Pure orchestration: all transport decisions stay
/// in [ZteClient].
Future<UssdRunResult> runUssdShortcut(
  ZteClient client,
  UssdShortcut shortcut, {
  void Function(UssdStepResult step)? onStep,
  bool Function(UssdStepResult step)? shouldContinue,
}) async {
  UssdResult opening;
  try {
    await client.cancelUssd();
  } catch (_) {
    // Best-effort clear of a stale session, exactly like a manual dial.
  }
  try {
    opening = await client.runUssd(shortcut.code);
  } catch (e) {
    return UssdRunResult(
      opening: const UssdResult(false, '', '', '', 'Send failed'),
      steps: const [],
      stop: UssdStop.error,
      message: '$e',
    );
  }
  if (!opening.success) {
    return UssdRunResult(
      opening: opening,
      steps: const [],
      stop: UssdStop.rejected,
      message: opening.error,
    );
  }

  final steps = <UssdStepResult>[];
  var reply = opening;
  var stop = UssdStop.completed;
  String? message;

  for (var i = 0; i < shortcut.steps.length; i++) {
    if (!reply.needsReply) break; // terminal reply: nothing left to answer
    final answer = shortcut.steps[i].trim();
    if (answer.isEmpty) continue;
    bool accepted;
    UssdResult next;
    try {
      accepted = await client.replyUssd(answer);
      next = accepted
          ? await client.waitUssdReply()
          : const UssdResult(
              false,
              '',
              '',
              '',
              'The menu did not accept this answer.',
            );
    } catch (e) {
      accepted = false;
      next = const UssdResult(false, '', '', '', 'Session error');
      message = '$e';
    }
    final step = UssdStepResult(i + 1, answer, next);
    steps.add(step);
    onStep?.call(step);
    reply = next;
    if (!accepted) {
      stop = UssdStop.rejected;
      message ??= next.error;
      break;
    }
    if (!next.success) {
      stop = UssdStop.rejected;
      message ??= next.error;
      break;
    }
    if (shouldContinue != null && !shouldContinue(step)) {
      stop = UssdStop.rejected;
      message = 'Stopped by you';
      break;
    }
  }
  // Steps ran out but the menu is still asking: say so rather than
  // declaring victory.
  if (stop == UssdStop.completed && reply.needsReply) {
    stop = UssdStop.stepsExhausted;
    message = 'The menu is still open — answer the rest by hand.';
  }
  return UssdRunResult(
    opening: opening,
    steps: steps,
    stop: stop,
    message: message,
  );
}

/// One-line summary of a run for the log. Pure + tested.
String describeUssdRun(UssdShortcut shortcut, UssdRunResult run) {
  final outcome = switch (run.stop) {
    UssdStop.completed => 'completed',
    UssdStop.rejected => 'stopped (${run.message ?? 'rejected'})',
    UssdStop.stepsExhausted => 'still open after ${run.stepsSent} step(s)',
    UssdStop.error => 'failed (${run.message ?? 'error'})',
  };
  return 'USSD ${shortcut.flowLabel}: $outcome';
}