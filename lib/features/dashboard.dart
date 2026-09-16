library;

/// Dashboard shell (SSOT): session, polling, navigation and tab
/// composition. App bootstrap (`main()`, [ZteApp]) lives in `main.dart`.
/// Header is a collapsing sliver (TradeMum parity) — the countdown and
/// theme controls live in their feature cards, never in the header.
/// Connection + diagnostics panels live exclusively in Settings.
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
import '../core/signal_locator.dart';
import 'bottom_nav.dart';
import 'info_tab.dart';
import 'settings_tab.dart';
import 'signal_locator_widgets.dart';
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
  // Raw balance replies (MTN *323*4# / Airtel *323*1#): archived for
  // the Settings tab only — the primary screen surfaces parsed
  // results, never verbose modem text.
  final List<String> _balanceRawLog = [];
  String _loginMessage = '';
  bool? _loginOk;
  bool _busy = false;
  int _tab = 0;
  bool _narrow = false; // <640px: bottom nav; otherwise sidebar
  // Published balance feed (StatusTab writes; the dashboard balance
  // card reads it for the countdown pill).
  final ValueNotifier<DataBalance?> _balanceFeed = ValueNotifier<DataBalance?>(
    null,
  );
  final ValueNotifier<SignalSample?> _signalFeed = ValueNotifier<SignalSample?>(
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
    _signalFeed.dispose();
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

  /// Archive a raw balance reply for the Settings tab (verbose modem
  /// chatter never surfaces on the primary screen).
  void _logBalanceRaw(String reply) {
    if (reply.trim().isEmpty) return;
    setState(() {
      _balanceRawLog.insert(
        0,
        '${TimeOfDay.now().format(context)}  ${reply.trim()}',
      );
      if (_balanceRawLog.length > 60) _balanceRawLog.removeLast();
    });
  }

  /// Router signal locator: modal dialog on desktop, bottom sheet on
  /// mobile — grounded in RSRP/RSRQ/SINR metric analysis. Width-based
  /// (640px): desktop windows render the glass modal, phones get the
  /// opaque bottom sheet.
  Future<void> _openSignalLocator() async {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    if (narrow) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black54,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // Wrap-content: the sheet sizes itself to the readout, no
        // fixed 85% box with dead space underneath.
        builder: (_) => SignalLocatorSheet(
          signalFeed: _signalFeed,
          client: _client,
        ),
      );
    } else {
      await showGlassModal<void>(
        context,
        icon: Icons.explore_outlined,
        title: 'Router signal locator',
        subtitle: 'RSRP · RSRQ · SINR placement analysis',
        width: 620,
        body: SignalLocatorBody(
          signalFeed: _signalFeed,
          client: _client,
        ),
      );
    }
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

  /// Status body: read-only + glanceable. Connection + diagnostics live
  /// exclusively in Settings — Status never duplicates them.
  Widget _statusBody() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 4),
      child: StatusTab(
        client: _client,
        connected: _connected,
        status: _status,
        log: _logLine,
        notify: _notifyNow,
        onRefreshNow: _refreshNow,
        balanceFeed: _balanceFeed,
        signalFeed: _signalFeed,
        onOpenSignalLocator: _openSignalLocator,
        onBalanceRaw: _logBalanceRaw,
        onJumpTab: (i) => setState(() => _tab = i),
        onUnsupported: _markUnsupported,
      ),
    );
  }

  /// All five tab bodies, index-aligned with the nav. They live in an
  /// [IndexedStack] so switching tabs never disposes state — scroll
  /// offsets, selections, text fields and loaded data are exactly
  /// where you left them.
  List<Widget> _tabBodies() => [
    _statusBody(),
    SmsTab(client: _client, connected: _connected, log: _logLine),
    UssdTab(
      client: _client,
      connected: _connected,
      log: _logLine,
      onUnsupported: _markUnsupported,
    ),
    InfoTab(client: _client, connected: _connected, log: _logLine),
    SettingsTab(
      client: _client,
      connected: _connected,
      ipCtrl: _ipCtrl,
      passCtrl: _passCtrl,
      busy: _busy,
      cooldownLeft: _cooldownLeft,
      loginMessage: _loginMessage,
      loginOk: _loginOk,
      onLogin: _doLogin,
      onTest: _testConnection,
      onPasswordSubmit: _doLogin,
      logLines: _log,
      onClearLog: () => setState(() => _log.clear()),
      onExportDiagnostics: _exportDiagnostics,
      unsupported: capabilities.unsupported,
      balanceRawLog: _balanceRawLog,
      onClearBalanceLog: () => setState(() => _balanceRawLog.clear()),
      log: _logLine,
      onUnsupported: _markUnsupported,
    ),
  ];

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

  // ── Layout: collapsing sliver header + tab body ──
  // TradeMum parity: the header is a SliverAppBar inside a
  // NestedScrollView, so it collapses/scrolls smoothly with the body
  // while each tab keeps its own scrollable. The header carries the
  // brand only — countdown + theme live in their feature cards.
  @override
  Widget build(BuildContext context) {
    _narrow = MediaQuery.sizeOf(context).width < 640;

    // AnnotatedRegion carries the transparent-status-bar style (see
    // [ZSystemUI]): it rebuilds with the theme, so toggling light/dark
    // in Settings flips the status-bar icons with it.
    // No SafeAreas anywhere: content scrolls full-bleed beneath the OS
    // status + system bars (both transparent via edge-to-edge).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: ZSystemUI.overlay(context),
      // extendBody: the ambient background paints edge-to-edge behind
      // the floating dock — no flat Scaffold strip shows around it in
      // any theme. Tab scrolls carry bottom clearance so last rows
      // never hide under the pill.
      child: Scaffold(
      extendBody: true,
      body: AmbientBackground(
        child: _shell(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: NestedScrollView(
              physics: const BouncingScrollPhysics(),
              headerSliverBuilder: (ctx, innerScrolled) =>
                  [const ZSliverHeader()],
              body: Padding(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: _narrow ? 88 : 0,
                ),
                child: IndexedStack(index: _tab, children: _tabBodies()),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _narrow
          // Floating dock: generous margins on all sides so the bar
          // hovers over the ambient background instead of striping
          // the screen edge. The bar itself is untouched.
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: BottomNavBar(
                selected: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
            )
          : null,
      ),
    );
  }
}

/// Collapsing dashboard header (TradeMum `GlassSliverAppBar` parity):
/// transparent sliver, no pin — it scrolls away with the body and
/// reappears on scroll-up via the nested scroll coordination. Brand
/// only, full width: with the countdown + theme toggle relocated to
/// their feature cards, nothing competes for header space, so the
/// title never truncates. The text is additionally scale-down fitted
/// as a guard on very narrow phones.
class ZSliverHeader extends StatelessWidget {
  const ZSliverHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final narrow = MediaQuery.sizeOf(context).width < 640;
    return SliverAppBar(
      systemOverlayStyle: ZSystemUI.overlay(context),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      floating: false,
      pinned: false,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      toolbarHeight: 64,
      title: Row(
        mainAxisSize: MainAxisSize.max,
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
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'MiFi Companion',
                    maxLines: 1,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (!narrow)
                  Text(
                    'ZTE MiFi dashboard · battery · signal · data',
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
        ],
      ),
    );
  }
}
