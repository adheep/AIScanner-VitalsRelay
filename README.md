# Vitals Relay

An iPhone app that reads Apple Watch health data out of HealthKit and streams it
to the AIScanner WebApp over your LAN, plus an optional Apple Watch app that
makes heart rate genuinely live.

```
Apple Watch Ultra                iPhone                        Your PC
─────────────────                ──────                        ───────
 workout session ──┐
   heart rate 1 Hz │  WatchConnectivity
                   └──────────────► VitalsRelay ──── WebSocket ────► WebApp
 HealthKit sync ──────────────────►      ▲            JSON frames    /ws/vitals
   SpO2, respiration, steps…            │
                                   HKAnchoredObjectQuery
```

The phone app is standalone. If the watch app never installs — sideloading a
watchOS bundle is the least reliable thing in this whole stack — you still get
every metric, just with the Watch's own sync latency on heart rate.

---

## Read this before you build

**Two of the metrics you asked for are not continuously measured by the Watch,
and no app can change that.**

| Metric | How the Watch actually samples it |
|---|---|
| Heart rate | Continuous during a workout, every few minutes otherwise |
| Blood oxygen | Periodic background spot-checks, roughly hourly, and only when still. Not a stream |
| Respiratory rate | Almost exclusively during sleep |
| Steps, energy, distance | Continuous, aggregated |

So "real-time SpO2 and respiration" is not achievable — the sensor is not
running. What this app gives you is the freshest reading that exists, forwarded
the moment it appears. Heart rate is the one that can be truly live, which is
what the watch app is for.

**Expected end-to-end latency:**

| Path | Latency |
|---|---|
| Heart rate, watch app running | ~1–2 s |
| Heart rate, phone only | seconds to several minutes |
| Heart rate, phone only, workout running on the Watch | seconds |
| SpO2 / respiratory rate | whenever the Watch next measures |
| Steps / energy / distance | 20 s refresh of the daily total |

The phone-only heart-rate figure is why the watch app exists. If it will not
install, the practical workaround is to **start any workout on the Watch** —
that alone tightens sync to seconds.

---

## Getting an IPA without a Mac

Xcode is macOS-only, so the build has to happen on a Mac somewhere. GitHub's
macOS runners are one, and they need no Apple certificate.

1. Push this folder to a GitHub repository. If it is not the repo root, edit
   `WORKDIR` at the top of [.github/workflows/ios-build.yml](.github/workflows/ios-build.yml)
   to its path, e.g. `MobileApp/iOS`.
2. Open **Actions → Build unsigned IPA → Run workflow**.
3. Download the `VitalsRelay-unsigned-ipa` artifact and unzip it.
4. Open Sideloadly on Windows, drop in `VitalsRelay.ipa`, sign with your Apple
   ID, install.

Public repositories get macOS runner minutes free. Private ones bill them at 10x
the Linux rate, so keep this repo public or watch the quota.

**Change the bundle identifier first.** `com.aiscanner.vitalsrelay` in
[project.yml](project.yml) may already be taken; a free Apple ID can only claim
an unregistered one. Change both the phone id and the watch id, keeping the
watch as `<phone-id>.watchkitapp` — watchOS pairs them by that exact string.

### If you do get to a Mac

```sh
brew install xcodegen
xcodegen generate
open VitalsRelay.xcodeproj
```

Set your team in Signing & Capabilities, plug in the phone, run. This installs
the watch app to the paired Watch automatically and sidesteps every signing
problem below. If you can borrow a Mac for twenty minutes, do that instead.

---

## Using it

1. Start the WebApp: `python run.py` (or `--https`), and note the LAN address it
   prints.
2. On the phone, type just the host and port — `192.168.1.42:8000`. The scheme
   and the `/ws/vitals` path are filled in.
3. Tap **Start relaying**. Grant Health access, then allow the local-network
   prompt.
4. Leave **Accept self-signed certificate** on if the WebApp runs with `--https`.
   That exception is pinned to the one host you typed.

Keep the app in the foreground. Background relaying works only while the
HealthKit background-delivery entitlement survives signing, so the screen-awake
toggle is on by default.

---

## Wire format

JSON text frames, phone to server, one-way. Timestamps are **epoch
milliseconds** — `datetime.fromtimestamp(ms / 1000)` in Python.

Sent once on connect:

```json
{
  "type": "hello",
  "deviceId": "9F1C…",
  "deviceName": "iPhone",
  "appVersion": "1.0",
  "sentAt": 1756192800000,
  "metrics": ["heartRate", "respiratoryRate", "oxygenSaturation", "steps", "..."]
}
```

Then, batched every 250 ms while there is anything to send:

```json
{
  "type": "vitals",
  "deviceId": "9F1C…",
  "deviceName": "iPhone",
  "sentAt": 1756192801250,
  "samples": [
    {
      "metric": "heartRate",
      "value": 72,
      "unit": "bpm",
      "start": 1756192800000,
      "end": 1756192801000,
      "source": "watch-live"
    }
  ]
}
```

