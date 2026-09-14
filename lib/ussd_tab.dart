import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'widgets.dart';
import 'zte_client.dart';

class UssdEntry {
  final String request;
  final String reply;
  final bool ok;
  final DateTime at;
  UssdEntry(this.request, this.reply, this.ok) : at = DateTime.now();
}

/// A saved USSD shortcut. Codes auto-save on send; the UI also allows
/// manual add / edit / delete (full CRUD).
class UssdSaved {
  final String code;
  final String label;

  const UssdSaved({required this.code, this.label = ''});

  String get displayName => label.trim().isEmpty ? code : label.trim();

  Map<String, dynamic> toJson() => {'code': code, 'label': label};

  factory UssdSaved.fromJson(Map<String, dynamic> j) => UssdSaved(
        code: '${j['code'] ?? ''}',
        label: '${j['label'] ?? ''}',
      );
}

const _savedKey = 'ussd_saved';
const _maxSaved = 12;

/// USSD tab: send console (keypad, saved shortcuts with full CRUD) on the
/// left, session history on the right — both running to the bottom on
/// wide screens, stacked + dialer-first on narrow ones.
class UssdTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;

  const UssdTab(
      {super.key,
      required this.client,
      required this.connected,
      required this.log});

  @override
  State<UssdTab> createState() => _UssdTabState();
}

