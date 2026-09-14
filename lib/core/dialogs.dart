library;

/// Glass modal dialog shell (SSOT): the ONE dialog shape in this app.
///
/// Extracted from the former `widgets.dart` god file. `widgets.dart`
/// re-exports this file so existing imports keep working unchanged.
import 'package:flutter/material.dart';

import 'theme.dart';

/// Rhema-style glass modal shell — the ONE dialog shape in this app.
/// Header (icon pill + title + subtitle + close), body, footer actions.
class GlassModal extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final double width;
  final bool danger;

  const GlassModal({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions,
    this.width = 440,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final accent = danger ? c.danger : c.accent;
    final accentText = danger ? c.danger : c.accentText;
    return Center(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: width,
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height - 88).clamp(
              280.0,
              640.0,
            ),
          ),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.surfaceLifted.withAlpha(245),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 32,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withAlpha(40),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: accent.withAlpha(90)),
                    ),
                    child: Icon(icon, color: accentText, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close, color: c.textMuted, size: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(child: SingleChildScrollView(child: body)),
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions!.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions![i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Show a [GlassModal] dialog. Single entry point — no raw AlertDialogs.
Future<T?> showGlassModal<T>(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  required Widget body,
  List<Widget>? actions,
  bool danger = false,
  double width = 440,
}) {
  return showDialog<T>(
    context: context,
    // Outside tap always dismisses — no trapped modals.
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassModal(
        icon: icon,
        title: title,
        subtitle: subtitle,
        body: body,
        actions: actions,
        danger: danger,
        width: width,
      ),
    ),
  );
}

/// Destructive/confirm prompt. Returns true when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = true,
}) async {
  final c = context.zc;
  final ok = await showGlassModal<bool>(
    context,
    icon: icon,
    title: title,
    danger: danger,
    body: Text(
      message,
      style: TextStyle(color: c.textSecondary, fontSize: 13.5, height: 1.5),
    ),
    actions: [
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        style: danger
            ? ElevatedButton.styleFrom(
                backgroundColor: c.danger,
                foregroundColor: Colors.white,
              )
            : null,
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(confirmLabel),
      ),
    ],
  );
  return ok == true;
}
