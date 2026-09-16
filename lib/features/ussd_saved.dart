library;

/// Saved USSD shortcuts domain (SSOT): model, persistence, CRUD dialog
/// and the saved-codes section. Stateless apart from the dialog form —
/// [UssdTab] owns the send flow; this module owns everything "saved".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dialogs.dart';
import '../core/theme.dart';
import '../core/zte_client.dart';

/// A saved USSD shortcut. Codes auto-save on send; the UI also allows
/// manual add / edit / delete (full CRUD).
class UssdSaved {
  final String code;
  final String label;

  const UssdSaved({required this.code, this.label = ''});

  String get displayName => label.trim().isEmpty ? code : label.trim();

  Map<String, dynamic> toJson() => {'code': code, 'label': label};

  factory UssdSaved.fromJson(Map<String, dynamic> j) =>
      UssdSaved(code: '${j['code'] ?? ''}', label: '${j['label'] ?? ''}');
}

const _savedKey = 'ussd_saved';
const _maxSaved = 12;

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
  final entry = UssdSaved(code: code, label: existing?.label ?? '');
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

/// Saved shortcuts list: tap to send, pencil to edit, trash to delete.
/// "+ Save" opens the CRUD dialog.
class SavedUssdSection extends StatelessWidget {
  final List<UssdSaved> saved;
  final bool busy;
  final ValueChanged<String> onSendCode;
  final VoidCallback onAdd;
  final ValueChanged<UssdSaved> onEdit;
  final ValueChanged<String> onDelete;

  const SavedUssdSection({
    super.key,
    required this.saved,
    required this.busy,
    required this.onSendCode,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
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
              onPressed: busy ? null : onAdd,
              icon: Icon(Icons.add, size: 15, color: c.accentText),
              label: Text(
                'Save',
                style: TextStyle(color: c.accentText, fontSize: 12),
              ),
            ),
          ],
        ),
        if (saved.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Sent codes auto-save here. Tap + to add one manually.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
          )
        else
          for (final s in saved)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: c.chip,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Row(
                  children: [
                    InkWell(
                      onTap: busy ? null : () => onSendCode(s.code),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.north_west,
                          size: 14,
                          color: c.accentText,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: busy ? null : () => onSendCode(s.code),
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
                                  FontFeature.tabularFigures(),
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
                      onPressed: busy ? null : () => onEdit(s),
                      icon: Icon(
                        Icons.edit_outlined,
                        color: c.textMuted,
                        size: 16,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Delete ${s.displayName}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onDelete(s.code),
                      icon: Icon(
                        Icons.delete_outline,
                        color: c.danger,
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
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
    Navigator.of(
      context,
    ).pop(UssdSaved(code: code, label: _labelCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final code = _codeCtrl.text;
    final valid =
        code.trim().isEmpty ||
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
              onPressed: valid && code.trim().isNotEmpty ? _submit : null,
              child: Text(widget.existing == null ? 'Save' : 'Update'),
            ),
          ],
        ),
      ],
    );
  }
}
