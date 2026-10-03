import 'package:flutter_test/flutter_test.dart';
import 'package:zte_mf935_app/core/network_scout.dart';

void main() {
  test('Scout sample parsing never invents a metric', () {
    final s = scoutSampleFromStatus(
      {
        'signalbar': '4',
        'network_type': 'LTE',
        'lte_rsrp': '-86',
        'lte_rsrq': '-11',
        'realtime_rx_thrpt': '12000000',
        'realtime_tx_thrpt': '4000000',
      },
      DateTime(2026, 1, 2),
    );
    expect(s.bars, 4);
    expect(s.rsrp, -86);
    expect(s.rsrq, -11);
    expect(s.sinr, isNull);
    // The firmware reports bytes/s; Scout converts to Mbps so a 12 MB/s link
// is not scored like a 12 Mbps one.
    expect(s.downMbps, closeTo(96, 0.001));
    expect(s.upMbps, closeTo(32, 0.001));
    expect(s.reachable, isTrue);
  });

  test('Scout scoring: stats, stability, confidence and ranking', () {
    final t0 = DateTime(2026, 1, 2, 12);
    ScoutSession spot(String label, {double rsrp = -86, double swing = 0}) {
      return ScoutSession(
        id: label,
        label: label,
        startedAt: t0,
        samples: [
          for (var i = 0; i < 10; i++)
            ScoutSample(
              at: t0.add(Duration(seconds: 5 * i)),
              bars: 4,
              rsrp: (rsrp + swing * (i.isEven ? 1 : -1)).round(),
              networkType: 'LTE',
              downMbps: 20,
              upMbps: 5,
            ),
        ],
      );
    }

    final stable = spot('Window', rsrp: -80);
    final volatile = spot('Basement', rsrp: -95, swing: 12);

    // Stability separates two spots even though bars are identical.
    final s1 = scoreSpot(stable);
    final s2 = scoreSpot(volatile);
    expect(s1.stability!, greaterThan(s2.stability!));
    expect(s1.overall, greaterThan(s2.overall));

    // A spot that never answered cannot score well on reachability.
    final dead = ScoutSession(
      id: 'dead',
      label: 'dead',
      startedAt: t0,
      samples: [
        for (var i = 0; i < 6; i++)
          ScoutSample(at: t0.add(Duration(seconds: 5 * i)), reachable: false),
      ],
    );
    expect(scoreSpot(dead).reachability, 0);

    // Ranking puts the better spot first and says why.
    final ranked = rankSpots([volatile, stable]);
    expect(ranked.first.session.label, 'Window');
    expect(ranked.first.score.reason, isNotNull);
    expect(ranked.last.score.reason, isNull);
  });

  test('Scout sessions persist and cap', () async {
    final backend = MemoryScoutBackend();
    final store = ScoutStore(backend: backend);
    final sessions = [
      for (var i = 0; i < 25; i++)
        ScoutSession(
          id: '$i',
          label: 'spot $i',
          startedAt: DateTime(2026, 1, 2),
          samples: [
            ScoutSample(
              at: DateTime(2026, 1, 2, 0, 0, i),
              bars: 3,
              rsrp: -90,
            ),
          ],
        ),
    ];
    await store.save(sessions);
    expect(backend.sessions.length, 20);
  });

  test('Scout confidence is low below the dwell floor', () {
    final t0 = DateTime(2026, 1, 2, 12);
    final quick = ScoutSession(
      id: 'q',
      label: 'q',
      startedAt: t0,
      samples: [
        ScoutSample(at: t0, rsrp: -80),
        ScoutSample(at: t0.add(const Duration(seconds: 1)), rsrp: -80),
      ],
    );
    expect(confidenceFor(quick), ScoutConfidence.low);
    final long = ScoutSession(
      id: 'l',
      label: 'l',
      startedAt: t0,
      samples: [
        for (var i = 0; i < 30; i++)
          ScoutSample(at: t0.add(Duration(seconds: i * 3)), rsrp: -80),
      ],
    );
    expect(confidenceFor(long), ScoutConfidence.high);
    expect(confidenceLabel(long), contains('high'));
  });

  test('Scout export names the best location', () {
    final t0 = DateTime(2026, 1, 2, 12);
    ScoutSession mk(String id, double rsrp) => ScoutSession(
      id: id,
      label: id,
      startedAt: t0,
      samples: [
        for (var i = 0; i < 10; i++)
          ScoutSample(
            at: t0.add(Duration(seconds: 5 * i)),
            bars: 4,
            rsrp: rsrp.round(),
          ),
      ],
    );
    final report = buildScoutReport([mk('Basement', -105), mk('Window', -78)]);
    expect(report, contains('Best location: Window'));
    expect(encodeScoutJson([mk('Window', -78)]), contains('Window'));
  });
}
