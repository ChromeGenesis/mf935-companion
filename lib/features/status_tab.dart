import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'status_cards.dart';
import '../core/widgets.dart';
import '../core/zte_client.dart';

/// Status tab: device card, carrier data-balance card (*323*1# snapshot,
/// persisted — never guessed from SMS), and the stat tile grid.
///
/// Owns the balance lifecycle: cached snapshot on boot, refresh on
/// connect, re-dial every 20 min, expiry alerts. Main stays a shell.
class StatusTab extends StatefulWidget {
  final ZteClient client;
  final bool connected;
  final Map<String, dynamic> status;
  final void Function(String) log;
  final Future<void> Function(String title, String body) notify;
  final Future<void> Function() onRefreshNow;

  /// Published snapshot feed: main's header fuse ring listens to
  /// this, so the countdown lives app-wide, not in the hero card.
  final ValueNotifier<DataBalance?> balanceFeed;

  /// Jump to another tab (SMS unread → inbox, devices → Device).
  /// Null-safe: tiles stay static when the shell doesn't provide it.
  final void Function(int tab)? onJumpTab;

  const StatusTab({
    super.key,
    required this.client,
    required this.connected,
    required this.status,
    required this.log,
    required this.notify,
    required this.onRefreshNow,
    required this.balanceFeed,
    this.onJumpTab,
  });

