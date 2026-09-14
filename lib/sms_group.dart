import 'package:flutter/material.dart';

import 'theme.dart';
import 'zte_client.dart';

/// One sender group in the inbox: tri-state header (counts, read-all,
/// delete-all), capped message rows, swipe-to-delete.
///
/// Stateless by design — the tab owns selection/expansion state (SSOT);
/// this widget only renders + forwards intents.
class SenderGroup extends StatelessWidget {
  /// Max rows per sender before the "show all" expander kicks in — one
  /// chatty sender must never fill the whole screen.
  static const groupCap = 4;

  final String sender;
  final List<SmsMessage> msgs;
  final bool collapsed;
  final bool showAll;
  final bool selecting;
  final Set<String> selected;
  final bool busy;

  final VoidCallback onToggleCollapse;
  final VoidCallback onToggleShowAll;
  final ValueChanged<String> onToggleSelect;
  final VoidCallback onToggleGroupPick;
  final ValueChanged<SmsMessage> onOpen;
  final ValueChanged<String> onEnterSelect;
  final VoidCallback onSelectGroup;
  final VoidCallback onMarkGroupRead;
  final VoidCallback onDeleteGroup;
  final ValueChanged<SmsMessage> onSwipeDelete;

  const SenderGroup({
    super.key,
    required this.sender,
    required this.msgs,
    required this.collapsed,
    required this.showAll,
    required this.selecting,
    required this.selected,
    required this.busy,
    required this.onToggleCollapse,
    required this.onToggleShowAll,
    required this.onToggleSelect,
    required this.onToggleGroupPick,
    required this.onOpen,
    required this.onEnterSelect,
    required this.onSelectGroup,
    required this.onMarkGroupRead,
    required this.onDeleteGroup,
    required this.onSwipeDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    // Newest first within the group (modem returns id-desc already).
    final visible = showAll ? msgs : msgs.take(groupCap).toList();
    final hidden = msgs.length - visible.length;
    final ids = msgs.map((m) => m.id).toSet();
    final picked = ids.intersection(selected).length;
    final allPicked = picked == ids.length && ids.isNotEmpty;
    final unread = msgs.where((m) => m.isNew).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggleCollapse,
          onLongPress: onSelectGroup,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Checkbox(
                    // Tri-state: all / some / none.
                    value: allPicked ? true : (picked > 0 ? null : false),
                    tristate: true,
                    visualDensity: VisualDensity.compact,
                    fillColor: WidgetStatePropertyAll(c.accent),
                    onChanged: (_) => onToggleGroupPick(),
                  ),
                ),
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                  color: c.textMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          sender,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${msgs.length}',
                        style: TextStyle(color: c.textMuted, fontSize: 12),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: c.accent.withAlpha(40),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '$unread new',
                            style: TextStyle(
                              color: c.accentText,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Per-group quick actions: read + nuke the sender.
                IconButton(
                  tooltip: 'Mark $sender read',
                  visualDensity: VisualDensity.compact,
                  onPressed: busy ? null : onMarkGroupRead,
                  icon: Icon(Icons.done_all, color: c.textMuted, size: 18),
                ),
                IconButton(
                  tooltip: 'Delete all from $sender',
                  visualDensity: VisualDensity.compact,
                  onPressed: busy ? null : onDeleteGroup,
                  icon: Icon(Icons.delete_outline, color: c.danger, size: 18),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          ...visible.map((m) {
            final pickedRow = selected.contains(m.id);
            final row = InkWell(
              onTap: () => selecting ? onToggleSelect(m.id) : onOpen(m),
              onLongPress: () => onEnterSelect(m.id),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 34,
                  top: 5,
                  bottom: 5,
                  right: 2,
                ),
                child: Row(
                  children: [
                    if (selecting)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: pickedRow,
                            visualDensity: VisualDensity.compact,
                            fillColor:
                                WidgetStatePropertyAll(c.accent),
                            onChanged: (_) => onToggleSelect(m.id),
                          ),
                        ),
                      )
                    else if (m.isNew)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: c.accentText,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        m.content.replaceAll('\n', ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: pickedRow ? c.textPrimary : c.textSecondary,
                          fontWeight: m.isNew && !pickedRow
                              ? FontWeight.w600
                              : FontWeight.w400,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      m.displayDate,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            );
            return Dismissible(
              key: ValueKey('sms-${m.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(
                  color: c.danger.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.delete_outline, color: c.danger, size: 20),
              ),
              onDismissed: (_) => onSwipeDelete(m),
              child: row,
            );
          }),
        // Overflow expander: capped groups never hog the screen.
        if (!collapsed && (hidden > 0 || showAll))
          InkWell(
            onTap: onToggleShowAll,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.only(left: 34, top: 4, bottom: 6),
              child: Text(
                showAll ? 'Show less' : 'Show all ${msgs.length} from $sender',
                style: TextStyle(
                  color: c.accentText,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
