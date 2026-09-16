library;

/// Phase 0 stability baseline: modem capability matrix (SSOT).
///
/// Purpose: know which goform commands the firmware actually supports,
/// mark rejected ones once, and never spam them again. Pure Dart, fully
/// unit-tested — no Dio, no Flutter.
enum CapabilityKind {
  /// Safe GET polling (status, device info, traffic, SMS list).
  readOnly,

  /// POST that normally works (LOGIN, SEND_SMS, DELETE_SMS, REBOOT…).
  writable,

  /// Works on some firmwares, rejected on others
  /// (USSD_PROCESS, SET_AUTO_POWER_SAVE). Mark unsupported on first
  /// hard rejection instead of retrying forever.
  firmwareDependent,
}

/// One known modem command.
class ModemCommand {
  final String id;
  final CapabilityKind kind;
  final String label;
  final String nextAction;

  const ModemCommand({
    required this.id,
    required this.kind,
    required this.label,
    this.nextAction = '',
  });
}

/// Known command table. Unknown ids default to [CapabilityKind.writable]
/// (honest: we tried it, the modem decides).
const knownCommands = <String, ModemCommand>{
  'LOGIN': ModemCommand(
    id: 'LOGIN',
    kind: CapabilityKind.writable,
    label: 'Login',
    nextAction: 'Check password / lockout counters, then retry after cooldown.',
  ),
  'USSD_PROCESS': ModemCommand(
    id: 'USSD_PROCESS',
    kind: CapabilityKind.firmwareDependent,
    label: 'USSD send/reply/cancel',
    nextAction: 'If flag=41/99, the carrier or firmware blocks USSD — stop retrying.',
  ),
  'SEND_SMS': ModemCommand(
    id: 'SEND_SMS',
    kind: CapabilityKind.writable,
    label: 'Send SMS',
    nextAction: 'Check signal + SMS center number, then retry once.',
  ),
  'DELETE_SMS': ModemCommand(
    id: 'DELETE_SMS',
    kind: CapabilityKind.writable,
    label: 'Delete SMS',
    nextAction: 'Reload the inbox; the row may already be gone.',
  ),
  'SET_MSG_READ': ModemCommand(
    id: 'SET_MSG_READ',
    kind: CapabilityKind.writable,
    label: 'Mark SMS read',
    nextAction: 'Reload the inbox before retrying.',
  ),
  'SET_MESSAGE_CENTER': ModemCommand(
    id: 'SET_MESSAGE_CENTER',
    kind: CapabilityKind.writable,
    label: 'SMS settings save',
    nextAction: 'Reload settings; some firmwares ignore this silently.',
  ),
  'SET_AUTO_POWER_SAVE': ModemCommand(
    id: 'SET_AUTO_POWER_SAVE',
    kind: CapabilityKind.firmwareDependent,
    label: 'Power-save mode',
    nextAction: 'This firmware may not support it — leave the current mode.',
  ),
  'SET_WIFI_COVERAGE': ModemCommand(
    id: 'SET_WIFI_COVERAGE',
    kind: CapabilityKind.firmwareDependent,
    label: 'Wi-Fi coverage mode',
    nextAction: 'This firmware may not support it — keep the current mode.',
  ),
  'SET_WIFI_SLEEP': ModemCommand(
    id: 'SET_WIFI_SLEEP',
    kind: CapabilityKind.firmwareDependent,
    label: 'Wi-Fi sleep timer',
    nextAction: 'This firmware may not support it — keep the current timer.',
  ),
  'REBOOT_DEVICE': ModemCommand(
    id: 'REBOOT_DEVICE',
    kind: CapabilityKind.writable,
    label: 'Reboot modem',
    nextAction: 'WiFi drops ~1 min; a transport error usually MEANS it worked.',
  ),
  'SHUTDOWN_DEVICE': ModemCommand(
    id: 'SHUTDOWN_DEVICE',
    kind: CapabilityKind.writable,
    label: 'Shutdown modem',
    nextAction: 'Power the MiFi on physically afterwards.',
  ),
  'RESET_DATA_COUNTER': ModemCommand(
    id: 'RESET_DATA_COUNTER',
    kind: CapabilityKind.writable,
    label: 'Reset data counter',
    nextAction: 'Reload stats; carrier bill is unaffected.',
  ),
};

/// Tracks firmware rejections at runtime. Mark once, skip retries after.
class CapabilityRegistry {
  final Map<String, String> _unsupported = {};

  /// `goformId -> reason` for every command the modem has refused.
  Map<String, String> get unsupported => Map.unmodifiable(_unsupported);

  bool isUnsupported(String goformId) => _unsupported.containsKey(goformId);

  String? reasonFor(String goformId) => _unsupported[goformId];

  /// Returns true when this is a NEW entry (caller should log/notify).
  bool markUnsupported(String goformId, String reason) {
    if (_unsupported.containsKey(goformId)) return false;
    _unsupported[goformId] = reason;
    return true;
  }

  void clear() => _unsupported.clear();
}

/// Rich failure message: modem result + command + next action.
/// Replaces every generic "refused" string (Phase 0 guardrail).
String formatCommandFailure({
  required String command,
  required String result,
  String raw = '',
  String next = '',
}) {
  final known = knownCommands[command];
  final action = next.isNotEmpty
      ? next
      : (known?.nextAction ?? 'Check connection, then retry once.');
  final buf = StringBuffer()
    ..write('Modem rejected $command (result=$result).')
    ..write(' Next: $action');
  if (raw.isNotEmpty) buf.write(' Raw: $raw');
  return buf.toString();
}
