# MF935 Companion Roadmap

A practical roadmap for turning MF935 Companion into a reliable, high-quality modem operations tool.

## Product North Star

Make modem problems obvious and modem actions safe:

- Know whether the problem is Wi-Fi, cellular signal, carrier congestion, or the modem.
- Know where to place the MiFi for the best real-world connection.
- Know what changed when the connection becomes unreliable.
- Keep every action reversible, explained, and honest about firmware support.

## Guardrails

- Prefer capabilities already exposed by the MF935 firmware.
- Never invent a metric when the modem does not report it.
- Treat unsupported write commands as unsupported, not as UI bugs.
- Keep polling lightweight and pause expensive work when the app is hidden.
- Store history locally first; no account or cloud backend is needed.
- Every new command needs a raw-response path and a failure message.
- Preserve mobile usability and the existing desktop-first visual language.

## Phase 0: Stability Baseline

- [x] Keep `flutter analyze` clean.
- [x] Keep the widget and parsing tests green.
- [x] Add tests for every new pure scoring, formatting, and classification helper.
- [x] Add a small modem capability matrix: read-only, writable, firmware-dependent.
- [x] Make unsupported firmware commands visible in the UI without repeated retries.
- [x] Replace generic `refused` messages with the modem result, command, and next action.
- [x] Add a lightweight diagnostic export containing app version, firmware, and recent errors.

**Done when:** the app can fail gracefully, explain why, and never spam a rejected command.

## Phase 1: Network Scout MVP

The first major feature. It helps the user physically find a better location for the MiFi without pretending to have GPS.

### Sampling engine

- [ ] Add a `NetworkSample` model with timestamp, signal bars, RSSI, LTE RSRP, network type, download rate, upload rate, and reachability.
- [ ] Add a foreground sampling session with a configurable interval, defaulting to 2 seconds.
- [ ] Prevent overlapping requests when a sample is still in flight.
- [ ] Stop sampling when the user leaves Scout mode.
- [ ] Show sample count, elapsed time, and current collection status.
- [ ] Keep the existing background poller separate from Scout sampling.

### Guided placement flow

- [ ] Add a Scout screen with `Start`, `Pause`, `Mark Spot`, and `Finish` actions.
- [ ] Let the user label a spot manually: `Desk`, `Window`, `Upstairs`, `Kitchen`, etc.
- [ ] Show the current live score and the best score so far.
- [ ] Require a short dwell period before accepting a spot result.
- [ ] Warn when the modem is disconnected or samples are stale.
- [ ] Show a clear result: `Best location: Upstairs window`.

### Scoring

- [ ] Score signal strength, stability, upload, download, and reachability separately.
- [ ] Weight stability and upload strongly enough that a volatile high signal does not win unfairly.
- [ ] Normalize missing metrics instead of treating missing data as zero.
- [ ] Show why a spot won: `best upload`, `most stable`, or `best overall`.
- [ ] Add a confidence label based on sample count and measurement duration.

### Results

- [ ] Show a ranked list of marked spots.
- [ ] Show min, max, average, and variation for each metric.
- [ ] Show a compact signal/throughput chart for each spot.
- [ ] Allow a session to be renamed, deleted, or cleared.
- [ ] Persist completed sessions locally.
- [ ] Export a plain-text or JSON report.

**Done when:** a user can walk around with the MiFi, mark three locations, and receive a defensible recommendation in under five minutes.

## Phase 2: Network Health

- [ ] Add a persistent health score with separate cellular, Wi-Fi, and modem-health components.
- [ ] Classify common states:
  - [ ] Strong and stable
  - [ ] Strong but volatile
  - [ ] Weak cellular signal
  - [ ] Good signal but poor throughput
  - [ ] Reachable modem with no usable internet
  - [ ] Modem unreachable
- [ ] Add a simple explanation beside every score.
- [ ] Track signal loss and recovery episodes.
- [ ] Track modem unreachable and recovery episodes.
- [ ] Track network-type changes such as LTE to fallback mode.
- [ ] Add notification cooldowns so health alerts do not become noise.
- [ ] Add a health-history chart for the last hour and last day.

**Done when:** the dashboard answers “what is wrong?” instead of only displaying raw values.

## Phase 3: Connection Timeline

- [ ] Store important events locally with timestamps.
- [ ] Record login, logout, reconnect, signal loss, signal recovery, SMS, reboot, shutdown, and network changes.
- [ ] Record notable throughput drops and recoveries.
- [ ] Add a timeline view with severity and category filters.
- [ ] Make each event expandable to show raw supporting values.
- [ ] Add retention limits so history cannot grow forever.
- [ ] Add clear-history and export actions.