class _UssdTabState extends State<UssdTab> {
  final _codeCtrl = TextEditingController(text: '*312#');
  final _replyCtrl = TextEditingController();
  final List<UssdEntry> _history = [];
  List<UssdSaved> _saved = [];
  UssdResult? _last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedKey);
    List<UssdSaved> list = [];
    if (raw != null) {
      try {
        list = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => UssdSaved.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {
        list = [];
      }
    }
    if (!mounted) return;
    setState(() => _saved = list);
  }

  Future<void> _persistSaved() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _savedKey,
      jsonEncode(_saved.map((e) => e.toJson()).toList()),
    );
  }

  /// Auto-remember a sent code (deduped against manual entries so an
  /// edit survives the next send).
  void _remember(String code) {
    final existing = _saved.where((s) => s.code == code).firstOrNull;
    final entry =
        UssdSaved(code: code, label: existing?.label ?? '');
    final list = [
      entry,
      ..._saved.where((s) => s.code != code),
    ].take(_maxSaved).toList();
    setState(() => _saved = list);
    _persistSaved();
  }

  Future<void> _editSaved({UssdSaved? existing}) async {
    final code = ZteClient.normalizeUssd(_codeCtrl.text);
    final result = await showUssdSavedDialog(
      context,
      existing: existing ?? (code.isEmpty || code == '#'
          ? null
          : UssdSaved(code: code)),
    );
    if (result == null || !mounted) return;
    setState(() {
      final list = [
        result,
        ..._saved.where((s) => s.code != result.code),
      ].take(_maxSaved).toList();
      _saved = list;
    });
    await _persistSaved();
  }

  Future<void> _deleteSaved(String code) async {
    setState(() => _saved = _saved.where((s) => s.code != code).toList());
    await _persistSaved();
    widget.log('saved USSD removed: $code');
  }

  void _key(String k) {
    final v = _codeCtrl.value;
    final pos = v.selection.isValid
        ? v.selection.extentOffset
        : _codeCtrl.text.length;
    final t = _codeCtrl.text;
    _codeCtrl.value = TextEditingValue(
      text: t.substring(0, pos) + k + t.substring(pos),
      selection: TextSelection.collapsed(offset: pos + k.length),
    );
  }

  void _backspace() {
    final v = _codeCtrl.value;
    final pos = v.selection.isValid
        ? v.selection.extentOffset
        : _codeCtrl.text.length;
    if (pos <= 0) return;
    final t = _codeCtrl.text;
    _codeCtrl.value = TextEditingValue(
      text: t.substring(0, pos - 1) + t.substring(pos),
      selection: TextSelection.collapsed(offset: pos - 1),
    );
  }

  Future<void> _send() async {
    final code = ZteClient.normalizeUssd(_codeCtrl.text);
    if (!ZteClient.isValidUssd(code)) {
      widget.log('USSD rejected locally: "$code" is not *digits#.');
      return;
    }
    if (_busy || !widget.connected) return;
    _codeCtrl.text = code;
    _remember(code);
    setState(() {
      _busy = true;
      _last = null;
    });
    widget.log('USSD $code → sending…');
    try {
      // Best-effort clear of any stale session first (stock pattern).
      try {
        await widget.client.cancelUssd();
      } catch (_) {}
      final r = await widget.client.runUssd(code);
      if (!mounted) return;
      setState(() {
        _last = r;
        _history.insert(0, UssdEntry(code, r.success ? r.text : r.error, r.success));
      });
      widget.log(r.success
          ? 'USSD reply (${r.text.length} chars${r.needsReply ? ', menu awaits reply' : ''})'
          : 'USSD failed: ${r.error}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _history.insert(0, UssdEntry(code, '$e', false)));
      widget.log('USSD error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    widget.log('USSD reply "$text" → sending…');
    try {
      final sent = await widget.client.replyUssd(text);
      if (!sent) {
        if (mounted) {
          setState(() => _history.insert(
              0, UssdEntry('↳ $text', 'Modem refused the reply.', false)));
        }
        widget.log('USSD reply refused');
        return;
      }
      final r = await widget.client.waitUssdReply();
      if (!mounted) return;
      setState(() {
        _last = r;
        _history.insert(
            0, UssdEntry('↳ $text', r.success ? r.text : r.error, r.success));
        _replyCtrl.clear();
      });
      widget.log(r.success ? 'USSD reply ok' : 'USSD reply failed: ${r.error}');
    } catch (e) {
      widget.log('USSD reply error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.client.cancelUssd();
      widget.log('USSD session cancelled');
    } catch (e) {
      widget.log('USSD cancel failed: $e');
    }
    if (mounted) setState(() => _last = null);
  }

  /// Dialpad grid. One build path for both placements (SSOT).
  Widget _keypad() {
    final c = context.zc;
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.4,
      children: [
        for (final k in keys)
          OutlinedButton(
            onPressed: () => _key(k),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(k,
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }

  /// Saved shortcuts list: tap to send, pencil to edit, trash to delete.
  /// "+ Save" opens the CRUD dialog.
  Widget _savedSection(ZteColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              'SAVED CODES',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : () => _editSaved(),
              icon: Icon(Icons.add, size: 15, color: c.accentText),
              label: Text('Save',
                  style:
                      TextStyle(color: c.accentText, fontSize: 12)),
            ),
          ],
        ),
        if (_saved.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Sent codes auto-save here. Tap + to add one manually.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
          )
        else
          for (final s in _saved)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(70),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Row(
                  children: [
                    InkWell(
                      onTap: _busy
                          ? null
                          : () {
                              _codeCtrl.text = s.code;
                              _send();
                            },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.north_west,
                            size: 14, color: c.accentText),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: _busy
                            ? null
                            : () {
                                _codeCtrl.text = s.code;
                                _send();
                              },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (s.label.trim().isNotEmpty)
                              Text(
                                s.label.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            Text(
                              s.code,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: s.label.trim().isNotEmpty
                                    ? c.textMuted
                                    : c.textPrimary,
                                fontSize: 12,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit ${s.displayName}',
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy ? null : () => _editSaved(existing: s),
                      icon: Icon(Icons.edit_outlined,
                          color: c.textMuted, size: 16),
                    ),
                    IconButton(
                      tooltip: 'Delete ${s.displayName}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _deleteSaved(s.code),
                      icon: Icon(Icons.delete_outline,
                          color: c.danger, size: 16),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Widget _sendCard(ZteColors c, bool narrow) {
    final code = _codeCtrl.text;
    final codeValid = code.trim().isEmpty ||
        ZteClient.isValidUssd(ZteClient.normalizeUssd(code));
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Send USSD'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'USSD code',
                    hintText: '*312#',
                    isDense: true,
                    errorText: codeValid ? null : 'Codes look like *123#',
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : _send,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Backspace',
                onPressed: _backspace,
                icon:
                    Icon(Icons.backspace_outlined, color: c.textMuted, size: 20),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _cancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(60),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.borderSubtle),
            ),
            child: _last == null
                ? Text(
                    'No reply yet — send a code to begin a session.',
                    style: TextStyle(color: c.textMuted, fontSize: 12.5),
                  )
                : SelectableText(
                    _last!.success ? _last!.text : _last!.error,
                    style: TextStyle(
                      color: _last!.success ? c.textPrimary : c.danger,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
          ),
          if (_last?.needsReply == true) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replyCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Menu reply (e.g. 9)',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _reply(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _busy ? null : _reply,
                  child: const Text('Reply'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _keypad(),
          const SizedBox(height: 10),
          _savedSection(c),
        ],
      ),
    );
  }

  Widget _historyCard(ZteColors c) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SectionLabel('History'),
              const Spacer(),
              InkWell(
                onTap: () => setState(() => _history.clear()),
                child: Text('clear',
                    style:
                        TextStyle(color: c.textMuted, fontSize: 11.5)),
              ),
            ],
          ),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                  child: Text('No USSD yet this session.',
                      style: TextStyle(color: c.textMuted))),
            )
          else
            ..._history.take(50).map((h) => InkWell(
                  onTap: h.ok && h.request.startsWith('*')
                      ? () {
                          _codeCtrl.text = h.request;
                          _send();
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              h.ok
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline,
                              size: 14,
                              color: h.ok ? c.live : c.danger,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${h.request} · ${ZteClient.timeAgo(h.at)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: c.textMuted,
                                    fontSize: 10.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          h.reply.replaceAll('\n', ' '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.textPrimary, fontSize: 12.5),
                        ),
                        const SizedBox(height: 6),
                        Divider(color: c.borderSubtle, height: 1),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.connected) {
      return const EmptyState(
          icon: Icons.dialpad_outlined,
          title: 'Log in to use USSD',
          subtitle: 'Balance checks and carrier menus live here.');
    }
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final c = context.zc;
        final wide = constraints.maxWidth >= 760;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: SingleChildScrollView(
                  child: _sendCard(c, false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 5,
                child: SingleChildScrollView(child: _historyCard(c)),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              _sendCard(c, true),
              const SizedBox(height: 10),
              _historyCard(c),
            ],
          ),
        );
      },
    );
  }
}

