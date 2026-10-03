library;

/// "Data path" card: three rungs — gateway, DNS, HTTPS — so a dead
/// connection is localised instead of guessed at. Sits on the Status tab
/// under the tools that measure.
///
/// The probe runs once automatically when a session comes up (so the
/// first thing a user sees when the internet is broken is *where* it is
/// broken) and on demand after that. It never runs on a timer: this is a
/// diagnostic, not a poll.
import 'package:flutter/material.dart';

import '../core/reachability.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

class InternetCheckCard extends StatefulWidget {
  final bool connected;

  /// Injectable so tests and previews never touch the network.
  final InternetProbe probe;

  /// Fired with every completed probe (the connection timeline records it).
  final void Function(ProbeResult result)? onResult;

  final void Function(String) log;

  const InternetCheckCard({
    super.key,
    required this.connected,
    required this.probe,
    required this.log,
    this.onResult,
  });

  @override
  State<InternetCheckCard> createState() => _InternetCheckCardState();
}

class _InternetCheckCardState extends State<InternetCheckCard> {
  ProbeResult? _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.connected) _run();
  }

  @override
  void didUpdateWidget(InternetCheckCard old) {
    super.didUpdateWidget(old);
    // One probe per session: reconnecting is exactly when the answer
    // changes, and repeating it every rebuild would be noise.
    if (widget.connected && !old.connected) _run();
  }

  Future<void> _run() async {
    if (_busy || !widget.connected) return;
    setState(() => _busy = true);
    try {
      final r = await widget.probe.run(gatewayOk: widget.connected);
      if (!mounted) return;
      final v = r.info;
      setState(() => _result = r);
      widget.log('data path: ${v.headline.toLowerCase()}');
      widget.onResult?.call(r);
    } catch (e) {
      widget.log('data path probe failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final r = _result;
    final v = r?.info;
    final ok = v?.verdict == InternetVerdict.ok;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SectionLabel('Data path'),
              const Spacer(),
              if (_busy)
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(c.accentText),
                  ),
                )
              else
                InkWell(
                  key: const Key('data-path-test'),
                  onTap: widget.connected ? _run : null,
                  child: Text(
                    widget.connected ? 'test' : 'offline',
                    style: TextStyle(
                      color: widget.connected ? c.textMuted : c.textMuted
                          .withAlpha(90),
                      fontSize: 11.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // The ladder: each rung is a separate fact, so a failure can be
          // pointed at instead of summarised away.
          Row(
            children: [
              _rung(c, 'Router', r?.gatewayOk ?? widget.connected),
              const SizedBox(width: 8),
              _rung(c, 'DNS', r?.dnsOk),
              const SizedBox(width: 8),
              _rung(c, 'HTTPS', r?.httpsOk),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            v == null
                ? 'Checking whether traffic gets past the modem…'
                : v.headline,
            style: TextStyle(
              color: v == null ? c.textMuted : (ok ? c.live : c.danger),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            v == null
                ? 'Reachable is not the same as online — this test asks both.'
                : v.detail,
            style: TextStyle(color: c.textMuted, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// One rung of the ladder. Unknown rungs (never tested) read grey,
  /// never green: an untested fact must not look like a passing one.
  Widget _rung(ZteColors c, String label, bool? ok) {
    final color = ok == null
        ? c.textMuted.withAlpha(90)
        : (ok ? c.live : c.danger);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: ok == null ? c.borderSubtle : color.withAlpha(90),
          ),
        ),
        child: Column(
          children: [
            Icon(
              ok == null
                  ? Icons.remove
                  : (ok ? Icons.check : Icons.close),
              size: 14,
              color: color,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(color: c.textSecondary, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}