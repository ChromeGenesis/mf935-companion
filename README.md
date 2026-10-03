# MF935 Companion

Desktop companion for the **ZTE MF935 MiFi** (MTN Broadband 4G / Airtel NG and
siblings): auto-login, live status, SMS inbox, USSD dialer, real carrier data
balance, and native alerts — everything the stock `192.168.0.1` web UI does,
without the browser.

## Features

- **Status** — battery ring, signal, operator, live throughput, online time,
  attached devices, carrier data balance (`*323*1#`, Airtel + MTN shapes,
  persisted, expiry chips + alerts, raw reply always attached). Values
  left over from a lost session are dimmed and stamped with their real age
  instead of pretending to be live
- **SMS** — device/SIM inbox grouped by sender, search, unread filter,
  multi-select + bulk actions, swipe delete, send, center settings
- **USSD** — glass dialer field, dialpad keypad (`0` long-press = `+`),
  remembered codes, `*…#` normalization, interactive menu replies with
  inline Send, multi-step shortcuts (`*312# → 3 → 1` in one confirmed tap),
  bounded session history, and a raw-reply view for when the reply
  sanitizer's guess looks wrong
- **Info** — IMEI/IMSI/firmware/WAN, traffic stats + counter reset
- **Data path** — router / DNS / HTTPS probes that separate "the MiFi is
  down" from "the MiFi is fine but the internet behind it is dead"
- **Network Scout** — sample the radio from wherever the MiFi sits, mark
  named spots, and get a ranked verdict with min/max/avg, a reason and a
  confidence label
- **Device** — connected clients, power-save, reboot/shutdown (confirmed)
- **Resilience** — session watchdog that re-logs-in after a reboot, a
  persisted activity log, and a filterable connection timeline that feeds
  incident reports
- **Alerts** — low/full battery, no-signal + recovery, new SMS, inbox nearly
  full, data usage, billing-month rollover, bundle expiry, unreachable modem

## Run

```sh
flutter pub get
flutter run -d windows   # or -d linux
flutter test             # 68 tests, must stay green
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
  main.dart             app shell + theme bootstrap (ZteApp)
  core/                 pure Dart: models, transport, decisions (no Flutter)
    zte_client.dart       modem wire protocol (goform GET/POST, cookies)
    zte_utils.dart        codecs, parsers, formatters, USSD reply sanitizer
    models.dart           LoginResult / UssdResult / SMS / balance shapes
    poller.dart           background poll loop + latched alerts
    session_recovery.dart reboot/session-loss policy for the watchdog
    log_store.dart        persisted, rotating activity log + typed events
    conn_timeline.dart    persisted connection timeline (state changes)
    network_scout.dart    scout sampling, spot scoring, ranking, export
    signal_locator.dart   RSRP/RSRQ/SINR sampling + 3GPP band guidance
    reachability.dart     gateway/DNS/HTTPS probe + fault localisation
    speed_test.dart       M-Lab ndt7 runner; speed_history.dart stores runs
    ussd_steps.dart       scripted multi-step USSD shortcut runner
    incident_report.dart  redacted text/JSON evidence bundle
    ui_kit.dart           GlassCard, SectionLabel, StatTile, PillSwitcher…
    theme.dart            dark/light tokens (ZteColors ThemeExtension)
  features/             Flutter widgets, one screen or card per file
    dashboard.dart         shell: session, polling, tabs, recovery watchdog
    status_tab.dart        hero, data path, devices, speed test, scout
    ussd_tab.dart          dialer, menus, history, shortcuts
    settings_tab.dart      connection, power, alerts, timeline, diagnostics
    scout_card.dart        Network Scout session + ranked results
    internet_check_card.dart  data-path probe card
    timeline_card.dart     filterable connection timeline
```

Conventions: domain logic lives in `lib/core` as pure Dart with unit tests,
UI lives in `lib/features`, widgets read colours through `context.zc`, and
persistent data goes through `SharedPreferences` keys owned by its domain
module.