/// Add / edit a saved USSD code. Pops with an [UssdSaved] or null.
Future<UssdSaved?> showUssdSavedDialog(
  BuildContext context, {
  UssdSaved? existing,
}) {
  return showDialog<UssdSaved>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassModal(
        icon: existing == null ? Icons.add : Icons.edit_outlined,
        title: existing == null ? 'Save USSD code' : 'Edit saved code',
        subtitle: 'Shortcut stays on this device.',
        body: _UssdForm(existing: existing),
      ),
    ),
  );
}

class _UssdForm extends StatefulWidget {
  final UssdSaved? existing;
  const _UssdForm({this.existing});

  @override
  State<_UssdForm> createState() => _UssdFormState();
}

class _UssdFormState extends State<_UssdForm> {
  late final _codeCtrl =
      TextEditingController(text: widget.existing?.code ?? '');
  late final _labelCtrl =
      TextEditingController(text: widget.existing?.label ?? '');
  late final _codeFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _labelCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final code = ZteClient.normalizeUssd(_codeCtrl.text);
    if (!ZteClient.isValidUssd(code)) return;
    Navigator.of(context).pop(
      UssdSaved(code: code, label: _labelCtrl.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = _codeCtrl.text;
    final valid = code.trim().isEmpty ||
        ZteClient.isValidUssd(ZteClient.normalizeUssd(code));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _codeCtrl,
          focusNode: _codeFocus,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'USSD code',
            hintText: '*312#',
            isDense: true,
            errorText: valid ? null : 'Codes look like *123#',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _labelCtrl,
          decoration: const InputDecoration(
            labelText: 'Label (optional)',
            hintText: 'e.g. "My MTN balance"',
            isDense: true,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed:
                  valid && code.trim().isNotEmpty ? _submit : null,
              child: Text(widget.existing == null ? 'Save' : 'Update'),
            ),
          ],
        ),
      ],
    );
  }
}