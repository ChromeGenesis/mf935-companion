import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'status_cards.dart';
import 'scout_card.dart';
import 'internet_check_card.dart';
import '../core/reachability.dart';
import '../core/theme.dart';
import 'speed_test_card.dart';
import '../core/session_recovery.dart' as recovery;
import '../core/signal_locator.dart';
import '../core/zte_client.dart';

/// Status tab (SSOT): hero (battery/carrier/signal + balance + live
/// metrics), fully-expanded connected devices, speed test and the
/// signal-locator launcher. All state-changing controls (reboot,
/// shutdown, connection, power management, diagnostics) live on the
/// Settings tab — Status is read-only + glanceable. The raw balance
/// modem reply is archived to the shell for the Settings tab; only
/// parsed results surface here.
class StatusTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final Map<String, dynamic> status;

  /// When [status] was last polled. With the session down the numbers
  /// stay on screen (they are still true) but they must be labelled
  /// with their age — see [recovery.staleBannerText].
  final DateTime? statusAt;

  final void Function(String) log;
  final Future<void> Function(String title, String body) notify;
  final Future<void> Function() onRefreshNow;

  /// Published snapshot feed: the dashboard balance card reads this
  /// for its countdown pill, so the "when does my data die" answer
  /// lives alongside the balance it describes.
  final ValueNotifier<DataBalance?> balanceFeed;

  /// Published live signal sample: the signal-locator modal/sheet
  /// reads this instead of polling on its own.
  final ValueNotifier<SignalSample?> signalFeed;

  /// Reachability probe used by the data-path card. Injectable so tests
  /// and previews never open a socket.
  final InternetProbe? probe;

  /// Fired with every completed reachability probe (the connection
  /// timeline records it).
  final void Function(ProbeResult result)? onProbeResult;

  /// Open the router signal-locator tool (modal on desktop, bottom
  /// sheet on mobile).
  final Future<void> Function()? onOpenSignalLocator;

  /// Archive a raw balance reply (verbose modem text lives in the
  /// Settings tab's raw data log, never on the primary screen).
  final void Function(String raw)? onBalanceRaw;

  /// Jump to another tab (SMS unread → inbox, devices → Device).
  /// Null-safe: tiles stay static when the shell doesn't provide it.
  final void Function(int tab)? onJumpTab;

  /// Report a firmware rejection once so the shell can latch it in the
  /// capability matrix instead of retrying.
  final void Function(String goformId, String reason)? onUnsupported;

  const StatusTab({
    super.key,
    required this.client,
    required this.connected,
    required this.status,
    this.statusAt,
    required this.log,
    required this.notify,
    required this.onRefreshNow,
    required this.balanceFeed,
    required this.signalFeed,
    this.probe,
    this.onProbeResult,
    this.onOpenSignalLocator,
    this.onBalanceRaw,
    this.onJumpTab,
    this.onUnsupported,
  });

  @override
  State<StatusTab> createState() => StatusTabState();
}

class StatusTabState extends State<StatusTab> {
  static const _balanceKey = 'data_balance_json';
  static const _balanceEvery = Duration(minutes: 20);

  DataBalance? _balance;
  bool _balanceBusy = false;
  Timer? _balanceTimer;
  final Set<String> _expiryNotified = {};

  // Connected clients: read-only, fully expanded on Status. Device
  // management controls live on the Settings tab.
  List<AttachedDevice> _devices = [];
  bool _devicesBusy = false;
  DateTime? _devicesAt;

  @override
  void initState() {
    super.initState();
    _loadCached();
    if (widget.connected) _onConnect();
  }

  @override
  void didUpdateWidget(StatusTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connected && !oldWidget.connected) {
      _loadCached();
      _onConnect();
    } else if (!widget.connected && oldWidget.connected) {
      _balanceTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _balanceTimer?.cancel();
    super.dispose();
  }

  void _onConnect() {
    _balanceTimer?.cancel();
    _balanceTimer = Timer.periodic(_balanceEvery, (_) => _refreshBalance());
    _refreshDevices();
    _refreshBalance();
    _refreshSignal();
  }