**Done when:** a user can inspect why the connection was bad earlier without watching the dashboard live.

## Phase 4: Built-In Speed Test

- [x] Add a small, cancellable speed-test service.
- [x] Measure latency before throughput.
- [x] Measure download and upload with explicit progress.
- [ ] Record signal and network type at the start and end.
- [ ] Store test results locally with a user label.
- [x] Show “signal problem” versus “carrier congestion” as a cautious diagnosis.
- [x] Avoid running tests automatically in the background.
- [x] Add a data-use warning before the first test.

**Done when:** users can compare two physical locations under comparable conditions.

## Phase 5: Smart Alerts

- [x] Add a placement-degraded alert when signal or upload falls sharply from baseline.
- [x] Add a repeated-outage alert with episode duration.
- [x] Add a network fallback alert.
- [x] Add “modem reachable, internet quality poor” alert when evidence supports it.
- [x] Add a configurable quiet period.
- [x] Add per-alert enable/disable controls.
- [x] Include the evidence in every notification, not just a vague title.

Example:

> Upload has been weak for 8 minutes. RSRP fell from -86 to -108 dBm while Wi-Fi remained connected.

## Phase 6: Connected-Device Intelligence

- [x] Keep connected-device count visible at all times.
- [x] Add first-seen and last-seen timestamps.
- [x] Detect device appearance and disappearance episodes.
- [x] Allow local device names such as `Work laptop` or `TV`.
- [x] Show connection duration.
- [x] Show per-device traffic only if the firmware exposes trustworthy values.
- [x] Notify when an important named device disappears.
- [x] Add a device-history view without retaining unnecessary identifying data.

## Phase 7: Battery and Travel Modes

- [x] Add a battery-health panel with charging state and drain rate.
- [x] Add a travel mode that reduces polling and expensive diagnostics.
- [x] Add a desk mode that keeps richer monitoring enabled.
- [x] Warn about prolonged charging at 100%.
- [x] Add battery-low and battery-full notification settings.
- [x] Only expose charge-control features after confirming firmware support.

## Phase 8: Incident Reports

- [x] Add `Create incident report` from the diagnostics panel.
- [x] Include firmware, network type, signal values, uptime, recent events, and recent speed tests.
- [x] Redact passwords, cookies, message bodies, and unnecessary device identifiers.
- [x] Export as text and JSON first.
- [x] Add a copy-to-clipboard action.
- [x] Add a short human summary suitable for a carrier support ticket.

## Phase 9: Advanced Features

These are valuable, but should wait until the core monitoring is trustworthy.

- [ ] Room-by-room signal heatmap using manually marked spots.
- [x] Best time of day for downloads based on local history.
- [x] Latency-focused gaming mode.
- [x] Sustained-download streaming mode.
- [x] Scheduled diagnostics.
- [x] Firmware-aware command capability discovery.
- [x] Safe scheduled reboot with a clear warning and cancellation path.
- [x] Local read-only API for other apps on the same machine.
- [ ] Compare two Scout sessions side by side.
- [ ] Optional encrypted backup of local history.

## Explicitly Out Of Scope For Now

- [ ] Cloud accounts or remote access.
- [ ] Automatic GPS tracking.
- [ ] Carrier-specific write commands without live verification.
- [ ] Automatic modem movement or physical robotics.
- [ ] Full network-management promises based only on signal bars.
- [ ] A giant analytics platform before the Scout MVP proves useful.

## Recommended Build Order

1. Stability baseline and capability matrix.
2. Network Scout sampling model and session engine.
3. Scout screen with manual spot labels.
4. Scoring, confidence, and ranked results.
5. Local persistence and export.
6. Health score and connection timeline.
7. Speed tests correlated with Scout samples.
8. Smart alerts and incident reports.
9. Connected-device history.
10. Advanced modes and heatmaps.

## Definition Of A High-Quality Release

- [ ] Works when the modem is offline.
- [ ] Works when firmware fields are missing.
- [ ] Does not spam polling or notifications.
- [ ] Does not claim unsupported modem capabilities.
- [ ] Explains every recommendation with visible evidence.
- [ ] Has focused tests for models, scoring, persistence, and failure states.
- [ ] Keeps the main dashboard calm; advanced details live in dedicated views.
- [ ] Has been checked at desktop minimum size and a narrow mobile layout.
