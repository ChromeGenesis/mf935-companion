import 'package:flutter/material.dart';

import 'sms_group.dart';
import 'sms_panels.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

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
    final anyOpen = groups.any((g) => !_collapsed.contains(g.key));

    Widget inboxHeader() => SmsInboxHeader(
      selectedCount: _selected.length,
      unreadTotal: unreadTotal,
      store: _store,
      busy: _busy,
      capLine: capLine,
      searchCtrl: _searchCtrl,
      search: _search,
      bulkVisible: _selecting || _selected.isNotEmpty,
      onMarkAllRead: _markAllRead,
      onRefresh: _load,
      onStoreChanged: (v) {
        setState(() {
          _store = v;
          _selecting = false;
          _selected.clear();
          _collapsed.clear();
          _showAll.clear();
        });
        _load();
      },
      onSearchChanged: (v) => setState(() => _search = v),
      onClearSearch: () {
        _searchCtrl.clear();
        setState(() => _search = '');
      },
      onSelectAll: () => setState(() {
        _selected
          ..clear()
          ..addAll(filtered.map((m) => m.id));
      }),
      onSelectNone: () => setState(() {
        _selected.clear();
        _selecting = false;
      }),
      onMarkReadSelected: () => _markReadIds(_selected.toList()),
      onBulkDelete: _bulkDelete,
    );

    Widget inboxList() => SmsInboxList(
      busy: _busy,
      wasEmpty: _msgs.isEmpty,
      hasFilter: _search.isNotEmpty || _unreadOnly,
      unreadOnly: _unreadOnly,
      onUnreadOnlyChanged: (v) => setState(() => _unreadOnly = v),
      groups: groups,
      filteredCount: filtered.length,
      collapseLabel: anyOpen ? 'collapse all' : 'expand all',
      onToggleCollapseAll: () => setState(() {
        // Toggle: collapse all if any expanded, else expand.
        _collapsed.clear();
        if (anyOpen) {
          _collapsed.addAll(groups.map((g) => g.key));
        }
      }),
      groupBuilder: _group,
    );

    final sideColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SmsSendCard(
          numCtrl: _numCtrl,
          textCtrl: _textCtrl,
          busy: _busy,
          onSend: _send,
          onTextChanged: () => setState(() {}),
        ),
        const SizedBox(height: 10),
        SmsCenterCard(
          centerCtrl: _centerCtrl,
          validity: _validity,
          report: _report,
          busy: _busy,
          onValidityChanged: (v) => setState(() => _validity = v),
          onReportChanged: (v) => setState(() => _report = v),
          onSave: _saveSettings,
        ),
      ],
    );

    // Desktop: inbox owns the left at full height (its list scrolls
    // inside the card); compose + center settings stack on the right.
    // Narrow: the same cards stacked in one scroll.
    return LayoutBuilder(
      builder: (_, cons) {
        if (cons.maxWidth > 760) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: GlassCard(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      inboxHeader(),
                      Expanded(
                        child: SingleChildScrollView(child: inboxList()),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 5,
                child: SingleChildScrollView(child: sideColumn),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [inboxHeader(), inboxList()],
                ),
              ),
              const SizedBox(height: 10),
              sideColumn,
            ],
          ),
        );
      },
    );
  }
}
