library;

/// Saved USSD shortcuts domain (SSOT): model, persistence, CRUD dialog,
/// the saved-codes chip row and the persisted session history.
/// Stateless apart from the dialog form — [UssdTab] owns the send flow;
/// this module owns everything "saved".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dialogs.dart';
import '../core/theme.dart';
import '../core/ussd_steps.dart';
import '../core/zte_client.dart';

/// A saved USSD shortcut. Codes auto-save on send; the UI also allows
/// manual add / edit (long-press a chip) / delete (chip ✕, confirmed).
///
/// [steps] are the menu answers that follow the code (`*312#` then `3`,
/// then `1`). A shortcut with steps is run as one confirmed action; a
/// plain code stays exactly as before — remembered, recalled, never
/// auto-sent.
class UssdSaved {
  final String code;
  final String label;
  final List<String> steps;

  UssdSaved({required this.code, this.label = '', List<String>? steps})
    : steps = List.unmodifiable(steps ?? const []);

  String get displayName => label.trim().isEmpty ? code : label.trim();

  /// True when this shortcut needs a confirmation sheet before it runs.
  bool get isMultiStep => steps.isNotEmpty;

  /// The shortcut as the runner wants it.
  UssdShortcut get shortcut => UssdShortcut(code, steps);

  Map<String, dynamic> toJson() => {
    'code': code,
    'label': label,
    if (steps.isNotEmpty) 'steps': steps,
  };

  factory UssdSaved.fromJson(Map<String, dynamic> j) => UssdSaved(
    code: '${j['code'] ?? ''}',
    label: '${j['label'] ?? ''}',
    steps: (j['steps'] as List?)?.map((e) => '$e').toList(),
  );
}

const _savedKey = 'ussd_saved';
const _historyKey = 'ussd_history_v1';
const _maxSaved = 12;
const _maxHistory = 30;

/// Load persisted shortcuts (empty when none/corrupt).
Future<List<UssdSaved>> loadUssdSaved() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_savedKey);
  if (raw == null) return [];
  try {
    return (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => UssdSaved.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  } catch (_) {
    return [];
  }
}

/// Persist shortcuts.
Future<void> saveUssdSaved(List<UssdSaved> saved) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _savedKey,
    jsonEncode(saved.map((e) => e.toJson()).toList()),
  );
}

/// Auto-remember a sent code (deduped against manual entries so an
/// edit survives the next send), most-recent first, capped.
List<UssdSaved> rememberUssdCode(List<UssdSaved> saved, String code) {
  final existing = saved.where((s) => s.code == code).firstOrNull;
  final entry = UssdSaved(
    code: code,
    label: existing?.label ?? '',
    steps: existing?.steps,
  );
  return [
    entry,
    ...saved.where((s) => s.code != code),
  ].take(_maxSaved).toList();
}

/// Insert-or-replace a shortcut (manual add / edit), capped.
List<UssdSaved> upsertUssdCode(List<UssdSaved> saved, UssdSaved result) {
  return [
    result,
    ...saved.where((s) => s.code != result.code),
  ].take(_maxSaved).toList();
}

// ── Session history (persisted) ─────────────────────────────────────

/// One USSD transaction worth remembering: the dialed code (or "↳ n"
/// for menu replies), the decoded reply/error, ok flag and timestamp.
/// Survives restarts — balance answers never die with the app.
///
/// [rawReply] keeps the modem's untouched text when it differs from
/// [reply]; entries saved before that field existed simply carry none.
class UssdHistoryEntry {
  final String request;
  final String reply;
  final bool ok;
  final DateTime at;

  /// The modem's unsanitized text when it differs from [reply]. The
  /// reply sanitizer is a set of heuristics about how this firmware
  /// mangles line breaks; keeping the untouched text alongside means a
  /// wrong guess can be audited later instead of argued about.
  final String rawReply;

  const UssdHistoryEntry({
    required this.request,
    required this.reply,
    required this.ok,
    required this.at,
    this.rawReply = '',
  });

  /// True when a raw capture exists and says something different.
  bool get hasRaw => rawReply.isNotEmpty && rawReply != reply;

  Map<String, dynamic> toJson() => {
    'request': request,
    'reply': reply,
    'ok': ok,
    'at': at.millisecondsSinceEpoch,
    if (hasRaw) 'raw': rawReply,
  };

  factory UssdHistoryEntry.fromJson(Map<String, dynamic> j) =>
      UssdHistoryEntry(
        request: '${j['request'] ?? ''}',
        reply: '${j['reply'] ?? ''}',
        ok: j['ok'] == true,
        at: DateTime.fromMillisecondsSinceEpoch(
          (j['at'] as num?)?.toInt() ?? 0,
        ),
        rawReply: '${j['raw'] ?? ''}',
      );
}

