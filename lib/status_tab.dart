import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'widgets.dart';
import 'zte_client.dart';

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
  int? _deviceCount;

  // Data cap (firmware-side limit): lives here next to the month-usage
  // tile it constrains, not in Info.
  bool _limitOn = false;
  String _limitUnit = 'data';
  final _limitSizeCtrl = TextEditingController();
  final _limitAlertCtrl = TextEditingController();

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
    _refreshDeviceCount();
    _refreshBalance();
    _loadLimit();
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

  /// Attached-station count (separate endpoint, best-effort).
  Future<void> _refreshDeviceCount() async {
    try {
      final devs = await widget.client.getConnectedDevices();
      if (!mounted) return;
      setState(() => _deviceCount = devs.length);
    } catch (_) {
      // Leave the last known count; tile shows — when never fetched.
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

  /// Compact data-cap card under the tiles: the cap constrains the month
  /// usage above, so they share the pane. One header row (label + switch
  /// + save), one control row (unit + size + alert %).
  Widget _limitCard(ZteColors c) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SectionLabel('Data cap'),
              const Spacer(),
              Switch(
                value: _limitOn,
                activeThumbColor: c.accent,
                onChanged: !widget.connected
                    ? null
                    : (v) => setState(() => _limitOn = v),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: !widget.connected ? null : _saveLimit,
                child: const Text('Save'),
              ),
            ],
          ),
          Row(
            children: [
              PillSwitcher<String>(
                options: const [
                  PillOption(
                      value: 'data',
                      label: 'Data',
                      icon: Icons.data_usage_outlined),
                  PillOption(
                      value: 'time', label: 'Time', icon: Icons.schedule_outlined),
                ],
                selected: _limitUnit,
                enabled: widget.connected,
                onChanged: (v) => setState(() => _limitUnit = v),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _limitSizeCtrl,
                  enabled: widget.connected,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText:
                        _limitUnit == 'data' ? 'Size (modem units)' : 'Minutes',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _limitAlertCtrl,
                  enabled: widget.connected,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Alert %', isDense: true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Balance section: divider, total, bundles, raw. [divider]=false
  /// when embedded side-by-side (the gap already separates).
  Widget _balanceSection(ZteColors c, {bool divider = true}) {
    final b = _balance;
    // Biggest bundle: quota bars are relative shares of this. The modem
    // never reports plan totals, so absolute % would be a guess.
    final maxMb = (b?.bundles ?? const <DataBundle>[]).fold<double>(
      0,
      (m, x) => x.mb > m ? x.mb : m,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (divider) ...[
          const SizedBox(height: 10),
          Divider(color: c.borderSubtle, height: 1),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Text(
              'DATA BALANCE',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const Spacer(),
            if (b != null)
              Text(
                ZteClient.timeAgo(b.fetchedAt),
                style: TextStyle(color: c.textMuted, fontSize: 11.5),
              ),
            const SizedBox(width: 6),
            SizedBox(
              width: 30,
              height: 30,
              child: _balanceBusy
                  ? const Padding(
                      padding: EdgeInsets.all(7),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Re-check (*323*1#)',
                      padding: EdgeInsets.zero,
                      onPressed: (!widget.connected || _balanceBusy)
                          ? null
                          : _refreshBalance,
                      icon: Icon(Icons.refresh, color: c.accentText, size: 18),
                    ),
            ),
          ],
        ),
        if (b == null && !_balanceBusy)
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.connected
                      ? 'Dial *323*1# for the real balance.'
                      : 'Log in, then check the real balance.',
                  style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
              ),
              ElevatedButton(
                onPressed: (!widget.connected || _balanceBusy)
                    ? null
                    : _refreshBalance,
                child: const Text('Check'),
              ),
            ],
          )
        else if (b != null) ...[
          Text(
            ZteClient.formatDataVolume(b.totalMb),
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 23,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            b.bundles.isEmpty
                ? 'could not parse — raw reply below'
                : 'left across ${b.bundles.length} bundle${b.bundles.length == 1 ? '' : 's'}',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          // Hero keeps total + bundles + raw only; the live countdown
          // is the header fuse ring (main reads balanceFeed).
          for (final bundle in b.bundles)
            Opacity(
              // Exhausted bundles take less precedence: dimmed, last.
              opacity: bundle.exhausted ? 0.45 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            bundle.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12.5,
                              decoration: bundle.exhausted
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        Text(
                          ZteClient.formatDataVolume(bundle.mb),
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _expiryChip(c, bundle),
                      ],
                    ),
                    if (!bundle.exhausted && maxMb > 0) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: Container(
                          height: 3,
                          color: c.textMuted.withAlpha(45),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (bundle.mb / maxMb).clamp(0.02, 1.0),
                            child: Container(color: c.accentText),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          // Raw reply: ground truth one tap away, no matter how
          // the carrier rewords things next month.
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'Raw reply',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
            children: [
              SelectableText(
                b.raw,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Expiry chip: "exhausted" (grey, precedence over everything) for
  /// empty bundles, red when expired, amber under 3 days, muted
  /// otherwise, "expiry?" when unknown instead of guessing.
  Widget _expiryChip(ZteColors c, DataBundle bundle) {
    if (bundle.exhausted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.textMuted.withAlpha(20),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.textMuted.withAlpha(50)),
        ),
        child: Text(
          'exhausted',
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final exp = bundle.expiry;
    if (exp == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.textMuted.withAlpha(24),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.textMuted.withAlpha(60)),
        ),
        child: Text(
          'expiry?',
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final days = exp.difference(DateTime.now()).inDays;
    final Color color;
    final String label;
    if (days < 0) {
      color = c.danger;
      label = 'expired';
    } else if (days < 3) {
      color = c.accentText;
      label = days == 0 ? 'today' : '${days}d left';
    } else {
      color = c.textMuted;
      label = '${days}d left';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zc;
    final s = widget.status;
    final battery = int.tryParse('${s['battery_vol_percent'] ?? ''}');
    final charging = '${s['battery_charging'] ?? ''}' == '1';
    final signal = int.tryParse('${s['signalbar'] ?? ''}');
    final provider = ZteClient.carrierName('${s['network_provider'] ?? '—'}');
    final providerRaw = '${s['network_provider'] ?? ''}';
    final netType = '${s['network_type'] ?? ''}';
    final rx = double.tryParse('${s['monthly_rx_bytes'] ?? '0'}') ?? 0;
    final tx = double.tryParse('${s['monthly_tx_bytes'] ?? '0'}') ?? 0;
    final usedMb = (rx + tx) / (1024 * 1024);
    final liveDown = double.tryParse('${s['realtime_rx_thrpt'] ?? ''}');
    final liveUp = double.tryParse('${s['realtime_tx_thrpt'] ?? ''}');

    return Column(
      children: [
        GlassCard(
          highlighted: widget.connected,
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (ctx, cons) {
              // Wide hero: status and balance share the card horizontally
              // instead of stacking top-down. Narrow: stacked as before.
              // (Left pane is ~510px at the 980px minimum window.)
              final wide = cons.maxWidth > 480;
              final statusHead = Row(
                children: [
                  BatteryRing(percent: battery, charging: charging, size: 92),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          provider == '—' ? 'No device data yet' : provider,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          netType.isEmpty || netType == '—'
                              ? 'Log in to start polling'
                              : '$netType · ${providerRaw.isNotEmpty ? '$providerRaw · ' : ''}${widget.client.gatewayIp}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SignalBars(level: signal ?? -1, height: 22),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                signal == null
                                    ? 'signal n/a'
                                    : 'signal $signal/5',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh now',
                    onPressed: !widget.connected
                        ? null
                        : () => widget.onRefreshNow(),
                    icon: Icon(Icons.refresh, color: c.accentText, size: 20),
                  ),
                ],
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 11, child: statusHead),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 10,
                      child: _balanceSection(c, divider: false),
                    ),
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [statusHead, _balanceSection(c)],
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (ctx, cons) => GridView.count(
            // Three across when the pane earns it, two when narrow.
            crossAxisCount: cons.maxWidth > 430 ? 3 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.6,
            children: [
              StatTile(
                icon: Icons.data_usage,
                value: widget.connected
                    ? ZteClient.formatDataVolume(usedMb)
                    : '—',
                caption: 'month usage',
              ),
              StatTile(
                icon: Icons.speed_outlined,
                value: !widget.connected
                    ? '—'
                    : liveDown == null
                    ? 'n/a'
                    : ZteClient.formatRate(liveDown),
                caption: 'live down',
              ),
              StatTile(
                icon: Icons.upload_outlined,
                value: !widget.connected
                    ? '—'
                    : liveUp == null
                    ? 'n/a'
                    : ZteClient.formatRate(liveUp),
                caption: 'live up',
              ),
              StatTile(
                icon: Icons.markunread_mailbox_outlined,
                value: _tileText(s['sms_unread_num']),
                caption: 'SMS unread',
                valueColor:
                    _tileText(s['sms_unread_num']) != '—' &&
                        _tileText(s['sms_unread_num']) != '0' &&
                        _tileText(s['sms_unread_num']) != 'n/a'
                    ? c.accentText
                    : null,
                onTap: widget.onJumpTab == null
                    ? null
                    : () => widget.onJumpTab!(1),
              ),
              StatTile(
                icon: Icons.schedule_outlined,
                value: !widget.connected
                    ? '—'
                    : '${s['monthly_time'] ?? ''}'.isEmpty
                    ? 'n/a'
                    : ZteClient.formatOnlineTime(s['monthly_time']),
                caption: 'online',
              ),
              StatTile(
                icon: Icons.devices_outlined,
                value: _deviceCount == null
                    ? (widget.connected ? '…' : '—')
                    : '$_deviceCount',
                caption: 'devices',
                onTap: widget.onJumpTab == null
                    ? null
                    : () => widget.onJumpTab!(4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _limitCard(c),
      ],
    );
  }
}
