library;

/// Shared data shapes for the MF935 companion (SSOT).
///
/// Extracted from the former `zte_client.dart` god file: pure data, no Dio,
/// no Flutter. `zte_client.dart` re-exports this file so existing
/// `import 'zte_client.dart'` call sites keep working unchanged.

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
  List<SmsMessage> msgs,
) {
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

  /// When the station joined the WiFi (firmware `ctime` seconds). Null
  /// when the modem doesn't report it — displayed only when present.
  final DateTime? connectedAt;

  const AttachedDevice({
    required this.mac,
    required this.hostname,
    required this.ip,
    this.connectedAt,
  });
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

  /// Out of quota: unexpired but empty. Shown dimmed + last, never
  /// drives the countdown or alerts.
  bool get exhausted => mb <= 0;

  /// Days until expiry (negative = expired). Null when unknown.
  int? get daysLeft => expiry?.difference(DateTime.now()).inDays;

  Map<String, dynamic> toJson() => {
    'name': name,
    'mb': mb,
    'expiry': expiry?.toIso8601String(),
  };

  factory DataBundle.fromJson(Map<String, dynamic> j) => DataBundle(
    name: '${j['name'] ?? ''}',
    mb: (j['mb'] as num?)?.toDouble() ?? 0,
    expiry: j['expiry'] == null ? null : DateTime.tryParse('${j['expiry']}'),
  );
}

/// Persisted data-balance snapshot: survives SMS deletion, app restarts,
/// anything. Refreshed by dialing *323*1# (see [ZteClient.fetchDataBalance]).
class DataBalance {
  final List<DataBundle> bundles;
  final String raw;
  final DateTime fetchedAt;

  const DataBalance({
    required this.bundles,
    required this.raw,
    required this.fetchedAt,
  });

  double get totalMb => bundles.fold(0, (a, b) => a + b.mb);

  /// Soonest-dated LIVE bundle still in the future (the one that
  /// matters). Exhausted bundles never qualify, even unexpired.
  DataBundle? get nextExpiry {
    final live = bundles.where((b) => !b.exhausted && b.expiry != null).toList()
      ..sort((a, b) => a.expiry!.compareTo(b.expiry!));
    if (live.isEmpty) return null;
    final now = DateTime.now();
    return live.firstWhere(
      (b) => b.expiry!.isAfter(now),
      orElse: () => live.last,
    );
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
                .map((e) => DataBundle.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : [],
      raw: '${j['raw'] ?? ''}',
      fetchedAt:
          DateTime.tryParse('${j['fetchedAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
