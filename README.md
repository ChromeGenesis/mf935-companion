# MF935 Companion

Desktop companion for the **ZTE MF935 MiFi** (MTN Broadband 4G / Airtel NG and
siblings): auto-login, live status, SMS inbox, USSD dialer, real carrier data
balance, and native alerts — everything the stock `192.168.0.1` web UI does,
without the browser.

## Features

- **Status** — battery ring, signal, operator, live throughput, online time,
  attached devices, carrier data balance (`*323*1#`, Airtel + MTN shapes,
  persisted, expiry chips + alerts, raw reply always attached)
- **SMS** — device/SIM inbox grouped by sender, search, unread filter,
  multi-select + bulk actions, swipe delete, send, center settings
- **USSD** — dialpad keypad, remembered codes, `*…#` normalization,
  interactive menu replies with next-page follow, session history
- **Info** — IMEI/IMSI/firmware/WAN, traffic stats + counter reset
- **Device** — connected clients, power-save, reboot/shutdown (confirmed)
- **Alerts** — low/full battery, no-signal + recovery, new SMS, inbox nearly
  full, data usage, billing-month rollover, bundle expiry, unreachable modem

## Run

```sh
flutter pub get
flutter run -d windows   # or -d linux
flutter test             # 12 tests, must stay green
```

Join the MF935 WiFi first; default gateway `192.168.0.1`, default password
`admin`. One login session per device — close the stock web UI tab so it does
not steal the session.

## How login works

The firmware hashes `SHA256(UPPER(SHA256(password)) + LD)` with a per-session
`LD` salt, all uppercase hex (reverse-engineered from the stock
`util.js`/`service.js`, verified live with `{"result":"0"}`).

## Layout

```
lib/
  main.dart         app shell: auth, poller, tray, nav, diagnostics
  zte_client.dart   modem wire protocol (goform GET/POST, codecs, parsing)
  status_tab.dart   status + balance card (owns balance lifecycle)
  sms_tab.dart      grouped inbox + bulk actions + send + settings
  ussd_tab.dart     dialer + recents + interactive sessions
  info_tab.dart     device info, traffic, data limit
  device_tab.dart   clients, power-save, reboot/shutdown
  poller.dart       30s poll + latched native alerts
  widgets.dart      GlassCard, GlassModal, PillSwitcher, EmptyState…
  theme.dart        Rhema-inspired dark tokens
  notifications.dart single toast entry point (SSOT)
```
