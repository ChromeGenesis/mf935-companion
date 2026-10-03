library;

/// Network Scout card: find a better spot for the MiFi by measuring,
/// not guessing. The user starts sampling, walks the router around,
/// marks named spots, and gets a ranked verdict with a reason.
///
/// Lives on the Status tab under the speed test: Scout is a measurement
/// tool, and the tools that measure share a home. All scoring lives in
/// `core/network_scout.dart`; this file only owns the session state and
/// the presentation.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dialogs.dart';
import '../core/network_scout.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_client.dart';

/// Sampling loop + ranked results for [NetworkScoutCard].
class NetworkScoutCard extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;

  const NetworkScoutCard({
    super.key,
    required this.client,
    required this.connected,
    required this.log,
  });

  @override
  State<NetworkScoutCard> createState() => _NetworkScoutCardState();
}

class _NetworkScoutCardState extends State<NetworkScoutCard> {
  final _store = ScoutStore();

  /// Marked spots, newest first (the same order they persist in).
  List<ScoutSession> _sessions = [];

  /// The spot currently collecting samples. Non-null while sampling or
  /// paused — it exists between "Mark spot" and "End spot".
  ScoutSession? _active;

  Timer? _timer;
  bool _sampling = false;

  /// A sample is in flight: the loop must never stack requests (the
  /// firmware serves one goform caller at a time).
  bool _inFlight = false;

  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _persist();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final loaded = await _store.load();
      if (!mounted) return;
      setState(() {
        _sessions = loaded;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  Future<void> _persist() async {
    try {
      await _store.save(_sessions);
    } catch (_) {
      // Persistence is a convenience here; never fail the session over it.
    }
  }

  // ── Sampling loop ─────────────────────────────────────────────────

  void _toggleSampling() {
    if (_sampling) {
      _timer?.cancel();
      _timer = null;
      setState(() => _sampling = false);
      widget.log('scout sampling paused');
      return;
    }
    if (!widget.connected) {
      widget.log('scout needs a live session — log in first');
      return;
    }
    setState(() => _sampling = true);
    widget.log(
      'scout sampling started '
      '(${scoutDefaultInterval.inSeconds}s cadence)',
    );
    unawaited(_sample());
    _timer = Timer.periodic(scoutDefaultInterval, (_) => unawaited(_sample()));
  }

  /// One sample into the active spot. A spot with no name yet collects
  /// into a temporary "Scouting" session so the user can start moving
  /// the router before they commit to a label.
  Future<void> _sample() async {
    if (_inFlight || !mounted) return;
    _inFlight = true;
    try {
      final status = await widget.client.getStatus(
        cmds: const [
          'signalbar',
          'network_type',
          'lte_rsrp',
          'lte_rsrq',
          'lte_sinr',
          'rssi',
          'realtime_rx_thrpt',
          'realtime_tx_thrpt',
        ],
      );
      if (!mounted) return;
      final sample = scoutSampleFromStatus(status, DateTime.now());
      setState(() {
        final active = _active;
        if (active == null) return;
        active.samples.add(sample);
      });
    } catch (e) {
      // An unreachable poll still belongs to the record: it is exactly
      // the evidence that a spot is dead.
      if (mounted) {
        setState(() => _active?.samples.add(
          ScoutSample(at: DateTime.now(), reachable: false),
        ));
      }
    } finally {
      _inFlight = false;
    }
  }

  /// Start (or rename) a spot and begin sampling it.
  void _markSpot() {
    if (!widget.connected) {
      widget.log('scout needs a live session — log in first');
      return;
    }
    setState(() {
      _active = ScoutSession(
        id: ScoutStore.newId(),
        label: '',
        startedAt: DateTime.now(),
      );
      _sampling = true;
    });
    _timer?.cancel();
    _timer = Timer.periodic(
      scoutDefaultInterval,
      (_) => unawaited(_sample()),
    );
    unawaited(_sample());
  }

  /// Finish the active spot, persist it, and prompt for its name.
  Future<void> _endSpot() async {
    final active = _active;
    if (active == null) return;
    _timer?.cancel();
    _timer = null;
    setState(() {
      _sampling = false;
      _active = null;
      _sessions = [active.copyWith(finished: true), ..._sessions];
    });
    await _persist();
    widget.log(
      'scout spot marked: ${active.sampleCount} samples over '
      '${active.duration.inSeconds}s',
    );
    if (mounted) await _labelSpot(active.id);
  }

  /// Name a spot. Free text with one-tap suggestions — a numbered spot
  /// would be worthless in a report.
  Future<void> _labelSpot(String id) async {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session == null || !mounted) return;
    final ctrl = TextEditingController(text: session.label);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: GlassModal(
            icon: Icons.place_outlined,
            title: 'Name this spot',
            subtitle: '${session.sampleCount} samples over '
                '${session.duration.inSeconds}s — where was the MiFi?',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('scout-label-field'),
                  controller: ctrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Spot name',
                    hintText: 'e.g. Upstairs window',
                    isDense: true,
                  ),
                  onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in scoutSpotSuggestions)
                      ActionChip(
                        label: Text(name, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(ctx).pop(name),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(ctrl.text.trim()),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    ctrl.dispose();
    if (label == null || !mounted) return;
    setState(() {
      _sessions = [
        for (final s in _sessions)
          if (s.id == id) s.copyWith(label: label) else s,
      ];
    });
    await _persist();
    widget.log('scout spot labelled: $label');
  }

  Future<void> _clearAll() async {
    final ok = await confirmAction(
      context,
      icon: Icons.delete_outline,
      title: 'Clear Scout results?',
      message: '${_sessions.length} measured spot'
          '${_sessions.length == 1 ? '' : 's'} will be deleted from this '
          'device. Export first if you want the evidence.',
      confirmLabel: 'Clear',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _sessions = []);
    await _persist();
    widget.log('scout results cleared');
  }

  Future<void> _export() async {
    final text = buildScoutReport(_sessions);
    await Clipboard.setData(ClipboardData(text: text));
    widget.log('scout report copied (${text.length} chars)');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Scout report copied')));
  }

  // ── Presentation ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final ranked = rankSpots(_sessions);
    final best = ranked.isEmpty ? null : ranked.first;
    final live = _active == null
        ? null
        : scoreSpot(_active!.copyWith(samples: List.of(_active!.samples)));

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SectionLabel('Network Scout'),
              const Spacer(),
              if (_sessions.isNotEmpty)
                InkWell(
                  onTap: _clearAll,
                  child: Text(
                    'clear',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!widget.connected)
            Text(
              'Log in to sample the radio. Scout needs a live session.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            )
          else ...[
            // Live status strip: what is being measured, right now.
            Row(
              children: [
                Expanded(
                  child: Text(
                    _active == null
                        ? _sampling
                              ? 'Sampling — mark a spot to start recording'
                              : 'Idle — mark a spot where the MiFi is now'
                        : 'Recording · ${_active!.sampleCount} samples · '
                              '${_active!.duration.inSeconds}s',
                    maxLines: 2,
                    style: TextStyle(color: c.textSecondary, fontSize: 12),
                  ),
                ),
                if (live != null)
                  Text(
                    live.overall.toStringAsFixed(0),
                    style: TextStyle(
                      color: c.accentText,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_active == null) ...[
                  OutlinedButton.icon(
                    key: const Key('scout-mark-spot'),
                    onPressed: _markSpot,
                    icon: const Icon(Icons.place_outlined, size: 16),
                    label: const Text('Mark spot'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('scout-toggle-sampling'),
                    onPressed: _toggleSampling,
                    icon: Icon(
                      _sampling
                          ? Icons.pause
                          : Icons.play_arrow_outlined,
                      size: 16,
                    ),
                    label: Text(_sampling ? 'Pause' : 'Sample'),
                  ),
                ] else
                  FilledButton.icon(
                    key: const Key('scout-end-spot'),
                    onPressed: _endSpot,
                    icon: const Icon(Icons.flag, size: 16),
                    label: const Text('End spot'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_ready)
              Text(
                'Loading saved spots…',
                style: TextStyle(color: c.textMuted, fontSize: 12),
              )
            else if (ranked.isEmpty)
              Text(
                'No spots measured yet. Put the MiFi somewhere, press '
                'Mark spot, wait ~30 seconds, then end it.',
                style: TextStyle(color: c.textMuted, fontSize: 12),
              )
            else ...[
              Row(
                children: [
                  Icon(Icons.emoji_events_outlined, size: 15, color: c.accentText),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Best: ${_spotName(best!.session)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    best.score.reason == null
                        ? ''
                        : '(${best.score.reason})',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final r in ranked)
                _spotTile(c, r, isBest: identical(r, best)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.ios_share, size: 15),
                  label: const Text('Export report', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _spotName(ScoutSession s) => s.label.trim().isEmpty ? 'unnamed spot' : s.label.trim();

  /// One ranked spot: score bar, min/max/avg metrics, confidence and the
  /// reason it placed where it did.
  Widget _spotTile(ZteColors c, RankedSpot r, {required bool isBest}) {
    final thin = !r.session.hasDwell;
    return InkWell(
      onTap: () => _labelSpot(r.session.id),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isBest ? c.accent.withAlpha(120) : c.borderSubtle,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _spotName(r.session),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: thin ? c.textMuted : c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  r.score.overall.toStringAsFixed(0),
                  style: TextStyle(
                    color: thin ? c.textMuted : c.accentText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            // Score bar (0..100), so the ranking is comparable at a glance.
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (r.score.overall / 100).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: c.borderSubtle,
                valueColor: AlwaysStoppedAnimation<Color>(
                  thin ? c.textMuted : c.accent,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'RSRP ${r.rsrp.format()} dBm · bars ${r.bars.format(decimals: 1)}',
              style: TextStyle(color: c.textMuted, fontSize: 10.5),
            ),
            Text(
              'down ${r.down.format(decimals: 2)} · '
              'up ${r.up.format(decimals: 2)} Mbps',
              style: TextStyle(color: c.textMuted, fontSize: 10.5),
            ),
            Text(
              '${confidenceLabel(r.session)}'
              '${thin ? ' · not dwelled long enough to rank' : ''}',
              style: TextStyle(
                color: thin ? c.danger : c.textMuted,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}