  @override
  State<StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<StatusTab> {
  static const _balanceKey = 'data_balance_json';
  static const _balanceEvery = Duration(minutes: 20);

  DataBalance? _balance;
  bool _balanceBusy = false;
  Timer? _balanceTimer;
  final Set<String> _expiryNotified = {};

  // Data cap (firmware-side limit): lives here next to the month-usage
  // tile it constrains, not in Info.
  bool _limitOn = false;
  String _limitUnit = 'data';
  final _limitSizeCtrl = TextEditingController();
  final _limitAlertCtrl = TextEditingController();

  // Device management (consolidated from the Device tab): connected
  // clients, power-save presets, reboot/shutdown.
  List<AttachedDevice> _devices = [];
  bool _devicesBusy = false;
  DateTime? _devicesAt;
  bool _devicesOpen = false;
  String _powerSave = '';
  bool _powerBusy = false;

  @override
  void initState() {
    super.initState();
    _loadCached();
    if (widget.connected) _onConnect();
  }

  @override
  void didUpdateWidget(StatusTab old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) {
      _loadCached();
      _onConnect();
    } else if (!widget.connected && old.connected) {
      _balanceTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _balanceTimer?.cancel();
    _limitSizeCtrl.dispose();
    _limitAlertCtrl.dispose();
    super.dispose();
  }

  void _onConnect() {
    _balanceTimer?.cancel();
    _balanceTimer = Timer.periodic(_balanceEvery, (_) => _refreshBalance());
    _refreshDevices();
    _refreshBalance();
    _loadLimit();
    _loadPowerSave();
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

  /// Dial *323*1# and persist the snapshot. Deletion-proof: the modem
  /// is the source of truth, SMS is never consulted.
  Future<void> _refreshBalance() async {
    if (!widget.connected || _balanceBusy) return;
    setState(() => _balanceBusy = true);
    try {
      final b = await widget.client.fetchDataBalance();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_balanceKey, jsonEncode(b.toJson()));
      if (!mounted) return;
      setState(() => _balance = b);
      widget.balanceFeed.value = b;
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

  /// Tile honesty, no default shit: '—' when logged out, 'n/a' when the
  /// modem gave nothing, the value otherwise.
  String _tileText(dynamic raw) {
    if (!widget.connected) return '—';
    final v = '${raw ?? ''}';
    return v.isEmpty ? 'n/a' : v;
  }

  /// Attached-station list (separate endpoint, best-effort). Feeds the
  /// device-info card with one fetch.
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

  Future<void> _loadPowerSave() async {
    if (!widget.connected) return;
    try {
      final raw = await widget.client.getPowerSave();
      if (!mounted) return;
      setState(() => _powerSave = raw);
    } catch (e) {
      widget.log('power-save load failed: $e');
    }
  }

  Future<void> _applyPowerSave() async {
    if (!widget.connected) return;
    setState(() => _powerBusy = true);
    try {
      final mode = _powerSave;
      final ok = await widget.client.setPowerSave(mode);
      widget.log(ok ? 'power-save set to "$mode"' : 'power-save refused');
    } catch (e) {
      widget.log('power-save failed: $e');
    } finally {
      if (mounted) setState(() => _powerBusy = false);
    }
  }

  Future<void> _devicePowerAction(String kind) async {
    final confirm = await confirmAction(
      context,
      icon: kind == 'reboot' ? Icons.restart_alt : Icons.power_settings_new,
      title: kind == 'reboot' ? 'Reboot the MiFi?' : 'Shut down?',
      message: kind == 'reboot'
          ? 'WiFi drops for ~1 minute, then it comes back. The app will keep polling.'
          : 'The MiFi turns OFF. You will need to power it on physically.',
      confirmLabel: kind == 'reboot' ? 'Reboot' : 'Shut down',
    );
    if (!confirm) return;
    try {
      final raw = kind == 'reboot'
          ? await widget.client.reboot()
          : await widget.client.shutdown();
      widget.log('$kind sent. Modem said: $raw');
    } catch (e) {
      // Reboot/shutdown kills the HTTP connection mid-reply — a transport
      // error here usually MEANS it worked.
      widget.log('$kind sent (connection dropped as expected: $e)');
    }
  }

  /// Firmware data cap: load on connect, save on demand.
  Future<void> _loadLimit() async {
    if (!widget.connected) return;
    try {
      final limit = await widget.client.getDataLimit();
      if (!mounted) return;
      setState(() {
        _limitOn = '${limit['data_volume_limit_switch'] ?? ''}' == '1';
        final unit = '${limit['data_volume_limit_unit'] ?? ''}';
        _limitUnit = unit == 'time' ? 'time' : 'data';
        _limitSizeCtrl.text = '${limit['data_volume_limit_size'] ?? ''}';
        _limitAlertCtrl.text = '${limit['data_volume_alert_percent'] ?? ''}';
      });
    } catch (e) {
      widget.log('data limit load failed: $e');
    }
  }

  Future<void> _saveLimit() async {
    try {
      final ok = await widget.client.setDataLimit(
        enabled: _limitOn,
        unit: _limitUnit,
        size: _limitSizeCtrl.text.trim(),
        alertPercent: _limitAlertCtrl.text.trim(),
      );
      widget.log(ok ? 'data limit saved' : 'data limit refused');
    } catch (e) {
      widget.log('data limit failed: $e');
    }
    _loadLimit();
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
    final unread = int.tryParse('${s['sms_unread_num'] ?? ''}');
    final rx = double.tryParse('${s['monthly_rx_bytes'] ?? '0'}') ?? 0;
    final tx = double.tryParse('${s['monthly_tx_bytes'] ?? '0'}') ?? 0;
    final usedMb = (rx + tx) / (1024 * 1024);
    final liveDown = double.tryParse('${s['realtime_rx_thrpt'] ?? ''}');
    final liveUp = double.tryParse('${s['realtime_tx_thrpt'] ?? ''}');

    return Column(
      children: [
        StatusHero(
          highlighted: widget.connected,
          battery: battery,
          charging: charging,
          provider: provider == '—' ? 'No device data yet' : provider,
          netLine: netLine,
          signal: signal,
          unreadText: _tileText(s['sms_unread_num']),
          unreadAlive: widget.connected && (unread ?? 0) > 0,
          onUnreadTap:
              widget.onJumpTab == null ? null : () => widget.onJumpTab!(1),
          onRefreshNow:
              !widget.connected ? null : () => widget.onRefreshNow(),
          balance: BalanceSection(
            balance: _balance,
            busy: _balanceBusy,
            connected: widget.connected,
            onRefresh: _refreshBalance,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.data_usage,
                value: widget.connected
                    ? ZteClient.formatDataVolume(usedMb)
                    : '—',
                caption: 'month usage',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.speed_outlined,
                value: !widget.connected
                    ? '—'
                    : liveDown == null
                    ? 'n/a'
                    : ZteClient.formatRate(liveDown),
                caption: 'live down',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.upload_outlined,
                value: !widget.connected
                    ? '—'
                    : liveUp == null
                    ? 'n/a'
                    : ZteClient.formatRate(liveUp),
                caption: 'live up',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        DataLimitCard(
          limitOn: _limitOn,
          limitUnit: _limitUnit,
          sizeCtrl: _limitSizeCtrl,
          alertCtrl: _limitAlertCtrl,
          connected: widget.connected,
          onToggleOn: (v) => setState(() => _limitOn = v),
          onUnitChanged: (v) => setState(() => _limitUnit = v),
          onSave: _saveLimit,
        ),
        const SizedBox(height: 10),
        DevicesCard(
          devices: _devices,
          devicesAt: _devicesAt,
          busy: _devicesBusy,
          open: _devicesOpen,
          connected: widget.connected,
          onRefresh: _refreshDevices,
          onToggleOpen: () => setState(() => _devicesOpen = !_devicesOpen),
        ),
        const SizedBox(height: 10),
        PowerCard(
          powerSave: _powerSave,
          busy: _powerBusy,
          connected: widget.connected,
          onChanged: (v) => setState(() => _powerSave = v),
          onApply: _applyPowerSave,
        ),
        const SizedBox(height: 10),
        DeviceActionsCard(
          connected: widget.connected,
          onAction: _devicePowerAction,
        ),
      ],
    );
  }
}
