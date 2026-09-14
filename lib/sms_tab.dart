import 'package:flutter/material.dart';

import 'sms_group.dart';
import 'theme.dart';
import 'widgets.dart';
import 'zte_client.dart';

/// SMS tab: device/SIM inbox grouped by sender, multi-select + bulk
/// actions up top (never buried), search, unread filter, swipe delete.
class SmsTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;

  const SmsTab({
    super.key,
    required this.client,
    required this.connected,
    required this.log,
  });

  @override
  State<SmsTab> createState() => _SmsTabState();
}

class _SmsTabState extends State<SmsTab> {
  int _store = 1; // 1 = device, 0 = SIM
  List<SmsMessage> _msgs = [];
  Map<String, dynamic> _capacity = {};
  Map<String, String> _settings = {};
  bool _busy = false;

  // Selection + view state (SSOT: one set drives everything).
  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};
  final Set<String> _showAll = {}; // senders expanded past the cap
  String _search = '';
  bool _unreadOnly = false;

  final _numCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _centerCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _validity = 'twelve_hours';
  bool _report = false;

  @override
  void initState() {
    super.initState();
    if (widget.connected) _load();
  }

  @override
  void didUpdateWidget(SmsTab old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) _load();
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    _textCtrl.dispose();
    _centerCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.connected || _busy) return;
    setState(() => _busy = true);
    try {
      final results = await Future.wait([
        widget.client.listSms(memStore: _store),
        widget.client.getSmsCapacity(),
        widget.client.getSmsSettings(),
      ]);
      if (!mounted) return;
      setState(() {
        _msgs = results[0] as List<SmsMessage>;
        _capacity = results[1] as Map<String, dynamic>;
        _settings = results[2] as Map<String, String>;
        _centerCtrl.text = _settings['centerNumber'] ?? '';
        _validity = _settings['validity'] ?? 'twelve_hours';
        _report = (_settings['deliveryReport'] ?? '0') == '1';
        _selected.retainAll(_msgs.map((m) => m.id));
        if (_selected.isEmpty) _selecting = false;
      });
      widget.log('SMS loaded: ${_msgs.length} msgs (store=$_store)');
    } catch (e) {
      widget.log('SMS load failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Messages after search + unread filters.
  List<SmsMessage> get _filtered {
    final q = _search.trim().toLowerCase();
    return _msgs.where((m) {
      if (_unreadOnly && !m.isNew) return false;
      if (q.isEmpty) return true;
      return m.number.toLowerCase().contains(q) ||
          m.content.toLowerCase().contains(q);
    }).toList();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(id);
      }
    });
  }

  Future<void> _deleteIds(List<String> ids, String what) async {
    if (ids.isEmpty) return;
    try {
      final done = await widget.client.deleteSms(ids);
      widget.log(done ? '$what deleted (${ids.length})' : 'delete refused');
    } catch (e) {
      widget.log('delete failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _msgs.removeWhere((m) => ids.contains(m.id));
      _selected.removeAll(ids);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _bulkDelete() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    final ok = await confirmAction(
      context,
      icon: Icons.delete_outline,
      title: 'Delete ${ids.length} message${ids.length == 1 ? '' : 's'}?',
      message:
          'They are removed from the ${_store == 1 ? 'device' : 'SIM'} store. This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (ok) _deleteIds(ids, '${ids.length} SMS');
  }

  Future<void> _deleteGroup(String sender, List<SmsMessage> msgs) async {
    final ok = await confirmAction(
      context,
      icon: Icons.delete_outline,
      title: 'Delete all from $sender?',
      message: '${msgs.length} messages go away. This cannot be undone.',
      confirmLabel: 'Delete all',
    );
    if (ok) _deleteIds(msgs.map((m) => m.id).toList(), '$sender group');
  }

  Future<void> _markReadIds(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      await widget.client.markSmsRead(ids);
      widget.log('${ids.length} SMS marked read');
    } catch (e) {
      widget.log('mark-read failed: $e');
    }
    _load();
  }

  Future<void> _markAllRead() async {
    final ids = _msgs.where((m) => m.isNew).map((m) => m.id).toList();
    if (ids.isEmpty) {
      widget.log('nothing unread — already clean');
      return;
    }
    _markReadIds(ids);
  }

  Future<void> _swipeDelete(SmsMessage m) async {
    try {
      await widget.client.deleteSms([m.id]);
      widget.log('SMS from ${m.number} deleted');
    } catch (e) {
      widget.log('delete failed: $e');
      _load(); // re-pull: row may not actually be gone
      return;
    }
    if (!mounted) return;
    setState(() {
      _msgs.removeWhere((x) => x.id == m.id);
      _selected.remove(m.id);
    });
  }

  Future<void> _openMessage(SmsMessage m) async {
    final c = context.zc;
    await showGlassModal(
      context,
      icon: m.isNew ? Icons.markunread : Icons.drafts_outlined,
      title: m.number,
      subtitle: m.displayDate,
      body: SelectableText(
        m.content,
        style: TextStyle(color: c.textPrimary, fontSize: 13.5, height: 1.55),
      ),
      actions: [
        if (m.isNew)
          OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _markReadIds([m.id]);
            },
            child: const Text('Mark read'),
          ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: c.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            Navigator.of(context).pop();
            _deleteIds([m.id], 'SMS ${m.id}');
          },
          child: const Text('Delete'),
        ),
      ],
    );
    if (m.isNew && mounted) {
      // Reading implies seen — best-effort mark even on dismiss.
      try {
        await widget.client.markSmsRead([m.id]);
      } catch (_) {}
      _load();
    }
  }

  Future<void> _send() async {
    final to = _numCtrl.text.trim();
    final body = _textCtrl.text;
    if (to.isEmpty || body.isEmpty) return;
    setState(() => _busy = true);
    try {
      final ok = await widget.client.sendSms(to, body);
      widget.log(ok ? 'SMS sent to $to' : 'SMS refused by modem');
      if (ok && mounted) setState(() => _textCtrl.clear());
    } catch (e) {
      widget.log('SMS send failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _load();
  }

  Future<void> _saveSettings() async {
    setState(() => _busy = true);
    try {
      final ok = await widget.client.setSmsSettings(
        centerNumber: _centerCtrl.text.trim(),
        validity: _validity,
        deliveryReport: _report ? '1' : '0',
      );
      widget.log(ok ? 'SMS settings saved' : 'SMS settings refused');
    } catch (e) {
      widget.log('SMS settings failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Thin adapter: selection/expansion state lives here, rendering
  /// lives in [SenderGroup] (sms_group.dart).
  Widget _group(String sender, List<SmsMessage> msgs) {
    final ids = msgs.map((m) => m.id).toSet();
    final picked = ids.intersection(_selected).length;
    return SenderGroup(
      sender: sender,
      msgs: msgs,
      collapsed: _collapsed.contains(sender),
      showAll: _showAll.contains(sender),
      selecting: _selecting,
      selected: _selected,
      busy: _busy,
      onToggleCollapse: () => setState(() {
        if (!_collapsed.remove(sender)) _collapsed.add(sender);
      }),
      onToggleShowAll: () => setState(() {
        if (!_showAll.remove(sender)) _showAll.add(sender);
      }),
      onToggleSelect: _toggleSelect,
      onToggleGroupPick: () => setState(() {
        _selecting = true;
        if (picked == ids.length && ids.isNotEmpty) {
          _selected.removeAll(ids);
          if (_selected.isEmpty) _selecting = false;
        } else {
          _selected.addAll(ids);
        }
      }),
      onOpen: _openMessage,
      onEnterSelect: (id) => setState(() {
        _selecting = true;
        _selected.add(id);
      }),
      onSelectGroup: () => setState(() {
        _selecting = true;
        _selected.addAll(ids);
      }),
      onMarkGroupRead: () => _markReadIds(msgs.map((m) => m.id).toList()),
      onDeleteGroup: () => _deleteGroup(sender, msgs),
      onSwipeDelete: _swipeDelete,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    if (!widget.connected) {
      return const EmptyState(
        icon: Icons.sms_outlined,
        title: 'Log in to read SMS',
        subtitle: 'Device + SIM inbox live here.',
      );
    }
    final capLine = _capacity.isEmpty
        ? '…'
        : 'Device ${_capacity['sms_nv_rev_total'] ?? '?'}/${_capacity['sms_nv_total'] ?? '?'} · '
              'SIM ${_capacity['sms_sim_rev_total'] ?? '?'}/${_capacity['sms_sim_total'] ?? '?'}';
    final filtered = _filtered;
    final groups = groupSmsBySender(filtered);
    final unreadTotal = _msgs.where((m) => m.isNew).length;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Row 1: title + global actions (airy, nothing crammed) ──
                Row(
                  children: [
                    const SectionLabel('Inbox'),
                    if (_selected.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '${_selected.length} picked',
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
                      onPressed: (_busy || unreadTotal == 0)
                          ? null
                          : _markAllRead,
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
                      onPressed: _busy ? null : _load,
                      icon: Icon(Icons.refresh, color: c.accentText, size: 20),
                    ),
                  ],
                ),
                // ── Row 2: store switcher + capacity (own breathing line) ──
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
                      selected: _store,
                      onChanged: (v) {
                        setState(() {
                          _store = v;
                          _selecting = false;
                          _selected.clear();
                          _collapsed.clear();
                          _showAll.clear();
                        });
                        _load();
                      },
                    ),
                    const Spacer(),
                    Text(
                      capLine,
                      style: TextStyle(color: c.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // ── Row 3: full-width search ──
                SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search sender or text…',
                      prefixIcon: Icon(
                        Icons.search,
                        color: c.textMuted,
                        size: 16,
                      ),
                      suffixIcon: _search.isEmpty
                          ? null
                          : InkWell(
                              onTap: () {
                                _searchCtrl.clear();
                                setState(() => _search = '');
                              },
                              child: Icon(
                                Icons.clear,
                                color: c.textMuted,
                                size: 16,
                              ),
                            ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                const SizedBox(height: 4),
                // ── Row 4: filter + list meta ──
                // ── Bulk bar: ABOVE the list, never buried ──
                if (_selecting || _selected.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: c.accent.withAlpha(24),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.accent.withAlpha(90)),
                    ),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _selected
                              ..clear()
                              ..addAll(filtered.map((m) => m.id));
                          }),
                          child: const Text('All'),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _selected.clear();
                            _selecting = false;
                          }),
                          child: const Text('None'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : () => _markReadIds(_selected.toList()),
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
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : _bulkDelete,
                          child: Text(
                            'Delete${_selected.isEmpty ? '' : ' (${_selected.length})'}',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                // ── Grouped messages ──
                if (_busy && _msgs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: Text(
                        _search.isNotEmpty || _unreadOnly
                            ? 'No messages match.'
                            : 'No messages in this store.',
                        style: TextStyle(color: c.textMuted),
                      ),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      FilterChip(
                        label: const Text(
                          'Unread',
                          style: TextStyle(fontSize: 12),
                        ),
                        selected: _unreadOnly,
                        visualDensity: VisualDensity.compact,
                        onSelected: (v) => setState(() => _unreadOnly = v),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '${groups.length} sender${groups.length == 1 ? '' : 's'} · ${filtered.length} messages',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.textMuted, fontSize: 11.5),
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () => setState(() {
                          // Toggle: collapse all if any expanded, else expand.
                          final anyOpen = groups.any(
                            (g) => !_collapsed.contains(g.key),
                          );
                          _collapsed.clear();
                          if (anyOpen) {
                            _collapsed.addAll(groups.map((g) => g.key));
                          }
                        }),
                        child: Text(
                          groups.any((g) => !_collapsed.contains(g.key))
                              ? 'collapse all'
                              : 'expand all',
                          style: TextStyle(color: c.textMuted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final g in groups) _group(g.key, g.value),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SectionLabel('Send SMS'),
                Row(
                  children: [
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _numCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'To',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _textCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Message',
                          isDense: true,
                        ),
                        maxLines: 1,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _busy ? null : _send,
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SectionLabel('SMS center settings'),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 230),
                      child: SizedBox(
                        width: 230,
                        child: TextField(
                          controller: _centerCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Center number',
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: DropdownButtonFormField<String>(
                        initialValue: _validity,
                        decoration: const InputDecoration(
                          labelText: 'Validity',
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'twelve_hours',
                            child: Text('12 hours'),
                          ),
                          DropdownMenuItem(
                            value: 'one_day',
                            child: Text('1 day'),
                          ),
                          DropdownMenuItem(
                            value: 'one_week',
                            child: Text('1 week'),
                          ),
                          DropdownMenuItem(
                            value: 'largest',
                            child: Text('Maximum'),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _validity = v ?? _validity),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: _report,
                          activeThumbColor: c.accent,
                          onChanged: (v) => setState(() => _report = v),
                        ),
                        Text(
                          'Reports',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                    ElevatedButton(
                      onPressed: _busy ? null : _saveSettings,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
