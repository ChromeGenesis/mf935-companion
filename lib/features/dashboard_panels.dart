library;

/// Dashboard shell panels (SSOT): connection card and diagnostics log.
/// Stateless — [DashboardPage] owns auth, cooldown and log state.
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/ui_kit.dart';

/// Connection card: gateway, password, login/test, latched status.
class ConnectionPanel extends StatelessWidget {
  final TextEditingController ipCtrl;
  final TextEditingController passCtrl;
  final bool busy;
  final int cooldownLeft;
  final bool connected;
  final String loginMessage;
  final bool? loginOk;
  final VoidCallback? onLogin;
  final VoidCallback? onTest;
  final VoidCallback? onPasswordSubmit;

  const ConnectionPanel({
    super.key,
    required this.ipCtrl,
    required this.passCtrl,
    required this.busy,
    required this.cooldownLeft,
    required this.connected,
    required this.loginMessage,
    required this.loginOk,
    this.onLogin,
    this.onTest,
    this.onPasswordSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Connection'),
          TextField(
            controller: ipCtrl,
            decoration: const InputDecoration(
              labelText: 'Gateway IP',
              hintText: '192.168.0.1',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: passCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Admin password',
              hintText: 'Sticker on the MiFi',
              isDense: true,
            ),
            onSubmitted: (_) => busy ? null : onPasswordSubmit?.call(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (busy || cooldownLeft > 0) ? null : onLogin,
                  icon: const Icon(Icons.login, size: 15),
                  label: Text(
                    cooldownLeft > 0
                        ? 'Wait ${cooldownLeft}s'
                        : connected
                        ? 'Re-login'
                        : 'Login & poll',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onTest,
                  icon: const Icon(Icons.radar, size: 15),
                  label: const Text(
                    'Test',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (loginMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 64),
              child: SingleChildScrollView(
                child: SelectableText(
                  loginMessage,
                  style: TextStyle(
                    color: loginOk == true ? c.live : const Color(0xFFFCA5A5),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Diagnostics log: fills whatever height it's given (Expanded on
/// desktop, a fixed box on narrow).
class DiagnosticsPanel extends StatelessWidget {
  final List<String> lines;
  final VoidCallback? onClear;

  const DiagnosticsPanel({super.key, required this.lines, this.onClear});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'DIAGNOSTICS',
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onClear,
                child: Text(
                  'clear',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: lines.isEmpty
                ? Text(
                    'No events yet — log in to begin.',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      lines.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11.5,
                        height: 1.55,
                        color: Color(0xFFCBD5E1),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
