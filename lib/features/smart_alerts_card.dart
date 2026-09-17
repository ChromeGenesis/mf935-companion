library;

/// Smart-alerts settings card (SSOT): per-alert enable toggles +
/// quiet-period selector. Self-contained: reads/writes
/// [SmartAlertStore] directly so the dashboard never plumbs it.
import 'package:flutter/material.dart';

import '../core/smart_alerts.dart';
import '../core/theme.dart';
import '../core/ui_kit.dart';

const _quietOptions = <int>[0, 15, 30, 60, 120];

String _quietLabel(int m) =>
    m <= 0 ? 'Off' : (m < 60 ? '${m}m' : '${m ~/ 60}h');

class SmartAlertsCard extends StatefulWidget {
  const SmartAlertsCard({super.key});

  @override
  State<SmartAlertsCard> createState() => _SmartAlertsCardState();
}

class _SmartAlertsCardState extends State<SmartAlertsCard> {
  SmartAlertSettings? _settings;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Prefs failure must degrade to defaults, never to a stuck spinner:
  /// the card is settings UI, not load-bearing.
  Future<void> _load() async {
    SmartAlertSettings s;
    try {
      s = await SmartAlertStore.loadSettings();
    } catch (_) {
      s = SmartAlertSettings.defaults();
    }
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _save(SmartAlertSettings s) async {
    setState(() {
      _settings = s;
      _busy = true;
    });
    await SmartAlertStore.saveSettings(s);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final s = _settings;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withAlpha(90)),
                ),
                child: Icon(
                  Icons.notifications_active_outlined,
                  size: 17,
                  color: c.accentText,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SectionLabel('Smart alerts')),
              if (_busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.accentText,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Evidence in every notification — never a vague title. '
            'Each alert fires once per episode, then stays quiet.',
            style: TextStyle(color: c.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (s == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(),
              ),
            )
          else ...[
            for (final id in SmartAlertId.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            smartAlertTitle(id),
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            smartAlertBlurb(id),
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: s.isEnabled(id),
                      activeThumbColor: c.accentText,
                      onChanged: (v) {
                        final next = Map<SmartAlertId, bool>.from(s.enabled)
                          ..[id] = v;
                        _save(
                          SmartAlertSettings(
                            enabled: next,
                            quietMinutes: s.quietMinutes,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Quiet period after each alert',
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 8),
                PillSwitcher<int>(
                  options: [
                    for (final m in _quietOptions)
                      PillOption(value: m, label: _quietLabel(m)),
                  ],
                  selected: s.quietMinutes,
                  onChanged: (m) => _save(
                    SmartAlertSettings(
                      enabled: s.enabled,
                      quietMinutes: m,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
