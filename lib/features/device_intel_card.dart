library;

/// Device-intelligence card (SSOT): friendly names, first/last seen,
/// connection spans, important-device stars, join/leave history.
/// Self-contained: loads/saves [DeviceStore] from prefs and fetches
/// stations itself, so the dashboard never plumbs it.
///
/// Honest limit, stated in the UI: per-client traffic is not shown —
/// this firmware exposes no trustworthy per-station counters.
import 'package:flutter/material.dart';

import '../core/device_store.dart';
import '../core/dialogs.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';
import '../core/zte_client.dart';

class DeviceIntelCard extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String line) log;
  final Future<void> Function(String title, String body) notify;

  const DeviceIntelCard({
    super.key,
    required this.client,
    required this.connected,
    required this.log,
    required this.notify,
  });

  @override
  State<DeviceIntelCard> createState() => _DeviceIntelCardState();
}

class _DeviceIntelCardState extends State<DeviceIntelCard> {
  DeviceStore _store = const DeviceStore();
  bool _busy = false;
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(DeviceIntelCard old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _refresh();
  }

  Future<void> _init() async {
    try {
      _store = await DeviceStore.load();
    } catch (_) {
      _store = const DeviceStore();
    }
    if (mounted) {
      setState(() {});
      if (widget.connected) _refresh();
    }
  }

  Future<void> _refresh() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final stations = await widget.client.getConnectedDevices();
      final merged = _store.merge(stations);
      _store = merged.store;
      await _store.save();
      for (final e in merged.events.where((e) => !e.joined)) {
        final dev = _store.known[e.mac];
        if (dev != null && dev.important) {
          widget.log('important device left: ${e.name}');
          await widget.notify(
            'MiFi device left',
            '${e.name} disconnected from the MiFi.',
          );
        }
      }
      if (merged.events.isNotEmpty) {
        widget.log(
          'devices: ${merged.events.map((e) => '${e.joined ? 'joined' : 'left'} ${e.name}').join(', ')}',
        );
      }
    } catch (e) {
      widget.log('device intel refresh failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(KnownDevice d) async {
    final name = await showGlassModal<String>(
      context,
      icon: Icons.edit_outlined,
      title: 'Name this device',
      subtitle: d.mac,
      body: _RenameForm(initial: d.customName, hint: d.lastHostname),
    );
    if (name == null || !mounted) return;
    setState(() {
      _store = _store.withDevice(d.copyWith(customName: name.trim()));
    });
    await _store.save();
    widget.log('device renamed: ${d.mac} → "${name.trim()}"');
  }

  Future<void> _toggleImportant(KnownDevice d) async {
    setState(() {
      _store = _store.withDevice(d.copyWith(important: !d.important));
    });
    await _store.save();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final present = _store.present()
      ..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
    final absent = _store.gone()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withAlpha(90)),
                ),
                child: Icon(
                  Icons.hub_outlined,
                  size: 17,
                  color: c.accentText,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SectionLabel('Device intel')),
              Text(
                '${present.length} here',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              IconButton(
                tooltip: 'Refresh stations',
                onPressed: !widget.connected || _busy ? null : _refresh,
                icon: _busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.accentText,
                        ),
                      )
                    : Icon(Icons.refresh, color: c.accentText, size: 19),
              ),
            ],
          ),
          Text(
            'Names + stars live on this device only. Per-client traffic '
            'is not shown — the firmware reports no trustworthy counters.',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (present.isEmpty && absent.isEmpty)
            Text(
              widget.connected
                  ? 'No stations seen yet — refresh to scan.'
                  : 'Connect the MiFi to track stations.',
              style: TextStyle(color: c.textMuted, fontSize: 12.5),
            )
          else ...[
            for (final d in [...present, ...absent.take(5)])
              _deviceRow(context, c, d, d.missStreak <= 1),
            const SizedBox(height: 4),
            InkWell(
              onTap: _store.events.isEmpty
                  ? null
                  : () => setState(() => _showHistory = !_showHistory),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      _showHistory
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _store.events.isEmpty
                          ? 'No join/leave history yet'
                          : '${_store.events.length} join/leave events',
                      style: TextStyle(color: c.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ),
            if (_showHistory)
              for (final e in _store.events.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        e.joined
                            ? Icons.login_outlined
                            : Icons.logout_outlined,
                        size: 13,
                        color: e.joined ? c.accentText : c.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${e.joined ? 'Joined' : 'Left'}: ${e.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      Text(
                        timeAgo(e.at),
                        style: TextStyle(color: c.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }

  Widget _deviceRow(
    BuildContext context,
    ZteColors c,
    KnownDevice d,
    bool here,
  ) {
    final title = d.customName.isEmpty ? d.lastHostname : d.customName;
    final sub = [
      if (d.lastIp.isNotEmpty) d.lastIp,
      if (d.mac.isNotEmpty) d.mac,
      'first ${timeAgo(d.firstSeen)}',
      here ? 'span ${_spanLabel(d.span)}' : 'left ${timeAgo(d.lastSeen)}',
    ].join(' · ');
    return Opacity(
      opacity: here ? 1 : 0.62,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: here ? c.accentText : c.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title.isEmpty ? 'unknown' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (d.customName.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          d.lastHostname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 10.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: d.important ? 'Unmark important' : 'Mark important',
              visualDensity: VisualDensity.compact,
              onPressed: () => _toggleImportant(d),
              icon: Icon(
                d.important ? Icons.star : Icons.star_outline,
                size: 17,
                color: d.important ? c.accentText : c.textMuted,
              ),
            ),
            IconButton(
              tooltip: 'Rename',
              visualDensity: VisualDensity.compact,
              onPressed: () => _rename(d),
              icon: Icon(Icons.edit_outlined, size: 15, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

String _spanLabel(Duration d) {
  if (d.inMinutes < 1) return 'just arrived';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

/// Rename dialog body: returns the trimmed name (empty = clear).
class _RenameForm extends StatefulWidget {
  final String initial;
  final String hint;

  const _RenameForm({required this.initial, required this.hint});

  @override
  State<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends State<_RenameForm> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: 24,
          decoration: InputDecoration(
            hintText: widget.hint.isEmpty ? 'e.g. Work laptop' : widget.hint,
            isDense: true,
          ),
          onSubmitted: (_) => Navigator.of(context).pop(_ctrl.text.trim()),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(''),
                child: const Text('Clear'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).pop(_ctrl.text.trim()),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