  /// Pull-to-refresh entry point (dashboard RefreshIndicator): one
  /// gesture re-polls status, balance, devices and the signal sample
  /// concurrently. Each leg guards its own busy flag, so overlapping
  /// drags collapse into a single round.
  Future<void> refreshAll() async {
    if (!widget.connected) return;
    await Future.wait([
      widget.onRefreshNow(),
      _refreshBalance(),
      _refreshDevices(),
      _refreshSignal(),
    ]);
  }

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_balanceKey);
      if (raw == null) return;
      final cached = DataBalance.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      if (!mounted) return;
      setState(() => _balance = cached);
      widget.balanceFeed.value = cached;
    } catch (_) {
      // Corrupt cache — a fresh dial fixes it.
    }
  }

  /// Dial the carrier's balance code (MTN *323*4#, Airtel *323*1#)
  /// and persist the snapshot. Deletion-proof: the modem
  /// is the source of truth, SMS is never consulted. The raw modem
  /// reply is archived for the Settings tab (verbose chatter) — the
  /// card here shows only parsed results.
  Future<void> _refreshBalance() async {
    if (!widget.connected || _balanceBusy) return;
    setState(() => _balanceBusy = true);
    try {
      final provider = ZteClient.carrierName(
        '${widget.status['network_provider'] ?? ''}',
      );
      final b = await widget.client.fetchDataBalance(providerHint: provider);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_balanceKey, jsonEncode(b.toJson()));
      if (!mounted) return;
      setState(() => _balance = b);
      widget.balanceFeed.value = b;
      widget.onBalanceRaw?.call(b.raw);
      widget.log(
        'balance: ${ZteClient.formatDataVolume(b.totalMb)} across ${b.bundles.length} bundles',
      );
      _checkExpiries(b);
    } catch (e) {
      widget.log('balance check failed: $e');
    } finally {
      if (mounted) setState(() => _balanceBusy = false);
    }
  }

  /// Pull one live signal sample into the published feed (best-effort;
  /// the locator tool also re-reads on its own 5s cadence while open).
  Future<void> _refreshSignal() async {
    if (!widget.connected) return;
    try {
      widget.signalFeed.value = await SignalSample.fromClient(widget.client);
    } catch (_) {
      // Read-only: keep the last sample on failure.
    }
  }

  /// Warn once per bundle when expiry is within 48h (or just passed).
  Future<void> _checkExpiries(DataBalance b) async {
    final now = DateTime.now();
    for (final bundle in b.bundles) {
      // Exhausted bundles never alert — nothing left to warn about.
      if (bundle.exhausted) continue;
      final exp = bundle.expiry;
      if (exp == null) continue;
      final key = '${bundle.name}|${exp.toIso8601String()}';
      if (_expiryNotified.contains(key)) continue;
      final left = exp.difference(now);
      if (left.isNegative && left.inDays > -2) {
        _expiryNotified.add(key);
        await widget.notify(
          'MF935: ${bundle.name} expired',
          'It ran out on ${_fmtDate(exp)}.',
        );
      } else if (!left.isNegative && left.inHours <= 48) {
        _expiryNotified.add(key);
        final when = left.inDays >= 1
            ? 'in ${left.inDays}d'
            : 'in ${left.inHours}h';
        await widget.notify(
          'MF935: ${bundle.name} expires $when',
          '${ZteClient.formatDataVolume(bundle.mb)} left till ${_fmtDate(exp)}.',
        );
      }
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  /// Attached-station list (separate endpoint, best-effort).
  Future<void> _refreshDevices() async {
    if (!widget.connected || _devicesBusy) return;
    setState(() => _devicesBusy = true);
    try {
      final devs = await widget.client.getConnectedDevices();
      if (!mounted) return;
      setState(() {
        _devices = devs;
        _devicesAt = DateTime.now();
      });
    } catch (_) {
      // Leave the last known list.
    } finally {
      if (mounted) setState(() => _devicesBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final battery = int.tryParse('${s['battery_vol_percent'] ?? ''}');
    final charging = '${s['battery_charging'] ?? ''}' == '1';
    final signal = int.tryParse('${s['signalbar'] ?? ''}');
    final provider = ZteClient.carrierName('${s['network_provider'] ?? '—'}');
    final netType = '${s['network_type'] ?? ''}';
    final netLine = netType.isEmpty || netType == '—'
        ? 'Log in to start polling'
        : '$netType · ${widget.client.gatewayIp}';
    final rx = double.tryParse('${s['monthly_rx_bytes'] ?? '0'}') ?? 0;
    final tx = double.tryParse('${s['monthly_tx_bytes'] ?? '0'}') ?? 0;
    final usedMb = (rx + tx) / (1024 * 1024);
    final liveDown = double.tryParse('${s['realtime_rx_thrpt'] ?? ''}');
    final liveUp = double.tryParse('${s['realtime_tx_thrpt'] ?? ''}');

    // Session lost but the last poll is still on screen: say so, and say
    // how old it is. Dimming the numbers is a second cue — the eye reads
    // "greyed" before it reads the sentence.
    final staleText = recovery.staleBannerText(
      sessionLive: widget.connected,
      lastAt: widget.statusAt,
    );
    final live = Column(
      children: [
        StatusHero(
          highlighted: widget.connected,
          battery: battery,
          charging: charging,
          provider: provider == '—' ? 'No device data yet' : provider,
          netLine: netLine,
          signal: signal,
          onOpenSignalLocator: widget.connected
              ? () => widget.onOpenSignalLocator?.call()
              : null,
          metrics: [
            (
              Icons.data_usage,
              widget.connected ? ZteClient.formatDataVolume(usedMb) : '—',
              'month usage',
            ),
            (
              Icons.speed_outlined,
              !widget.connected
                  ? '—'
                  : liveDown == null
                  ? 'n/a'
                  : ZteClient.formatRate(liveDown),
              'live down',
            ),
            (
              Icons.upload_outlined,
              !widget.connected
                  ? '—'
                  : liveUp == null
                  ? 'n/a'
                  : ZteClient.formatRate(liveUp),
              'live up',
            ),
          ],
          balance: BalanceSection(
            balance: _balance,
            busy: _balanceBusy,
            connected: widget.connected,
            onRefresh: _refreshBalance,
            balanceCode: ZteClient.balanceUssdForProvider(provider),
          ),
        ),
        const SizedBox(height: 10),
        // Data path: "reachable" and "online" are different questions, and
        // telling them apart is what people otherwise debug for hours.
        InternetCheckCard(
          connected: widget.connected,
          probe: widget.probe ?? IoInternetProbe(),
          log: widget.log,
          onResult: widget.onProbeResult,
        ),
        const SizedBox(height: 10),
        // Connected devices: always fully expanded — the height cap and
        // collapse toggle are gone; every client is visible at a glance.
        DevicesCard(
          devices: _devices,
          devicesAt: _devicesAt,
          busy: _devicesBusy,
          connected: widget.connected,
          onRefresh: _refreshDevices,
        ),
        const SizedBox(height: 10),
        SpeedTestCard(
          connected: widget.connected,
          log: widget.log,
          // Lets each run record the radio conditions at both ends.
          client: widget.client,
        ),
        const SizedBox(height: 10),
        // Scout measures the radio from wherever the MiFi is put, so it
        // sits with the other measurement tool rather than in Settings.
        NetworkScoutCard(
          client: widget.client,
          connected: widget.connected,
          log: widget.log,
        ),
      ],
    );

    if (staleText.isEmpty) return live;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaleStatusBanner(text: staleText),
        const SizedBox(height: 10),
        Opacity(opacity: 0.55, child: live),
      ],
    );
  }
}

/// Amber banner naming the age of the numbers below it. Rendered only
/// while the session is down and a previous poll is still on screen —
/// see [recovery.staleBannerText] for the wording rules.
class StaleStatusBanner extends StatelessWidget {
  final String text;
  const StaleStatusBanner({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    return Container(
      key: const Key('status-stale-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.accent.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.accent.withAlpha(120)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_toggle_off, size: 16, color: c.accentText),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
