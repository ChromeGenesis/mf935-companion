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

const _recentKey = 'ussd_recent';
const _maxRecent = 8;

/// USSD tab: dialpad input + keypad (narrow screens), remembered codes,
/// interactive menu replies, session history.
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
  List<String> _recent = [];
  UssdResult? _last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _recent = prefs.getStringList(_recentKey) ?? []);
  }

  Future<void> _remember(String code) async {
    final list = [code, ..._recent.where((c) => c != code)]
        .take(_maxRecent)
        .toList();
    setState(() => _recent = list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentKey, list);
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
    await _remember(code);
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

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    if (!widget.connected) {
      return const EmptyState(
          icon: Icons.dialpad_outlined,
          title: 'Log in to use USSD',
          subtitle: 'Balance checks and carrier menus live here.');
    }
    final code = _codeCtrl.text;
    final codeValid =
        code.trim().isEmpty || ZteClient.isValidUssd(ZteClient.normalizeUssd(code));
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final narrow = constraints.maxWidth < 560;
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
                              errorText: codeValid
                                  ? null
                                  : 'Codes look like *123#',
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
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('Send'),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Backspace',
                          onPressed: _backspace,
                          icon: Icon(Icons.backspace_outlined,
                              color: c.textMuted, size: 20),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : _cancel,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                    if (_recent.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final r in _recent)
                            InkWell(
                              onTap: _busy
                                  ? null
                                  : () {
                                      _codeCtrl.text = r;
                                      _send();
                                    },
                              borderRadius: BorderRadius.circular(99),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: c.accent.withAlpha(24),
                                  borderRadius:
                                      BorderRadius.circular(99),
                                  border: Border.all(
                                      color: c.accent.withAlpha(80)),
                                ),
                                child: Text(r,
                                    style: TextStyle(
                                        color: c.accentText,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ),
                        ],
                      ),
                    ],
                    // Keypad: dialer-first on narrow screens, tucked into an
                    // expander on wide ones (no dead space on desktop).
                    if (narrow) ...[
                      const SizedBox(height: 12),
                      _keypad(),
                    ] else ...[
                      const SizedBox(height: 6),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('Keypad',
                            style: TextStyle(
                                color: c.textMuted, fontSize: 12.5)),
                        children: [_keypad()],
                      ),
                    ],
                    if (_last != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(60),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: _last!.success
                                  ? c.live.withAlpha(120)
                                  : c.danger.withAlpha(120)),
                        ),
                        child: SelectableText(
                          _last!.success ? _last!.text : _last!.error,
                          style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 13,
                              height: 1.5),
                        ),
                      ),
                    ],
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
                    Row(
                      children: [
                        const SectionLabel('History'),
                        const Spacer(),
                        InkWell(
                          onTap: () => setState(() => _history.clear()),
                          child: Text('clear',
                              style: TextStyle(
                                  color: c.textMuted, fontSize: 11.5)),
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
                      ..._history.take(20).map((h) => InkWell(
                            onTap: h.ok && h.request.startsWith('*')
                                ? () {
                                    _codeCtrl.text = h.request;
                                    _send();
                                  }
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 6),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        h.ok
                                            ? Icons.check_circle_outline
                                            : Icons.error_outline,
                                        size: 14,
                                        color:
                                            h.ok ? c.live : c.danger,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(h.request,
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: c.textPrimary,
                                                fontWeight:
                                                    FontWeight.w700,
                                                fontSize: 12.5)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    h.reply.replaceAll('\n', ' '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: c.textSecondary,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          )),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
