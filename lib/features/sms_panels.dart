library;

/// SMS-tab presentation (SSOT): inbox header, message list, compose card
/// and SMS-center settings. Stateless — [SmsTab] owns selection, filters
/// and modem calls; this module only renders + forwards intents.
/// The per-sender row lives in `sms_group.dart`.
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

/// Inbox header: title + global actions, store switcher, search,
/// bulk bar. The message list below is separate so desktop can give
/// it the full left height with its own scroll.
class SmsInboxHeader extends StatelessWidget {
  final int selectedCount;
  final int unreadTotal;
  final int store;
  final bool busy;
  final String capLine;
  final TextEditingController searchCtrl;
  final String search;
  final bool bulkVisible;
  final VoidCallback? onMarkAllRead;
  final VoidCallback? onRefresh;
  final ValueChanged<int> onStoreChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;
  final VoidCallback? onMarkReadSelected;
  final VoidCallback? onBulkDelete;

  const SmsInboxHeader({
    super.key,
    required this.selectedCount,
    required this.unreadTotal,
    required this.store,
    required this.busy,
    required this.capLine,
    required this.searchCtrl,
    required this.search,
    required this.bulkVisible,
    this.onMarkAllRead,
    this.onRefresh,
    required this.onStoreChanged,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSelectAll,
    required this.onSelectNone,
    this.onMarkReadSelected,
    this.onBulkDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SectionLabel('Inbox'),
            if (selectedCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '$selectedCount picked',
                  style: TextStyle(
                    color: c.accentText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else if (unreadTotal > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '$unreadTotal unread',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ),
            const Spacer(),
            IconButton(
              tooltip: 'Mark all read',
              onPressed: (busy || unreadTotal == 0) ? null : onMarkAllRead,
              icon: Icon(
                Icons.done_all,
                color: unreadTotal == 0
                    ? c.textMuted.withAlpha(120)
                    : c.accentText,
                size: 20,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Refresh',
              onPressed: busy ? null : onRefresh,
              icon: Icon(Icons.refresh, color: c.accentText, size: 20),
            ),
          ],
        ),
        Row(
          children: [
            PillSwitcher<int>(
              options: const [
                PillOption(
                  value: 1,
                  label: 'Device',
                  icon: Icons.smartphone_outlined,
                ),
                PillOption(
                  value: 0,
                  label: 'SIM',
                  icon: Icons.sd_card_outlined,
                ),
              ],
              selected: store,
              onChanged: onStoreChanged,
            ),
            const Spacer(),
            Text(
              capLine,
              style: TextStyle(color: c.textMuted, fontSize: 11.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: TextField(
            controller: searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search sender or text…',
              prefixIcon: Icon(Icons.search, color: c.textMuted, size: 16),
              suffixIcon: search.isEmpty
                  ? null
                  : InkWell(
                      onTap: onClearSearch,
                      child: Icon(Icons.clear, color: c.textMuted, size: 16),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: onSearchChanged,
          ),
        ),
        if (bulkVisible) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.accent.withAlpha(24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.accent.withAlpha(90)),
            ),
            child: Row(
              children: [
                TextButton(onPressed: onSelectAll, child: const Text('All')),
                TextButton(onPressed: onSelectNone, child: const Text('None')),
                const Spacer(),
                TextButton(
                  onPressed: busy || selectedCount == 0
                      ? null
                      : onMarkReadSelected,
                  child: const Text('Mark read'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.danger,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                  onPressed: busy || selectedCount == 0 ? null : onBulkDelete,
                  child: Text(
                    'Delete${selectedCount == 0 ? '' : ' ($selectedCount)'}',
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

/// Filter row + grouped messages (or spinner / empty state).
class SmsInboxList extends StatelessWidget {
  final bool busy;
  final bool wasEmpty;
  final bool hasFilter;
  final bool unreadOnly;
  final ValueChanged<bool> onUnreadOnlyChanged;
  final List<MapEntry<String, List<SmsMessage>>> groups;
  final int filteredCount;
  final String collapseLabel;
  final VoidCallback onToggleCollapseAll;
  final Widget Function(String sender, List<SmsMessage> msgs) groupBuilder;

  const SmsInboxList({
    super.key,
    required this.busy,
    required this.wasEmpty,
    required this.hasFilter,
    required this.unreadOnly,
    required this.onUnreadOnlyChanged,
    required this.groups,
    required this.filteredCount,
    required this.collapseLabel,
    required this.onToggleCollapseAll,
    required this.groupBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    if (busy && wasEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            hasFilter ? 'No messages match.' : 'No messages in this store.',
            style: TextStyle(color: c.textMuted),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            FilterChip(
              label: const Text('Unread', style: TextStyle(fontSize: 12)),
              selected: unreadOnly,
              visualDensity: VisualDensity.compact,
              onSelected: onUnreadOnlyChanged,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${groups.length} sender${groups.length == 1 ? '' : 's'} · $filteredCount messages',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ),
            const Spacer(),
            InkWell(
              onTap: onToggleCollapseAll,
              child: Text(
                collapseLabel,
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final g in groups) groupBuilder(g.key, g.value),
      ],
    );
  }
}

/// Vertical compose card: number up top, roomy message box, live
/// character count + Send pinned bottom-right. Reads well at any
/// width, narrow or side-column.
class SmsSendCard extends StatelessWidget {
  final TextEditingController numCtrl;
  final TextEditingController textCtrl;
  final bool busy;
  final VoidCallback? onSend;
  final VoidCallback onTextChanged;

  const SmsSendCard({
    super.key,
    required this.numCtrl,
    required this.textCtrl,
    required this.busy,
    this.onSend,
    required this.onTextChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final len = textCtrl.text.length;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Send SMS'),
          TextField(
            controller: numCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'To',
              hintText: 'Number or sender name',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: textCtrl,
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'GSM-7 / Unicode auto-encoded',
              alignLabelWithHint: true,
              isDense: true,
            ),
            maxLines: 6,
            minLines: 3,
            onChanged: (_) => onTextChanged(),
            onSubmitted: (_) => onSend?.call(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                len == 0 ? 'empty' : '$len char${len == 1 ? '' : 's'}',
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: busy ? null : onSend,
                child: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SmsCenterCard extends StatelessWidget {
  final TextEditingController centerCtrl;
  final String validity;
  final bool report;
  final bool busy;
  final ValueChanged<String> onValidityChanged;
  final ValueChanged<bool> onReportChanged;
  final VoidCallback? onSave;

  const SmsCenterCard({
    super.key,
    required this.centerCtrl,
    required this.validity,
    required this.report,
    required this.busy,
    required this.onValidityChanged,
    required this.onReportChanged,
    this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('SMS center settings'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: centerCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Center number',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: validity,
                  decoration: const InputDecoration(
                    labelText: 'Validity',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'twelve_hours',
                      child: Text('12 hours'),
                    ),
                    DropdownMenuItem(value: 'one_day', child: Text('1 day')),
                    DropdownMenuItem(value: 'one_week', child: Text('1 week')),
                    DropdownMenuItem(value: 'largest', child: Text('Maximum')),
                  ],
                  onChanged: (v) {
                    if (v != null) onValidityChanged(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Switch(
                value: report,
                activeThumbColor: c.accent,
                onChanged: onReportChanged,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Send delivery reports',
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              ElevatedButton(
                onPressed: busy ? null : onSave,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
