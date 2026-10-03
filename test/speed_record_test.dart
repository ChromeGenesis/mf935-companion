import 'package:flutter_test/flutter_test.dart';
import 'package:zte_mf935_app/core/speed_history.dart';

void main() {
  test('Speed records keep their label and start/end signal', () {
    final at = DateTime(2026, 1, 2, 20, 15);
    final record = SpeedRecord(
      at: DateTime.fromMillisecondsSinceEpoch(0),
      downMbps: 12.5,
      rsrpStart: -86,
      rsrpEnd: -92,
      netStart: 'LTE',
    );

    // JSON round-trip keeps the comparison evidence.
    final back = SpeedRecord.fromJson({
      ...record.toJson(),
      'at': at.toIso8601String(),
      'label': 'bedroom window',
    });
    expect(back.label, 'bedroom window');
    expect(back.rsrpStart, -86);
    expect(back.rsrpEnd, -92);
    expect(back.netStart, 'LTE');
    expect(back.hasSignal, isTrue);

    // A run that got worse mid-test says so; a steady one reads cleanly.
    expect(record.signalLine, contains('-86 → -92'));
    expect(
      SpeedRecord(
        at: DateTime.fromMillisecondsSinceEpoch(0),
        rsrpStart: -86,
        rsrpEnd: -86,
      ).signalLine,
      contains('-86 dBm'),
      reason: 'no arrow when nothing changed',
    );

    // Renaming is non-destructive.
    final renamed = record.withLabel('before the antenna move');
    expect(renamed.label, 'before the antenna move');
    expect(renamed.rsrpStart, record.rsrpStart);
    expect(renamed.downMbps, record.downMbps);

    // No signal captured -> nothing claimed.
    final bare = SpeedRecord(at: DateTime.fromMillisecondsSinceEpoch(0));
    expect(bare.hasSignal, isFalse);
    expect(bare.signalLine, isEmpty);
  });
}