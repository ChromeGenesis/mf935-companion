import 'package:flutter/material.dart';

import '../core/capability.dart';
import '../core/theme.dart';
import 'ussd_saved.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

class UssdEntry {
  final String request;
  final String reply;
  final bool ok;
  final DateTime at;
  UssdEntry(this.request, this.reply, this.ok) : at = DateTime.now();
}

/// USSD tab: send console (keypad, saved shortcuts with full CRUD) on the
/// left, session history on the right — both running to the bottom on
/// wide screens, stacked + dialer-first on narrow ones.
class UssdTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final void Function(String) log;
  final void Function(String goformId, String reason)? onUnsupported;

  const UssdTab({
    super.key,
    required this.client,
    required this.connected,
    required this.log,
    this.onUnsupported,
  });

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
    final list = await loadUssdSaved();
    if (!mounted) return;
    setState(() => _saved = list);
  }

  Future<void> _persistSaved() => saveUssdSaved(_saved);

  /// Auto-remember a sent code (deduped against manual entries so an
  /// edit survives the next send).
  void _remember(String code) {
    setState(() => _saved = rememberUssdCode(_saved, code));
    _persistSaved();
  }

  Future<void> _editSaved({UssdSaved? existing}) async {
    final code = ZteClient.normalizeUssd(_codeCtrl.text);
    final result = await showUssdSavedDialog(
      context,
      existing:
          existing ??
          (code.isEmpty || code == '#' ? null : UssdSaved(code: code)),
    );
    if (result == null || !mounted) return;
    setState(() => _saved = upsertUssdCode(_saved, result));
    await _persistSaved();
  }

  Future<void> _deleteSaved(String code) async {
    setState(() => _saved = _saved.where((s) => s.code != code).toList());
    await _persistSaved();
    widget.log('saved USSD removed: $code');
  }

  /// Keypad taps drive the entry through setState so validation,
  /// error text and the Send button react to every tap — not just to
  /// typed keystrokes.
  void _key(String k) {
    final v = _codeCtrl.value;
    final pos = v.selection.isValid
        ? v.selection.extentOffset
        : _codeCtrl.text.length;
    final t = _codeCtrl.text;
    setState(() {
      _codeCtrl.value = TextEditingValue(
        text: t.substring(0, pos) + k + t.substring(pos),
        selection: TextSelection.collapsed(offset: pos + k.length),
      );
    });
  }

  void _backspace() {
    final v = _codeCtrl.value;
    final pos = v.selection.isValid
        ? v.selection.extentOffset
        : _codeCtrl.text.length;
    if (pos <= 0) return;
    final t = _codeCtrl.text;
    setState(() {
      _codeCtrl.value = TextEditingValue(
        text: t.substring(0, pos - 1) + t.substring(pos),
        selection: TextSelection.collapsed(offset: pos - 1),
      );
    });
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
        _history.insert(
          0,
          UssdEntry(code, r.success ? r.text : r.error, r.success),
        );
      });
      widget.log(
        r.success
            ? 'USSD reply (${r.text.length} chars${r.needsReply ? ', menu awaits reply' : ''})'
            : 'USSD failed: ${r.error}',
      );
      if (!r.success && (r.flag == '41' || r.flag == '99')) {
        widget.onUnsupported?.call(
          'USSD_PROCESS',
          'flag=${r.flag}: ${r.error}',
        );
      }
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
        final msg = formatCommandFailure(
          command: 'USSD_PROCESS',
          result: 'not-accepted',
          next: 'Reply was not accepted. The menu may have expired — send the code again.',
        );
        if (mounted) {
          setState(
            () => _history.insert(0, UssdEntry('↳ $text', msg, false)),
          );
        }
        widget.log('USSD reply not accepted (USSD_PROCESS result=not-accepted)');
        return;
      }
      final r = await widget.client.waitUssdReply();
      if (!mounted) return;
      setState(() {
        _last = r;
        _history.insert(
          0,
          UssdEntry('↳ $text', r.success ? r.text : r.error, r.success),
        );
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

  /// Dialpad grid + a dialer-style delete key riding beneath it,
  /// bottom-right like a normal keypad. One build path for both
  /// placements (SSOT).
  Widget _keypad() {
    final c = context.zc;
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GridView.count(
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
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  k,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _codeCtrl.text.isEmpty ? null : _backspace,
              icon: const Icon(Icons.backspace_outlined, size: 16),
              label: const Text('Delete'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sendCard(ZteColors c, bool narrow) {
    final code = _codeCtrl.text;
    final codeValid =
        code.trim().isEmpty ||
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
              // Send + Cancel ride together on the right.
              ElevatedButton(
                onPressed: _busy ? null : _send,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send'),
              ),
              const SizedBox(width: 8),
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
              color: c.chip,
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
          SavedUssdSection(
            saved: _saved,
            busy: _busy,
            onSendCode: (code) {
              _codeCtrl.text = code;
              _send();
            },
            onAdd: _editSaved,
            onEdit: (s) => _editSaved(existing: s),
            onDelete: _deleteSaved,
          ),
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
                child: Text(
                  'clear',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
            ],
          ),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  'No USSD yet this session.',
                  style: TextStyle(color: c.textMuted),
                ),
              ),
            )
          else
            ..._history
                .take(50)
                .map(
                  (h) => InkWell(
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
                                    fontSize: 10.5,
                                  ),
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
                              color: c.textPrimary,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Divider(color: c.borderSubtle, height: 1),
                        ],
                      ),
                    ),
                  ),
                ),
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
        subtitle: 'Balance checks and carrier menus live here.',
      );
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
                  physics: const BouncingScrollPhysics(),
                  child: _sendCard(c, false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: _historyCard(c),
                ),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
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
