library;

/// Connection timeline card (Settings): the answer to "what happened to
/// the connection while I wasn't watching".
///
/// Filterable by severity and kind, every entry expandable to its
/// supporting values, exportable as text, and clearable. It reads the
/// events the dashboard records — this widget owns no state beyond the
/// active filters.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/conn_timeline.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

class TimelineCard extends StatefulWidget {
  final List<ConnEvent> events;
  final VoidCallback onClear;

  const TimelineCard({
    super.key,
    required this.events,
    required this.onClear,
  });

  @override
  State<TimelineCard> createState() => _TimelineCardState();
}

class _TimelineCardState extends State<TimelineCard> {
  /// null = no severity floor. Default 'problems only' is the view most
  /// people want; the full history is one tap away.
  EventSeverity? _minSeverity = EventSeverity.warn;
  final Set<ConnEventKind> _kinds = {};

  Future<void> _export() async {
    final text = _exportText(_rendered());
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Timeline copied to clipboard')),
    );
  }

  /// Plain text for the currently filtered view — what the user sees is
  /// what they copy.
  static String _exportText(List<ConnEvent> events) {
    final buf = StringBuffer()
      ..writeln('=== connection timeline (${events.length} events) ===');
    for (final e in events) {
      final stamp = e.at.toIso8601String().substring(0, 19).replaceAll('T', ' ');
      buf.writeln('$stamp  [${e.severity.name}] ${e.kind.name}: ${e.summary}');
      for (final entry in e.data.entries) {
        buf.writeln('        ${entry.key}=${entry.value}');
      }
    }
    return buf.toString();
  }

  List<ConnEvent> _rendered() => filterEvents(
    widget.events,
    kinds: _kinds,
    minSeverity: _minSeverity,
  );

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final shown = _rendered();
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Expanded: the title must ellipsize rather than push the
              // actions out of a narrow column (Settings is a 2-up grid).
              const Expanded(child: SectionLabel('Connection timeline')),
              const SizedBox(width: 8),
              if (widget.events.isNotEmpty) ...[
                InkWell(
                  onTap: _export,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      'copy',
                      style: TextStyle(color: c.textMuted, fontSize: 11.5),
                    ),
                  ),
                ),
                InkWell(
                  onTap: widget.onClear,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      'clear',
                      style: TextStyle(color: c.textMuted, fontSize: 11.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Severity floor + kind chips: the filters are the feature, so
          // they sit above the list rather than in a menu.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final sev in EventSeverity.values)
                _chip(
                  c,
                  label: sev.name,
                  active: _minSeverity == sev,
                  onTap: () => setState(
                    () => _minSeverity = _minSeverity == sev ? null : sev,
                  ),
                ),
              for (final kind in const [
                ConnEventKind.sessionLost,
                ConnEventKind.unreachable,
                ConnEventKind.internetDown,
                ConnEventKind.networkTypeChanged,
                ConnEventKind.reboot,
              ])
                _chip(
                  c,
                  label: kind.name,
                  active: _kinds.contains(kind),
                  onTap: () => setState(() {
                    if (!_kinds.remove(kind)) _kinds.add(kind);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.events.isEmpty)
            Text(
              'Nothing recorded yet. Logins, session losses, outages, '
              'network-type changes and internet verdicts land here and '
              'survive restarts.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            )
          else if (shown.isEmpty)
            Text(
              'No events match these filters.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            )
          else
            ConstrainedBox(
              // Bounded: a month of history must not stretch the tab.
              constraints: const BoxConstraints(maxHeight: 320),
              child: Scrollbar(
                child: ListView.builder(
                  key: const Key('timeline-list'),
                  shrinkWrap: true,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _eventTile(c, shown[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    ZteColors c, {
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: active ? c.accent.withAlpha(40) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? c.accent.withAlpha(140) : c.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? c.accentText : c.textMuted,
            fontSize: 10.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// One entry: time, severity dot, kind + summary. Tapping expands the
  /// supporting values — an assertion you cannot inspect is not evidence.
  Widget _eventTile(ZteColors c, ConnEvent e) {
    final color = switch (e.severity) {
      EventSeverity.critical => c.danger,
      EventSeverity.warn => c.accent,
      EventSeverity.info => c.textMuted,
    };
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: Key('timeline-${e.kind.name}-${e.at.millisecondsSinceEpoch}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6, left: 16),
        visualDensity: const VisualDensity(vertical: -3),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.circle, size: 8, color: color),
        title: Text(
          e.summary,
          style: TextStyle(color: c.textPrimary, fontSize: 12),
        ),
        subtitle: Text(
          '${e.at.toIso8601String().substring(11, 16)} · ${e.kind.name}'
          '${e.data.isEmpty ? '' : ' · ${e.data.length} values'}',
          style: TextStyle(color: c.textMuted, fontSize: 10.5),
        ),
        children: [
          if (e.data.isEmpty)
            Text(
              'No supporting values recorded for this event.',
              style: TextStyle(color: c.textMuted, fontSize: 11),
            )
          else
            for (final entry in e.data.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${entry.key}: ${entry.value}',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
        ],
      ),
    );
  }
}