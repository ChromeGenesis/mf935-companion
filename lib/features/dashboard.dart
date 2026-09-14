library;

/// Dashboard shell (SSOT): session, polling, navigation and tab
/// composition. App bootstrap (`main()`, [ZteApp]) lives in `main.dart`;
/// connection + diagnostics panels live in `dashboard_panels.dart`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/poller.dart';
import '../core/capability.dart';
import '../core/diagnostics.dart';
import '../core/platform.dart';
import 'dashboard_panels.dart';
import 'info_tab.dart';
import '../core/notifications.dart';
import 'sidebar.dart';
import 'sms_tab.dart';
import 'status_tab.dart';
import '../core/theme.dart';
import 'ussd_tab.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WindowListener, TrayListener {
  late final ZteClient _client;
  ZtePoller? _poller;
  // Initialized once in main(); this handle only routes show() calls.
  final _notifications = FlutterLocalNotificationsPlugin();

  final _ipCtrl = TextEditingController(text: '192.168.0.1');
  final _passCtrl = TextEditingController();
  Map<String, dynamic> _status = {};
  final List<String> _log = [];
  String _loginMessage = '';
  bool? _loginOk;
  bool _busy = false;
  int _tab = 0;
  bool _narrow = false; // <640px: bottom nav; otherwise sidebar
  // Published balance feed (StatusTab writes, header fuse ring reads).
  final ValueNotifier<DataBalance?> _balanceFeed = ValueNotifier<DataBalance?>(
    null,
  );
  Timer? _cooldownTimer;
  DateTime? _cooldownUntil;
  final CapabilityRegistry capabilities = CapabilityRegistry();

  bool get _connected => _loginOk == true;

  /// Seconds left before another LOGIN may be sent. The firmware locks out
  /// (result=3) after a few rapid failures — and every retry resets its
  /// timer — so the UI enforces the back-off instead of trusting willpower.
  int get _cooldownLeft {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    _cooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldownLeft <= 0) {
        t.cancel();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
    }
    _client = ZteClient();
    _restoreSettings();
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _cooldownTimer?.cancel();
    _balanceFeed.dispose();
    _poller?.stop();
    _ipCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('gateway_ip') ?? '192.168.0.1';
    final pw = prefs.getString('admin_password') ?? 'admin';
    if (!mounted) return;
    setState(() {
      _ipCtrl.text = ip;
      _passCtrl.text = pw;
      _client.gatewayIp = ip;
    });
    _startupAuth();
  }

  /// Launch auth exactly like the browser UI behaves: if the saved session
  /// cookie is still valid, reuse it (no LOGIN needed); otherwise log in
  /// once with the remembered password (defaults to 'admin').
  Future<void> _startupAuth() async {
    try {
      final probe = await _client.getStatus(
        cmds: const ['battery_vol_percent'],
      );
      if (!mounted) return;
      if ('${probe['battery_vol_percent'] ?? ''}'.isNotEmpty) {
        setState(() {
          _status = probe;
          _loginOk = true;
          _loginMessage = 'Session restored — no login needed.';
        });
        _logLine('saved session still valid @ ${_client.gatewayIp}');
        _startPoller();
        return;
      }
    } catch (_) {
      // No usable session — fall through to auto-login.
    }
    if (!mounted) return;
    _logLine('no live session — auto-login…');
    await _doLogin();
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $line');
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _doLogin() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _loginMessage = '';
      _loginOk = null;
    });
    try {
      _client.gatewayIp = _ipCtrl.text.trim();
      final result = await _client.login(_passCtrl.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('gateway_ip', _client.gatewayIp);
      await prefs.setString('admin_password', _passCtrl.text);
      if (!mounted) return;
      setState(() {
        _loginOk = result.success;
        _loginMessage = result.success
            ? result.message
            : '${result.message}${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
      });
      _logLine(
        result.success
            ? 'LOGIN ok @ ${_client.gatewayIp}'
            : 'LOGIN FAILED: ${result.message}',
      );
      if (result.raw.isNotEmpty && !result.success) {
        _logLine('raw reply: ${result.raw}');
      }
      if (result.success) {
        _cooldownTimer?.cancel();
        _cooldownUntil = null;
        _startPoller();
      } else {
        // Read the real lockout counters (free GET) instead of guessing.
        final (failsLeft, lockSecs) = await _client.getLoginCounters();
        final counterInfo = failsLeft >= 0
            ? ' Attempts left: $failsLeft${lockSecs > 0 ? ', lockout lifts in ${lockSecs}s' : ''}.'
            : '';
        if (!mounted) return;
        setState(() {
          _loginMessage =
              '${_loginMessage.split('\n').first}$counterInfo'
              '${result.raw.isNotEmpty ? '\nRouter said: ${result.raw}' : ''}';
        });
        _logLine('counters: failsLeft=$failsLeft lockSecs=$lockSecs');
        _startCooldown(lockSecs > 0 ? lockSecs + 5 : 10);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loginOk = false;
        _loginMessage = 'Unexpected error: $e';
      });
      _logLine('LOGIN error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      _client.gatewayIp = _ipCtrl.text.trim();
      final (reachable, detail) = await _client.testConnection();
      String extra = '';
      if (reachable) {
        final caps = await _client.getAuthCaps();
        final ld = '${caps['LD'] ?? ''}';
        final rd = '${caps['RD'] ?? ''}';
        if (ld.isNotEmpty || rd.isNotEmpty) {
          extra = ' Auth tokens present (LD/RD) — firmware uses token login.';
        }
      }
      if (!mounted) return;
      setState(() {
        _loginMessage = '$detail$extra';
        if (!reachable) _loginOk = false;
      });
      _logLine(reachable ? 'REACHABLE: $detail$extra' : 'UNREACHABLE: $detail');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshNow() async {
    try {
      final s = await _client.getStatus();
      if (!mounted) return;
      setState(() => _status = s);
      _logLine('status poll ok');
    } catch (e) {
      _logLine('status poll failed: $e');
      if (!mounted) return;
      setState(() => _loginOk = false);
    }
  }

  Future<void> _notifyNow(String title, String body) =>
      showAlert(_notifications, title, body);

  /// Latch a firmware rejection once: capability matrix + log, no retries.
  void _markUnsupported(String goformId, String reason) {
    final isNew = capabilities.markUnsupported(goformId, reason);
    if (isNew) {
      _logLine('unsupported: $goformId — $reason (will not retry)');
      if (mounted) setState(() {});
    }
  }

  /// Phase 0 diagnostic export: app version + firmware + status +
  /// capability rejections + recent log. Copies to clipboard so it works
  /// on desktop and mobile without file access.
  Future<void> _exportDiagnostics() async {
    final text = buildDiagnosticText(
      appVersion: '1.0.0+1',
      gatewayIp: _client.gatewayIp,
      firmware: _status,
      status: _status,
      recentLog: _log,
      unsupported: capabilities.unsupported,
    );
    await Clipboard.setData(ClipboardData(text: text));
    _logLine(
      'diagnostic export copied (${text.length} chars, '
      '${capabilities.unsupported.length} unsupported cmds)',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics copied to clipboard')),
      );
    }
  }

  void _startPoller() {
    _poller?.stop();
    _poller = ZtePoller(
      client: _client,
      notifications: _notifications,
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
    )..start();
    _logLine('poller started (30s) — minimize to tray to keep polling');
  }

  /// Shell: sidebar on desktop, bare content on mobile (which gets
  /// the bottom nav instead).
  Widget _shell(Widget content) {
    if (_narrow) return content;
    return Row(
      children: [
        AppSidebar(
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
          connected: _connected,
          gatewayIp: _client.gatewayIp,
        ),
        Expanded(child: content),
      ],
    );
  }

  /// Header fuse ring: the "when does my data die" answer at title
  /// level, visible on every tab. Tapping jumps to Status. Renders
  /// nothing when there is no live bundle to count down to.
  Widget _expiryDial() {
    return ValueListenableBuilder<DataBalance?>(
      valueListenable: _balanceFeed,
      builder: (_, b, _) {
        final next = b?.nextExpiry;
        final exp = next?.expiry;
        if (!_connected || exp == null || !exp.isAfter(DateTime.now())) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ExpiryDial(
            bundle: next!,
            compact: _narrow,
            onTap: () => setState(() => _tab = 0),
          ),
        );
      },
    );
  }

  /// Status panes: side-by-side on desktop (log fills to the bottom),
  /// stacked + scrollable on narrow screens. One composition path (SSOT).
  Widget _statusBody(Widget left) {
    final conn = ConnectionPanel(
      ipCtrl: _ipCtrl,
      passCtrl: _passCtrl,
      busy: _busy,
      cooldownLeft: _cooldownLeft,
      connected: _connected,
      loginMessage: _loginMessage,
      loginOk: _loginOk,
      onLogin: _doLogin,
      onTest: _testConnection,
      onPasswordSubmit: _doLogin,
    );
    final log = DiagnosticsPanel(
      lines: _log,
      onClear: () => setState(() => _log.clear()),
      onExport: _exportDiagnostics,
      unsupported: capabilities.unsupported,
    );
    if (_narrow) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          children: [
            left,
            const SizedBox(height: 12),
            conn,
            const SizedBox(height: 10),
            SizedBox(height: 220, child: log),
          ],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 12,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: left,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 8,
          child: Column(
            children: [
              conn,
              const SizedBox(height: 10),
              Expanded(child: log),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void onWindowClose() async {
    if (!isDesktop) return;
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() async {
    if (!isDesktop) return;
    await windowManager.show();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (!isDesktop) return;
    if (menuItem.key == 'show') {
      await windowManager.show();
    } else if (menuItem.key == 'quit') {
      _poller?.stop();
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  // ── Layout: two panes, everything visible without scrolling ──
  @override
  Widget build(BuildContext context) {
    final c = context.zc;

    final pill = !_connected
        ? StatusPill(label: 'Disconnected', color: c.danger)
        : StatusPill(label: 'Connected · ${_client.gatewayIp}', color: c.live);

    _narrow = MediaQuery.sizeOf(context).width < 640;

    return Scaffold(
      body: AmbientBackground(
        child: _shell(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: Column(
              children: [
                // ── Header ──
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.accent.withAlpha(30),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: c.accent.withAlpha(110)),
                      ),
                      child: Icon(
                        Icons.wifi_tethering,
                        color: c.accentText,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MiFi Companion',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'ZTE MiFi dashboard · battery · signal · data',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _expiryDial(),
                    pill,
                  ],
                ),
                const SizedBox(height: 12),
                // ── Tab content ──
                Expanded(
                  child: _tab == 0
                      ? _statusBody(
                          StatusTab(
                            client: _client,
                            connected: _connected,
                            status: _status,
                            log: _logLine,
                            notify: _notifyNow,
                            onRefreshNow: _refreshNow,
                            balanceFeed: _balanceFeed,
                            onJumpTab: (i) => setState(() => _tab = i),
                            onUnsupported: _markUnsupported,
                          ),
                        )
                      : _tab == 1
                      ? SmsTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        )
                      : _tab == 2
                      ? UssdTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                          onUnsupported: _markUnsupported,
                        )
                      : InfoTab(
                          client: _client,
                          connected: _connected,
                          log: _logLine,
                        ),
                ),
                if (_narrow) const SizedBox(height: 8),
                if (_narrow)
                  NavigationBar(
                    height: 56,
                    backgroundColor: Colors.transparent,
                    indicatorColor: c.accent.withAlpha(40),
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    labelTextStyle: WidgetStatePropertyAll(
                      TextStyle(color: c.textSecondary, fontSize: 11),
                    ),
                    destinations: [
                      NavigationDestination(
                        icon: Icon(
                          Icons.dashboard_outlined,
                          color: c.textMuted,
                        ),
                        selectedIcon: Icon(
                          Icons.dashboard,
                          color: c.accentText,
                        ),
                        label: 'Status',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.sms_outlined, color: c.textMuted),
                        selectedIcon: Icon(Icons.sms, color: c.accentText),
                        label: 'SMS',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.dialpad_outlined, color: c.textMuted),
                        selectedIcon: Icon(Icons.dialpad, color: c.accentText),
                        label: 'USSD',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.info_outline, color: c.textMuted),
                        selectedIcon: Icon(Icons.info, color: c.accentText),
                        label: 'Info',
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