`source` is the field that matters downstream:

- `watch-live` — off the workout session, sub-second old.
- `healthkit` — read on the phone, as stale as the last Watch sync.

**`steps`, `activeEnergy` and `distance` are running totals for the day.**
Replace the previous value; never add to it. Everything else is a point reading.

Metric names, all lowerCamelCase and stable: `heartRate`, `restingHeartRate`,
`heartRateVariability`, `respiratoryRate`, `oxygenSaturation`,
`wristTemperature`, `walkingHeartRateAverage`, `vo2Max`, `steps`,
`activeEnergy`, `distance`.

### Minimal server side

Fits the shape already in `backend/ws.py`:

```python
@app.websocket("/ws/vitals")
async def ws_vitals(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        while True:
            message = json.loads(await websocket.receive_text())
            if message.get("type") != "vitals":
                continue
            for sample in message["samples"]:
                LATEST_VITALS[sample["metric"]] = sample
                EVENTS.publish("vitals.sample", **sample)
    except WebSocketDisconnect:
        pass
```

The phone sends **text** frames, so `receive_text()` is correct as written. The
socket is one-way — the server never has to reply, though a `pong` costs nothing
if you want one for debugging.

---

## Entitlement fallbacks

Free Apple IDs grant a limited set of capabilities, and which ones is not
documented anywhere Apple will commit to. If signing fails or the app misbehaves,
work down this list:

1. **Signing fails mentioning `healthkit.background-delivery`** — delete that one
   key from [VitalsRelay/VitalsRelay.entitlements](VitalsRelay/VitalsRelay.entitlements)
   and rebuild. The app detects the loss at runtime, posts a note, and keeps
   relaying in the foreground.
2. **The Health permission sheet never appears** — the HealthKit entitlement did
   not survive re-signing. Confirm with `codesign -d --entitlements - VitalsRelay.app`
   on a Mac, or try Sideloadly's advanced entitlement options. Without HealthKit
   there is no phone-side data at all.
3. **Watch app does not appear on the Watch** — the common outcome. Check the CI
   log for the "Watch app embedded" step to rule out a build problem, then
   accept phone-only mode and start workouts on the Watch for tighter sync.
4. **App stops working after seven days** — free provisioning profiles expire on
   that cycle. Re-sign with Sideloadly; the app's stored device id and endpoint
   survive because they live in `UserDefaults`, which is preserved across
   re-signs of the same bundle id.

---

## Layout

| Path | What lives there |
|---|---|
| [project.yml](project.yml) | the whole Xcode project, as text |
| [.github/workflows/ios-build.yml](.github/workflows/ios-build.yml) | macOS runner → unsigned IPA |
| [Shared/VitalsWire.swift](Shared/VitalsWire.swift) | the wire contract, compiled into both apps |
| [Shared/HealthKitMapping.swift](Shared/HealthKitMapping.swift) | metric names ↔ HealthKit types and units |
| [VitalsRelay/AppModel.swift](VitalsRelay/AppModel.swift) | start/stop, and the merge of both data sources |
| [VitalsRelay/Health/HealthRelayService.swift](VitalsRelay/Health/HealthRelayService.swift) | anchored, observer and statistics queries |
| [VitalsRelay/Relay/VitalsSocket.swift](VitalsRelay/Relay/VitalsSocket.swift) | WebSocket, batching, reconnect, TLS exception |
| [VitalsRelay/Relay/RelayEndpoint.swift](VitalsRelay/Relay/RelayEndpoint.swift) | forgiving address parsing |
| [VitalsRelay/Watch/PhoneConnectivity.swift](VitalsRelay/Watch/PhoneConnectivity.swift) | phone end of the Watch link |
| [VitalsRelayWatch/WorkoutSessionManager.swift](VitalsRelayWatch/WorkoutSessionManager.swift) | the live heart-rate session |
| [VitalsRelayWatch/WatchLink.swift](VitalsRelayWatch/WatchLink.swift) | watch end of the link, batching and queueing |

`VitalsRelay.xcodeproj` is generated and gitignored on purpose — a `.pbxproj` is
unreadable in a diff and unmergeable, and `project.yml` is the same project in
eighty legible lines.

---

## Known limitations

- **Foreground-biased.** iOS has no background mode for "keep a socket open".
  What keeps this alive in the background is HealthKit waking the app for new
  samples, and the Watch waking it via WatchConnectivity — both best-effort.
- **One-way.** Inbound WebSocket frames are read and discarded. Accepting
  commands from the network would be a much larger surface than this is worth.
- **The self-signed exception is real.** It is scoped to the exact host you type,
  but it is still a bypass of certificate validation. Do not point this at
  anything outside your own network.
- **No history.** The outbox holds 200 samples and drops oldest when offline.
  Persistence belongs on the server, not on the phone.