/// Load persisted history (newest first; empty on none/corrupt).
Future<List<UssdHistoryEntry>> loadUssdHistory() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_historyKey);
  if (raw == null) return [];
  try {
    return (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => UssdHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  } catch (_) {
    return [];
  }
}

/// Persist history (capped, newest first).
Future<void> saveUssdHistory(List<UssdHistoryEntry> history) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _historyKey,
    jsonEncode(history.take(_maxHistory).map((e) => e.toJson()).toList()),
  );
}

/// Prepend a new entry, capped.
List<UssdHistoryEntry> pushUssdHistory(
  List<UssdHistoryEntry> history,
  UssdHistoryEntry entry,
) => [entry, ...history].take(_maxHistory).toList();

/// Saved shortcuts as a bottom strip: a fixed-height, horizontally
/// scrollable line of chips. Tap a chip → fills the field (never
/// auto-sends); long-press → edit; the tiny ✕ removes (with a confirm).
///
/// The strip never wraps to a second row, so adding shortcuts can't push
/// the dialer, reply panel or keypad around — the old wrapping container
/// did exactly that (live-device bug report).
class SavedUssdSection extends StatelessWidget {
  final List<UssdSaved> saved;
  final bool busy;
  final ValueChanged<String> onPickCode;

  /// Called when a saved entry itself is picked (the tab decides whether
  /// that means "recall" or "run this script").
  final ValueChanged<UssdSaved> onPickSaved;

  final VoidCallback onAdd;
  final ValueChanged<UssdSaved> onEdit;
  final Future<void> Function(String code) onRemoveConfirm;

  const SavedUssdSection({
    super.key,
    required this.saved,
    required this.busy,
    required this.onPickCode,
    required this.onPickSaved,
    required this.onAdd,
    required this.onEdit,
    required this.onRemoveConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return SizedBox(
      // One line of chips, ever. Chips scroll sideways instead.
      height: 34,
      child: Row(
        children: [
          Icon(Icons.bookmark_border, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: saved.isEmpty
                ? Text(
                    'Sent codes are remembered here',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textMuted, fontSize: 11.5),
                  )
                : ListView.separated(
                    key: const Key('ussd-saved-strip'),
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.zero,
                    physics: const BouncingScrollPhysics(),
                    itemCount: saved.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final s = saved[i];
                      return Center(
                        child: _SavedChip(
                          saved: s,
                          busy: busy,
                          onTap: () {
                            onPickSaved(s);
                            onPickCode(s.code);
                          },
                          onLongPress: () => onEdit(s),
                          onDelete: () => onRemoveConfirm(s.code),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: busy ? null : onAdd,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.add, size: 16, color: c.accentText),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedChip extends StatelessWidget {
  final UssdSaved saved;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  const _SavedChip({
    required this.saved,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final hasLabel = saved.label.trim().isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: busy ? null : onTap,
      onLongPress: busy ? null : onLongPress,
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 3, top: 3, bottom: 3),
        decoration: BoxDecoration(
          color: c.accent.withAlpha(26),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.accent.withAlpha(70)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hasLabel ? saved.label.trim() : saved.code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 11.5,
                fontWeight: hasLabel ? FontWeight.w700 : FontWeight.w500,
                fontFeatures: hasLabel
                    ? null
                    : const [FontFeature.tabularFigures()],
              ),
            ),
            if (saved.isMultiStep) ...[
              const SizedBox(width: 4),
              Text(
                '→${saved.steps.join('→')}',
                style: TextStyle(
                  color: c.accentText,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (hasLabel) ...[
              const SizedBox(width: 4),
              Text(
                saved.code,
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 10.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            InkWell(
              onTap: busy ? null : onDelete,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close, size: 12, color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
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
  late final _codeCtrl = TextEditingController(
    text: widget.existing?.code ?? '',
  );
  late final _labelCtrl = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late final _stepsCtrl = TextEditingController(
    text: UssdShortcut.stepsToField(widget.existing?.steps ?? const []),
  );
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
    _stepsCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final code = ZteClient.normalizeUssd(_codeCtrl.text);
    if (!ZteClient.isValidUssd(code)) return;
    Navigator.of(context).pop(
      UssdSaved(
        code: code,
        label: _labelCtrl.text.trim(),
        steps: UssdShortcut.parseSteps(_stepsCtrl.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No error chrome: Save stays disabled until the code is dialable.
    final valid = ZteClient.isValidUssd(ZteClient.normalizeUssd(
      _codeCtrl.text,
    ));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _codeCtrl,
          focusNode: _codeFocus,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'USSD code',
            isDense: true,
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
        const SizedBox(height: 10),
        TextField(
          controller: _stepsCtrl,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            labelText: 'Menu steps (optional)',
            hintText: 'e.g. 3, 1 — answered in order after the menu opens',
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
              onPressed: valid ? _submit : null,
              child: Text(widget.existing == null ? 'Save' : 'Update'),
            ),
          ],
        ),
      ],
    );
  }
}
