import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/capability.dart';
import '../core/theme.dart';
import 'ussd_saved.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

/// USSD tab: send console (keypad, saved shortcuts with full CRUD) on the
/// left, session history on the right — both running to the bottom on
/// wide screens, stacked + dialer-first on narrow ones.
///
/// Everything here survives restarts: the half-typed code (draft), the
/// saved shortcuts and the reply history. History taps only *recall* a
/// code into the field — sending stays an explicit, deliberate action.
///
/// Layout contract (every rule traces to a live-device bug report):
///  - the entry field is a glass tile, never the theme's black Material
///    fill, and it *yields* to the session banner while a menu awaits a
///    reply so multi-line session text gets the vertical space;
///  - the reply panel and the history list scroll inside their own
///    bounded sub-containers, so a long menu never pushes the keypad
///    out of the viewport;
///  - quick-code chips live in one fixed-height strip at the bottom of
///    the card (horizontal scroll, never wraps, never reflows the card);
///  - the keypad uses fixed-height rows, so the action row sits right
///    under `* 0 #` instead of drifting toward the card's bottom edge.
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
  /// Starts empty — no default code. Any half-typed draft is restored
  /// (and saved) via [ussd_draft_v1], so a restart never throws away
  /// what you were typing.
  final _codeCtrl = TextEditingController();
  final _replyCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  List<UssdHistoryEntry> _history = [];
  List<UssdSaved> _saved = [];
  UssdResult? _last;
  bool _busy = false;

  /// When a menu awaits a reply the existing dialer keypad drives the
  /// answer (stock-phone parity). The phone keyboard is opt-in via the
  /// toggle that replaces the bookmark button while a menu is open —
  /// and every new menu resets to keypad.
  bool _replyViaKeyboard = false;

  /// Show the modem's unsanitized reply instead of the rendered one.
  /// The sanitizer is a heuristic — when the text still looks wrong,
  /// the honest fallback is the bytes the device actually sent. Off
  /// again for every new reply (never sticks across sessions).
  bool _showRaw = false;

  bool get _replyMode => _last?.needsReply == true;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadHistory();
    _restoreDraft();
    // Persist the draft as it changes (also fires for keypad setState).
    _codeCtrl.addListener(_persistDraft);
    // The glass tile lights up while the field holds focus.
    _codeFocus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _codeCtrl.removeListener(_persistDraft);
    _codeFocus.removeListener(_onFocusChanged);
    _codeFocus.dispose();
    _codeCtrl.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restoreDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final draft = prefs.getString('ussd_draft_v1') ?? '';
      // Only when the user hasn't typed during the async gap.
      if (_codeCtrl.text.isEmpty && draft.isNotEmpty) {
        _codeCtrl.text = draft;
      }
    } catch (_) {
      // Prefs unavailable — empty field is the correct default anyway.
    }
  }

  Future<void> _persistDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ussd_draft_v1', _codeCtrl.text);
    } catch (_) {}
  }

  Future<void> _loadSaved() async {
    final list = await loadUssdSaved();
    if (!mounted) return;
    setState(() => _saved = list);
  }

  Future<void> _loadHistory() async {
    final list = await loadUssdHistory();
    if (!mounted) return;
    setState(() => _history = list);
  }

  Future<void> _persistHistory() => saveUssdHistory(_history);

  /// Auto-remember a sent code (deduped against manual entries so an
  /// edit survives the next send).
  void _remember(String code) {
    final next = rememberUssdCode(_saved, code);
    setState(() => _saved = next);
    saveUssdSaved(next);
  }

  Future<void> _editSaved({UssdSaved? existing}) async {
    // "+ Save" saves whatever is dialed right now (or empty); the
    // long-press edit path passes the chip's own entry.
    final drafted = ZteClient.normalizeUssd(_codeCtrl.text);
    final result = await showUssdSavedDialog(
      context,
      existing: existing ??
          (ZteClient.isValidUssd(drafted) ? UssdSaved(code: drafted) : null),
    );
    if (result == null || !mounted) return;
    final next = upsertUssdCode(_saved, result);
    setState(() => _saved = next);
    await saveUssdSaved(next);
  }

  Future<void> _removeSaved(String code) async {
    final ok = await confirmAction(
      context,
      icon: Icons.delete_outline,
      title: 'Remove $code?',
      message: 'The shortcut goes away. It comes back if you dial it '
          'again, so this is always safe to undo by re-dialing.',
      confirmLabel: 'Remove',
      danger: true,
    );
    if (!ok || !mounted) return;
    final next = _saved.where((s) => s.code != code).toList();
    setState(() => _saved = next);
    await saveUssdSaved(next);
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

  void _clearAll() {
    setState(() => _codeCtrl.clear());
  }

  /// Same idea as [_key]/[_backspace], but writing the menu reply.
  /// Multi-level sessions need the navigation symbols too, so `*` and
  /// `#` are first-class answer keys (never inert).
  void _replyKey(String k) {
    setState(() => _replyCtrl.text += k);
  }

  void _replyBackspace() {
    final t = _replyCtrl.text;
    if (t.isEmpty) return;
    setState(() => _replyCtrl.text = t.substring(0, t.length - 1));
  }

  void _replyClearAll() {
    setState(() => _replyCtrl.clear());
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
        _replyViaKeyboard = false; // every new menu starts on the keypad
        _showRaw = false; // raw view never leaks across replies
        _history = pushUssdHistory(
          _history,
          UssdHistoryEntry(
            request: code,
            reply: r.success ? r.text : r.error,
            ok: r.success,
            at: DateTime.now(),
            rawReply: r.raw,
          ),
        );
      });
      _persistHistory();
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
      setState(() {
        _history = pushUssdHistory(
          _history,
          UssdHistoryEntry(
            request: code,
            reply: '$e',
            ok: false,
            at: DateTime.now(),
          ),
        );
      });
      _persistHistory();
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
          setState(() {
            _history = pushUssdHistory(
              _history,
              UssdHistoryEntry(
                request: '↳ $text',
                reply: msg,
                ok: false,
                at: DateTime.now(),
              ),
            );
          });
          _persistHistory();
        }
        widget.log('USSD reply not accepted (USSD_PROCESS result=not-accepted)');
        return;
      }
      final r = await widget.client.waitUssdReply();
      if (!mounted) return;
      setState(() {
        _last = r;
        _history = pushUssdHistory(
          _history,
          UssdHistoryEntry(
            request: '↳ $text',
            reply: r.success ? r.text : r.error,
            ok: r.success,
            at: DateTime.now(),
            rawReply: r.raw,
          ),
        );
        _replyCtrl.clear();
        _replyViaKeyboard = false; // next menu level: keypad again
        _showRaw = false;
      });
      _persistHistory();
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

  Future<void> _clearHistory() async {
    final ok = await confirmAction(
      context,
      icon: Icons.history,
      title: 'Clear USSD history?',
      message: '${_history.length} saved transaction${_history.length == 1 ? '' : 's'} '
          'disappear from every device this app runs on. This cannot be undone.',
      confirmLabel: 'Clear',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _history = []);
    await _persistHistory();
  }

  // ── Entry field (glass tile, stock dialer typography) ──────────────

  /// The primary entry field. Glass fill + faint border like every other
  /// inner tile in the app — the theme's opaque black Material fill is
  /// explicitly switched off ([filled] false) so the ambient background
  /// reads through. Focus paints an amber rim instead of a black box.
  Widget _dialerField(ZteColors c, bool invalidCode) {
    final focused = _codeFocus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: c.chip,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused ? c.accent.withAlpha(150) : c.borderSubtle,
          width: focused ? 1.2 : 0.8,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: c.accentGlow.withAlpha(36),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.dialpad, size: 17, color: c.textMuted),
          Expanded(
            child: TextField(
              key: const Key('ussd-code-field'),
              controller: _codeCtrl,
              focusNode: _codeFocus,
              keyboardType: TextInputType.phone,
              textAlign: TextAlign.center,
              cursorColor: c.accent,
              cursorWidth: 2.5,
              style: TextStyle(
                color: invalidCode ? c.danger : c.textPrimary,
                fontSize: 29,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              decoration: InputDecoration(
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                hintText: 'Dial a code — e.g. *312#',
                hintStyle: TextStyle(
                  color: c.textMuted.withAlpha(150),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.2,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _send(),
            ),
          ),
          SizedBox(
            width: 34,
            child: _codeCtrl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear code',
                    splashRadius: 16,
                    padding: EdgeInsets.zero,
                    onPressed: _busy ? null : _clearAll,
                    icon: Icon(
                      Icons.cancel_outlined,
                      size: 16,
                      color: c.textMuted,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// While a menu awaits a reply the primary field is *replaced* (not
  /// just disabled): the banner states which code owns the session so
  /// the menu text gets the whole vertical budget.
  Widget _sessionBanner(ZteColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: c.accent.withAlpha(20),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.accent.withAlpha(80)),
      ),
      child: Row(
        children: [
          Icon(Icons.phone_in_talk_outlined, size: 16, color: c.accentText),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SESSION OPEN — MENU AWAITS REPLY',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.accentText,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _codeCtrl.text.trim().isEmpty
                      ? 'USSD session'
                      : ZteClient.normalizeUssd(_codeCtrl.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _cancel,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('End', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── Reply panel: response text + inline answer bar ─────────────────

  /// Bounded, scrollable reply reader. Long menus (9 plans + Next on one
  /// screen) scroll inside the panel instead of stretching the card, and
  /// the cap grows while a reply is expected so nothing is clipped.
  Widget _responseBox(ZteColors c) {
    final r = _last;
    final ok = r?.success ?? true;
    // Raw = what the modem actually sent, before the sanitizer guessed
    // where the line breaks were. Offered only when the two differ.
    final rawAvailable = r != null && !r.rawWasClean;
    final showingRaw = rawAvailable && _showRaw;
    final text = r == null
        ? null
        : (showingRaw
              ? r.raw
              : (r.success ? r.text : r.error));
    return Container(
      key: const Key('ussd-response-box'),
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: 50,
        maxHeight: _replyMode ? 232 : 128,
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.chip,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: text != null && !ok
              ? c.danger.withAlpha(110)
              : c.borderSubtle,
        ),
      ),
      // The panel is height-capped, so its own text scaling is capped
      // too (same reasoning as the keypad): at 2x system text a single
      // placeholder line wraps past the cap and blows the layout.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (text != null)
              _responseToolbar(c, rawAvailable: rawAvailable),
            if (text == null)
              // Plain text (not an Align): the empty panel stays at its
              // minHeight instead of inflating to the maxHeight cap.
              Text(
                'No reply yet — send a code to begin a session.',
                style: TextStyle(color: c.textMuted, fontSize: 12.5),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      // Raw view is deliberately monospaced: control
                      // bytes and stray breaks only *look* wrong when you
                      // can see where the characters actually fall.
                      fontFamily: showingRaw ? 'monospace' : null,
                      color: showingRaw
                          ? c.textSecondary
                          : (ok ? c.textPrimary : c.danger),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Two small controls above the reply text: copy it anywhere, and flip
  /// between the rendered and the modem's raw text when they differ.
  Widget _responseToolbar(ZteColors c, {required bool rawAvailable}) {
    final r = _last!;
    final shown = _showRaw ? (r.raw) : (r.success ? r.text : r.error);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (rawAvailable)
            _toolChip(
              c,
              key: const Key('ussd-raw-toggle'),
              icon: Icons.raw_on,
              label: _showRaw ? 'RAW' : 'raw',
              active: _showRaw,
              tooltip: _showRaw
                  ? 'Show the repaired reply'
                  : "Show the modem's untouched text",
              onTap: () => setState(() => _showRaw = !_showRaw),
            ),
          if (rawAvailable) const SizedBox(width: 8),
          _toolChip(
            c,
            key: const Key('ussd-copy-reply'),
            icon: Icons.copy_all_outlined,
            label: 'copy',
            tooltip: 'Copy this reply to the clipboard',
            onTap: () => _copyToClipboard(shown, 'Reply copied'),
          ),
          const Spacer(),
          if (r.flag.isNotEmpty)
            Text(
              'flag ${r.flag}',
              style: TextStyle(color: c.textMuted, fontSize: 10),
            ),
        ],
      ),
    );
  }

  /// Small bordered text+icon control used by the response toolbar.
  Widget _toolChip(
    ZteColors c, {
    required Key key,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: active ? c.accent.withAlpha(45) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? c.accent.withAlpha(140) : c.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: active ? c.accentText : c.textMuted),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: active ? c.accentText : c.textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Clipboard with a visible confirmation (a copied USSD reply is the
  /// fastest way to hand evidence to a carrier chatbot).
  Future<void> _copyToClipboard(String text, String what) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    widget.log('$what (${text.length} chars)');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(what)));
  }

  /// Compact send control used inside the answer bar: submits the reply
  /// without scrolling down to the dial pad circle.
  Widget _inlineSend(ZteColors c, {required bool enabled}) {
    return Material(
      color: enabled ? c.accent : c.chip,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: const Key('ussd-reply-send'),
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? _reply : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.send_rounded,
                size: 15,
                color: enabled ? c.onAccent : c.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                'Send',
                style: TextStyle(
                  color: enabled ? c.onAccent : c.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Answer bar: mirrors what the keypad has typed (or hosts the phone
  /// keyboard when that path is toggled) and always carries an inline
  /// Send — adjacent to the response, above the keypad.
  Widget _replyBar(ZteColors c) {
    final ready = _replyCtrl.text.trim().isNotEmpty && !_busy;
    if (_replyViaKeyboard) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('ussd-reply-field'),
              controller: _replyCtrl,
              autofocus: true,
              keyboardType: TextInputType.phone,
              style: TextStyle(color: c.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                filled: false,
                isDense: true,
                labelText: 'Menu reply (e.g. 9)',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _reply(),
            ),
          ),
          const SizedBox(width: 8),
          _inlineSend(c, enabled: ready),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.accent.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.accent.withAlpha(70)),
      ),
      child: Row(
        children: [
          Icon(Icons.dialpad, size: 15, color: c.accentText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _replyCtrl.text.isEmpty
                  ? 'Answer with the keypad — digits, * and #'
                  : 'Reply: ${_replyCtrl.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _replyCtrl.text.isEmpty ? c.textMuted : c.textPrimary,
                fontSize: 12.5,
                fontWeight: _replyCtrl.text.isEmpty
                    ? FontWeight.w500
                    : FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (_replyCtrl.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear reply',
              splashRadius: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: _busy ? null : _replyClearAll,
              icon: Icon(Icons.close, size: 15, color: c.textMuted),
            ),
          const SizedBox(width: 4),
          _inlineSend(c, enabled: ready),
        ],
      ),
    );
  }

  // ── Keypad (one build path for both placements) ────────────────────

  /// Stock-dialer keypad (SSOT): borderless keys with a big digit + ITU
  /// letter sublabel, then a three-slot action row — save shortcut (or
  /// keyboard toggle while a menu awaits), gold call-style send circle,
  /// backspace (long-press clears all). Rows are fixed-height so the
  /// action row stays welded to `* 0 #`. In reply mode the same keys
  /// write the answer — including `*` and `#` for multi-level menus.
  static const _dialSubs = <String, String>{
    '1': '',
    '2': 'ABC',
    '3': 'DEF',
    '4': 'GHI',
    '5': 'JKL',
    '6': 'MNO',
    '7': 'PQRS',
    '8': 'TUV',
    '9': 'WXYZ',
    '*': '',
    '0': '+',
    '#': '',
  };

  Widget _dialKey(
    ZteColors c,
    String k, {
    VoidCallback? onTap,
    double scale = 1,
  }) {
    final sub = _dialSubs[k]!;
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      splashColor: c.accent.withAlpha(40),
      highlightColor: c.accent.withAlpha(24),
      onTap: onTap ?? () => _key(k),
      // The 0 key advertises '+' in its sublabel (stock dialer parity),
      // so it has to deliver it: tap = 0, long-press = '+'. Only in
      // dialer mode — a menu reply must stay exactly what was typed.
      onLongPress: (k == '0' && onTap == null)
          ? () => _key('+')
          : null,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              k,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 29,
                fontWeight: FontWeight.w500,
                height: 1.05,
              ),
            ),
            // Fixed slot keeps every row even whether or not the key
            // carries a sublabel (scaled with the system text size).
            SizedBox(
              height: 13 * scale,
              child: sub.isEmpty
                  ? null
                  : Text(
                      sub,
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2.1,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Keypad rows are fixed-height (the tight spacing is the feature), so
  /// the geometry has to follow the system text size instead of letting
  /// the glyphs outgrow their tiles. The pad itself is clamped at 1.5×:
  /// past that an oversized keypad stops fitting the phone it is meant
  /// for, while every other label in the console still scales fully.
  Widget _keypad() {
    final c = context.zc;
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    final reply = _replyMode;
    final replyEmpty = _replyCtrl.text.isEmpty;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.5,
          child: GridView.builder(
            key: const Key('ussd-keypad'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: keys.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              // Fixed rows: the old 1.4 aspect ratio sized tiles from the
              // card width (~83dp tall on a 412dp phone), leaving dead
              // air above and below every digit and pushing the action
              // row away from `* 0 #` — the reported gap. Fixed 58dp
              // rows + the sublabel slot track the text scale.
              mainAxisExtent: 58 * scale,
              mainAxisSpacing: 0,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (_, i) {
              final k = keys[i];
              // In reply mode every key — including the navigation
              // symbols — writes the answer.
              return reply
                  ? _dialKey(c, k, onTap: () => _replyKey(k), scale: scale)
                  : _dialKey(c, k, scale: scale);
            },
          ),
        ),
        const SizedBox(height: 2),
        Row(
          key: const Key('ussd-action-row'),
          children: [
            Expanded(
              child: Center(
                child: reply
                    ? // Keyboard is opt-in; the keypad is the default.
                    IconButton(
                        tooltip: _replyViaKeyboard
                            ? 'Answer with the keypad'
                            : 'Answer with the phone keyboard',
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _replyViaKeyboard = !_replyViaKeyboard,
                              ),
                        icon: Icon(
                          _replyViaKeyboard
                              ? Icons.dialpad_outlined
                              : Icons.keyboard_alt_outlined,
                          size: 24,
                          color: c.accentText,
                        ),
                      )
                    : IconButton(
                        tooltip: 'Save as shortcut',
                        onPressed: _busy ? null : () => _editSaved(),
                        icon: Icon(
                          Icons.bookmark_add_outlined,
                          size: 24,
                          color: c.accentText,
                        ),
                      ),
              ),
            ),
            Expanded(
              child: Center(
                child: Material(
                  color: _busy ? c.textMuted : c.accent,
                  shape: const CircleBorder(),
                  elevation: 0,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    // The gold circle is mode-honest: it dials a code
                    // normally and sends the reply when a menu awaits.
                    onTap: _busy
                        ? null
                        : (reply && !_replyViaKeyboard
                              ? (_replyCtrl.text.trim().isEmpty
                                    ? null
                                    : _reply)
                              : _send),
                    child: Padding(
                      // Compact circle: the action row must read as part
                      // of the keypad, not as a bar pinned to the floor.
                      padding: const EdgeInsets.all(17),
                      child: _busy
                          ? SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  c.onAccent,
                                ),
                              ),
                            )
                          : Icon(
                              reply && !_replyViaKeyboard
                                  ? Icons.send
                                  : Icons.call,
                              size: 28,
                              color: c.onAccent,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: IconButton(
                  tooltip: reply
                      ? 'Delete reply (long-press clears it)'
                      : 'Delete (long-press clears all)',
                  onPressed: _busy
                      ? null
                      : (reply
                            ? (replyEmpty ? null : _replyBackspace)
                            : (_codeCtrl.text.isEmpty ? null : _backspace)),
                  onLongPress: _busy
                      ? null
                      : (reply
                            ? (replyEmpty ? null : _replyClearAll)
                            : (_codeCtrl.text.isEmpty ? null : _clearAll)),
                  icon: Icon(
                    Icons.backspace_outlined,
                    size: 24,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sendCard(ZteColors c) {
    // Inline signal, zero layout shift: an undialable code tints itself
    // red — no error line ever appears or disappears under the layout.
    final code = _codeCtrl.text;
    final invalidCode =
        code.trim().isNotEmpty &&
        !ZteClient.isValidUssd(ZteClient.normalizeUssd(code));
    final reply = _replyMode;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Send USSD'),
          // Entry slot: dialer field normally, session banner while a
          // menu owns the session (the field would only eat height).
          if (reply) _sessionBanner(c) else _dialerField(c, invalidCode),
          const SizedBox(height: 8),
          // Session reader — bounded + scrollable so long menus never
          // clip and never push the keypad out of view.
          _responseBox(c),
          if (reply) ...[
            const SizedBox(height: 8),
            _replyBar(c),
          ],
          const SizedBox(height: 10),
          _keypad(),
          Center(
            child: TextButton(
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel session', style: TextStyle(fontSize: 12)),
            ),
          ),
          // Quick codes live at the bottom of the card in a single-line,
          // horizontally scrollable strip: it can never wrap to two rows
          // and push the dialer around, and it's hidden while a menu is
          // open (picking a code mid-session is out of context).
          if (!reply) ...[
            Divider(color: c.borderSubtle, height: 1),
            const SizedBox(height: 8),
            SavedUssdSection(
              saved: _saved,
              busy: _busy,
              onPickCode: (code) {
                setState(() => _codeCtrl.text = code);
              },
              onAdd: () => _editSaved(),
              onEdit: (s) => _editSaved(existing: s),
              onRemoveConfirm: _removeSaved,
            ),
          ],
        ],
      ),
    );
  }

  // ── History (bounded sub-container, never grows the page) ──────────

  Widget _historyTile(ZteColors c, UssdHistoryEntry h) {
    // Re-sanitized on render: entries stored before the USSD reply
    // sanitizer existed must not keep their mangled separators forever.
    final flat = ZteClient.sanitizeUssdText(h.reply).replaceAll(
      RegExp(r'\s*\n\s*'),
      ' · ',
    );
    return InkWell(
      // Recall, never auto-send: tapping puts the code back in the field
      // so you can read it before dialing.
      onTap: h.ok && h.request.startsWith('*')
          ? () => setState(() => _codeCtrl.text = h.request)
          : null,
      // Long-press = inspect: the full reply plus, when it differs, the
      // modem's untouched text. Tapping only recalls the code, so this
      // is the one place a stored entry can be audited.
      onLongPress: () => _showReplyInspector(h),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  h.ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 14,
                  color: h.ok ? c.live : c.danger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${h.request} · ${ZteClient.timeAgo(h.at)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 10.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              flat,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textPrimary, fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            Divider(color: c.borderSubtle, height: 1),
          ],
        ),
      ),
    );
  }

  /// Full-text inspector for one history entry: the repaired reply, the
  /// modem's raw text when they differ, and copy buttons for both.
  void _showReplyInspector(UssdHistoryEntry h) {
    final c = context.zc;
    final repaired = ZteClient.sanitizeUssdText(h.reply);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: GlassModal(
          icon: Icons.subject,
          title: h.request,
          subtitle: '${ZteClient.timeAgo(h.at)} · '
              '${h.ok ? 'ok' : 'failed'}',
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: SelectableText(
                    repaired,
                    style: TextStyle(
                      color: h.ok ? c.textPrimary : c.danger,
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              if (h.hasRaw) ...[
                const SizedBox(height: 14),
                Text(
                  'RAW — AS RECEIVED',
                  style: TextStyle(
                    color: c.accentText,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      h.rawReply,
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(
                      repaired,
                      'Reply copied',
                    ),
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    label: const Text('Copy'),
                  ),
                  if (h.hasRaw) ...[
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _copyToClipboard(
                        h.rawReply,
                        'Raw reply copied',
                      ),
                      icon: const Icon(Icons.raw_on, size: 15),
                      label: const Text('Copy raw'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
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
                onTap: _history.isEmpty ? null : _clearHistory,
                child: Text(
                  'clear',
                  style: TextStyle(
                    color: _history.isEmpty
                        ? c.textMuted.withAlpha(90)
                        : c.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  'Replies land here — kept across restarts.',
                  style: TextStyle(color: c.textMuted),
                ),
              ),
            )
          else
            // Dedicated scroll viewport (capped on both axes) so the list
            // scrolls itself instead of stretching the page.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Scrollbar(
                child: ListView.builder(
                  key: const Key('ussd-history-list'),
                  shrinkWrap: true,
                  primary: false,
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  itemCount: _history.length,
                  itemBuilder: (ctx, i) => _historyTile(c, _history[i]),
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
                  child: _sendCard(c),
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
              _sendCard(c),
              const SizedBox(height: 10),
              _historyCard(c),
            ],
          ),
        );
      },
    );
  }
}
