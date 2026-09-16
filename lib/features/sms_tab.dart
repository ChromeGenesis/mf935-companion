import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sms_group.dart';
import 'sms_panels.dart';
import '../core/capability.dart';
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
  // Groups start collapsed (retracted) — the inbox opens as a clean
  // sender list; tapping a sender expands its messages.
  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _expanded = {};
  final Set<String> _showAll = {}; // senders expanded past the cap
  String _search = '';
  bool _unreadOnly = false;

  // Auto-clean: when the active store hits 80%, the 50 oldest go so
  // new arrivals are never blocked. Opt-out via the inbox chip.
  bool _autoClean = true;
  bool _purging = false;
  String _lastPurgeKey = '';

  final _numCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _centerCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _validity = 'twelve_hours';
  bool _report = false;

  @override
  void initState() {
    super.initState();
    _loadAutoClean();
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

  Future<void> _loadAutoClean() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _autoClean = prefs.getBool('sms_autoclean') ?? true);
    } catch (_) {
      // Prefs unavailable — stay on the safe default (clean on).
    }
  }

  Future<void> _setAutoClean(bool v) async {
    setState(() => _autoClean = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sms_autoclean', v);
    } catch (_) {}
    widget.log(v ? 'auto-clean on: oldest 50 go at 80% full' : 'auto-clean off');
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
    if (mounted) _maybeAutoPurge();
  }

  /// Auto-clean: the modem stops receiving into a full store, so at
  /// 80% the 50 oldest messages go (one attempt per usage level — a
  /// failed delete never loops). Runs after every load; a successful
  /// purge reloads so counts settle below the line.
  Future<void> _maybeAutoPurge() async {
    if (!_autoClean || _purging || !widget.connected || _busy) return;
    final (used, total) = smsStoreUsage(_capacity, _store);
    if (total <= 0 || used / total < 0.8) return;
    final key = '$_store|$used|$total';
    if (key == _lastPurgeKey) return; // already tried this level
    _lastPurgeKey = key;
    final victims = oldestSmsIds(_msgs, 50);
    if (victims.isEmpty) return;
    _purging = true;
    try {
      final ok = await widget.client.deleteSms(victims);
      widget.log(
        ok
            ? 'auto-clean: store $used/$total — removed ${victims.length} oldest'
            : formatCommandFailure(
                command: 'DELETE_SMS',
                result: 'error',
                next: 'Free inbox space by hand — the store is nearly full.',
              ),
      );
    } catch (e) {
      widget.log('auto-clean failed: $e');
    } finally {
      _purging = false;
    }
    _load();
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
      widget.log(
        done
            ? '$what deleted (${ids.length})'
            : formatCommandFailure(
                command: 'DELETE_SMS',
                result: 'error',
                next: 'Reload the inbox — the row may already be gone.',
              ),
      );
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
      widget.log(
        ok
            ? 'SMS sent to $to'
            : formatCommandFailure(
                command: 'SEND_SMS',
                result: 'error',
                next: 'Check signal + SMS center number, then retry once.',
              ),
      );
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
      widget.log(
        ok
            ? 'SMS settings saved'
            : formatCommandFailure(
                command: 'SET_MESSAGE_CENTER',
                result: 'error',
                next: 'Reload settings; some firmwares ignore this silently.',
              ),
      );
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
      collapsed: !_expanded.contains(sender),
      showAll: _showAll.contains(sender),
      selecting: _selecting,
      selected: _selected,
      busy: _busy,
      onToggleCollapse: () => setState(() {
        if (!_expanded.remove(sender)) _expanded.add(sender);
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
    final anyOpen = groups.any((g) => _expanded.contains(g.key));
    final allIds = filtered.map((m) => m.id).toSet();
    final allPicked =
        allIds.isNotEmpty && _selected.containsAll(allIds);

    Widget inboxHeader() => SmsInboxHeader(
      selectedCount: _selected.length,
      unreadTotal: unreadTotal,
      store: _store,
      busy: _busy,
      capLine: capLine,
      searchCtrl: _searchCtrl,
      search: _search,
      allSelected: allPicked,
      onMarkAllRead: _markAllRead,
      onRefresh: _load,
      onStoreChanged: (v) {
        setState(() {
          _store = v;
          _selecting = false;
          _selected.clear();
          _expanded.clear();
          _showAll.clear();
        });
        _load();
      },
      onSearchChanged: (v) => setState(() => _search = v),
      onClearSearch: () {
        _searchCtrl.clear();
        setState(() => _search = '');
      },
      // One toggle: all filtered picked → clear; otherwise pick all.
      // Per-group checkboxes + per-group delete do the rest — no bar.
      onToggleSelectAll: () => setState(() {
        if (allPicked) {
          _selected.clear();
          _selecting = false;
        } else {
          _selecting = true;
          _selected.addAll(allIds);
        }
      }),
    );

    Widget inboxList() => SmsInboxList(
      busy: _busy,
      wasEmpty: _msgs.isEmpty,
      hasFilter: _search.isNotEmpty || _unreadOnly,
      unreadOnly: _unreadOnly,
      onUnreadOnlyChanged: (v) => setState(() => _unreadOnly = v),
      autoClean: _autoClean,
      onAutoCleanChanged: _setAutoClean,
      groups: groups,
      filteredCount: filtered.length,
      collapseLabel: anyOpen ? 'collapse all' : 'expand all',
      onToggleCollapseAll: () => setState(() {
        // Toggle: collapse all if any expanded, else expand.
        _expanded.clear();
        if (!anyOpen) {
          _expanded.addAll(groups.map((g) => g.key));
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
