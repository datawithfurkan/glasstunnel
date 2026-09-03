# Mac Screen sharing instability audit

- Date: 2026-09-03
- Branch: `claude/screen-sharing-instability-audit-7c2782` (audited at `aab9db1d`, the 0.1.8 metadata commit)
- Symptom: the Mac Screen view in the web app sometimes goes black, and it only comes back after a page refresh.
- Method: full read of the screen path on all three tiers (PWA, Cloudflare Worker, Mac host), the 3-day macOS unified log of the running host app, browser-behaviour research for the WebRTC facts the fixes depend on, and a survey of the existing test lanes. No code was changed. Line numbers refer to the audited commit.

## Summary

The screen view has no health check once a frame has rendered, so anything that stops frames while the WebRTC connection stays up leaves a black (Safari) or frozen (Chrome) picture labelled "Screen ready". Several things stop frames without ending the connection: the Mac removes and re-adds its video track on a live peer with no renegotiation, a ScreenCaptureKit stream that dies is never restarted, and two copies of the screen panel are mounted at the same time on every device, so the hidden copy keeps restarting the visible one. Restarts themselves are fragile: a signaling-socket close tears down a healthy peer, a flow that fails before producing a stream is never retried, and restarts requested while the tab is hidden are dropped. A refresh works because it discards every piece of stale state at once.

The Mac log confirms the duplicate-panel behaviour (two `start` actions for the screen app 1 ms apart) and shows the Mac's own sockets to the Worker dropping roughly every 5 to 30 minutes over a VPN interface with heavy packet loss, so the fragile restart paths are exercised constantly. The log could not show the phone-side history because the host's screen lifecycle logging is info-level and is not persisted by macOS.

## Implementation status

Fixes landed on the audit branch after the report was written (commits in
branch order):

| Fix | Findings | Commit | Where |
| --- | --- | --- | --- |
| One panel mounted per layout, video kept across relay and signaling drops, signaling keepalive, retry with backoff, resume after hidden, Error status no longer tears down a live stream, Retry path cleanup, cached-workspace flag | S1, S5, S6, S9, S10, part of S4 | `c0470e5a` | PWA |
| Frame-liveness watchdog with "Screen paused" and automatic restart; a rendering picture outranks stale error text | S2 | `e061996a` | PWA |
| One sender per phone (track swap instead of remove/add), idle-frame keepalive at 1 fps, capture restart with backoff, display/wake/login observers, fallback pause while phones report live video, fallback rebuilt after relay reconnect, publish only on change, notice-level logging; protocol 0.2.3 | S3, S4, S7, S8, S12 | `e3b012e2` | Mac, protocol |
| Relay hub closes a Mac socket that missed three pings, alarm moved at most every 5 s, signaling hub queues for a silent host | S11 | `95adb5bc` | Worker |

Still open: S13 (same-profile duplicate tabs) and the S14 items.

## How the screen path works today

| Leg | Carries | Notes |
| --- | --- | --- |
| Phone to Worker `RelayHub` to Mac `RelayClient` | commands, hello, remote-app list, agent state, JPEG fallback frames (`relay_screen_frame`, 2 fps) | 20 s `relay_ping` from both ends; Worker fans host frames out to every phone |
| Phone to Worker `SignalingHub` to Mac `SignalingClient` | one `ping` envelope per video flow, then SDP offer/answer and ICE candidates | Mac is the offerer. No renegotiation exists anywhere. Phone socket has no keepalive |
| Mac `WebRTCPeer` to phone `RTCPeerConnection` | one video track (`gt-screen` in stream `gt-main`), one "control" data channel (hello, agent state, remote apps, 20 s heartbeat) | ICE consent keeps the connection "connected" even when no media flows |
| Mac capture | `Session.applyRemoteApps` computes the desired video apps (`enabled && available && hasVideo`), a per-agent reconciler starts (`addTrack` + `DisplayCapture`/`SCStream`) or stops (`removeTrack` + stop stream) | `RelayScreenCapture` runs a second `SCStream` for the JPEG fallback |

## Findings

Severity reflects how directly each item produces the reported symptom.

| ID | Tier | Severity | Finding |
| --- | --- | --- | --- |
| S1 | PWA | Critical | Two screen panels are mounted at once; the hidden one restarts the visible one |
| S2 | PWA | Critical | A rendering stream is never health-checked; a starved or muted track keeps "Screen ready" |
| S3 | Mac | High | The video track is removed and re-added on a live peer with no renegotiation |
| S4 | Mac | High | A capture stream that dies is never restarted |
| S5 | PWA | High | A video flow that fails without a stream is never retried; hidden-tab restarts are dropped |
| S6 | PWA | High | A signaling-socket close tears down a healthy video peer; the socket has no keepalive |
| S7 | Mac | Medium | The whole remote-app list is republished every 5 s, which clears phone state and echoes stale statuses |
| S8 | Mac | Medium | The JPEG fallback capture runs for the entire share and dies silently after a relay reconnect |
| S9 | PWA | Low | Every reconnect briefly marks screen sharing off from the cached workspace |
| S10 | PWA | Low | "Retry screen" sends three `start` actions and restarts the peer two or three times |
| S11 | Worker | Medium | A half-dead Mac socket is never detected server-side; screen `start` is acknowledged into the void |
| S12 | Mac | Medium | Screen lifecycle logging is info-level and not persisted; WebRTC and capture state changes are not logged |
| S13 | Design | Low | Two tabs of the same browser profile fight over one device identity |
| S14 | Various | Low | Smaller defects listed at the end |

### S1. Two screen panels are mounted at once

`apps/mobile-pwa/src/agents/AgentCarousel.tsx:392` renders the phone layout inside a `md:hidden` container and `:439` renders the desktop layout inside a `hidden md:grid` container. Both containers are always in the tree; CSS hides one of them. Both render `FocusedChat` for the selected app, and `FocusedChat` returns `ScreenRemotePanel` for the screen app (`:957`). So every device mounts two independent copies of the panel, each with its own `<video>`, render phase, retry timers and `startRequestedRef`.

Consequences:

- Each copy runs the start effect (`ScreenRemotePanel.tsx:113-130`), so opening the screen sends two `start` actions and calls `startVideoPeer()` twice; the second call aborts the first flow (`lib/store.ts:547`). The Mac log recorded exactly this at 12:37:57 today: two `remote app action received remoteAppId=screen ... action=start` lines 1 ms apart, both accepted.
- The hidden copy's `restartIfNeeded` (`ScreenRemotePanel.tsx:330-337`) runs on every `focus`, `online`, `pageshow` and `visibilitychange`. It is gated only by its own `status.canControl`, which depends on its own hidden `<video>` reporting a renderable frame. If that element never reaches a renderable state (browser-dependent for `display:none` video), the hidden copy calls `requestScreenStart()` plus `startVideoPeer()` on every such event after the first 6 s, tearing down the visible copy's healthy stream. Returning to the app is the most common trigger.
- Two sinks decode the same stream; each runs its own 250 ms probe, 1.2 s reattach retries, 7 s stall timer and 1.5 s diagnostics loop.

### S2. A rendering stream is never health-checked

`agents/screenVideoStatus.ts:51` decides "renderable" from `videoWidth`, `videoHeight` and `readyState` only. Those properties stay valid after frames stop, in every browser. Once the phase reaches `ready` the frame probe stops and diagnostics stop (`ScreenRemotePanel.tsx:282`); the track's `mute` event maps to `markSyncing`, which reads the same properties and flips straight back to `ready` (`:171`, `:245`); `restartIfNeeded` bails while `status.canControl` is true (`:332`). Nothing reads `track.muted`, `getStats()` frame counters or `requestVideoFrameCallback`.

Browser facts that matter here (verified against WebKit and Chromium sources during the audit):

- WebKit paints a remote track that is muted, ended or disabled black (`MediaPlayerPrivateMediaStreamAVFObjC::currentDisplayMode`, `PaintItBlack`). A track that merely stops receiving frames keeps its last image; a track WebKit mutes (renegotiation, some background/foreground transitions on iOS) is black.
- Chromium mutes a remote video track about one second after frames stop (frame-based, `VideoTrackAdapter`) and unmutes on the next frame, and it keeps the last frame on screen while muted. A static Mac screen therefore toggles `mute` constantly on Chrome, so `mute` alone cannot be the signal; frame counters can, but only if the Mac guarantees a minimum frame cadence (see S4 and fix 3).
- `connectionState` stays `connected` while ICE consent flows, regardless of media. A vanished peer reads `disconnected` after roughly 5 s and `failed` after 15 to 30 s.

Result: whenever frames stop while the connection stays up, the phone shows black (Safari) or a frozen frame (Chrome), the status stays "Screen ready", the controls stay enabled, and no automatic restart is possible. Only a refresh (a fresh `RTCPeerConnection`) recovers.

### S3. The video track is removed and re-added on a live peer

`apps/host-macos/Sources/Transport/Session.swift:893-895` calls `peer.removeVideoTrack` (`RTCPeerConnection.removeTrack`) whenever the screen app stops being `enabled && available && hasVideo`; `:852` calls `peer.addVideoTrack` (`addTrack`) when it becomes desired again. `WebRTCPeer.swift:184` leaves `peerConnectionShouldNegotiate` empty, and the only offer is created when the session is born (`SessionManager.swift:1400-1406`). libwebrtc will not reuse a transceiver that has ever sent (`FindFirstTransceiverForAddedTrack`), so the re-added track lands on a new m-section the phone never negotiates.

Phone-visible effect: after `removeTrack` the phone's receiver goes silent (black on Safari once muted, frozen on Chrome); after the later `addTrack` the phone still never sees a frame. The connection stays `connected`, so S2 hides it indefinitely.

Triggers found: turning sharing off and on from the Mac window (`RemoteAppController.setEnabled`), a Screen Recording permission flip false to true (`RemoteAppController.swift:450-458`, polled every 5 s from `AppState.swift:152`), and any remote-app publish where the screen app is momentarily not `enabled && available`. A phone-driven stop and start is safe only because the phone also closes its peer and re-pings, which makes the Mac build a fresh session.

### S4. A capture stream that dies is never restarted

`Capture/DisplayCapture.swift:127-129` reports `didStopWithError` as `.error`. `Session.swift:923-924` publishes "Screen unavailable" and leaves the dead binding in `captures`; `:848` then blocks any restart for that session. Nothing observes display sleep, display hot-plug, screen lock or system sleep anywhere in the host (no `NSWorkspace` observers), and `DisplayCapture.setActive` has no callers.

If the stream stops without an error callback (display sleep, a hot-plugged display, a sleeping Mac with the tunnel kept awake), frames simply stop and S2 applies. The Mac log shows display attach and detach events at 10:37:57 and 12:00:16 today and several yesterday; no ScreenCaptureKit errors were persisted, so the silent case is the one to plan for.

If the error path does fire, the phone drops its peer on the Error status (`store.ts:477`, `:1710`) and re-pings, and the new session builds a new capture, so recovery usually works. It fails when the stale Error status is republished (S7) during the one to two seconds the restart takes: the republish aborts the restart and nothing retries (S5).

### S5. A failed video flow is never retried; hidden-tab restarts are dropped

The panel's start effect only fires when `stream`, `hostOnline`, `screenSharingEnabled` or the quality callback change (`ScreenRemotePanel.tsx:131-139`). When the video flow closes without ever producing a stream (the 25 s connect timeout at `transport/startPeerFlow.ts:292`, a signaling close before connect, ICE failure) the store sets "Screen stream disconnected" (`store.ts:1628-1641`) and the panel shows a Retry button; no dependency changes, so nothing retries.

`startVideoPeer` returns immediately while the document is hidden (`store.ts:544`) and schedules nothing. On return, `restartIfNeeded` requires a stream (`:332`) and the app-level resume only forces a restart when the page was hidden for more than 1.5 s (`app/lifecycleRecovery.ts:2`). A flow that dropped during a short background stays down until the user taps Retry.

### S6. A signaling-socket close tears down a healthy video peer

`transport/startPeerFlow.ts:244-246` closes the whole flow (peer included) on any non-intentional signaling close, even after `peerConnected`. Signaling is only needed for the initial offer, answer and ICE candidates, so the close is harmless to media, yet it discards a working connection. The phone's signaling socket never sends anything after its one `ping` envelope; only the relay socket has a 20 s keepalive (`store.ts:509`). Idle NAT and carrier timeouts, iOS socket suspension, Worker deploys and Durable Object evictions all close it, and each close becomes a restart that then has to survive S1 and S5.

The Mac log shows what the network path looks like from the Mac's side: about twenty socket turnovers to the Worker between 05:51 and 11:55 today (POSIX errors 57 and 54, one full path loss at 08:15:28, two peer resets at 07:46), all over a VPN interface (`utun4`) with kernel-reported heavy loss. While the Mac's signaling client is reconnecting (about one second each time), `initiateWebRTC` drops any phone `ping` because `signaling` is nil (`SessionManager.swift:1400`), and the Worker "sends" pings into a socket it still believes is open (S11), so the phone's flow times out 25 s later and lands in S5.

### S7. The remote-app list is republished every 5 s

`AppState.swift:152` runs `refreshWindows` every 5 s, which calls `RemoteAppController.updateWindows` (`:444-448`); that always calls `publishRemoteApps`, which fires `onRemoteAppsChanged` (`AppState.swift:107-113`) and `SessionManager.applyRemoteApps` (`:528-538`). Every session re-sends `remoteAppsUpdate` and `gridLayoutUpdate` over the data channel, and the relay re-publishes `relay_remote_apps` and `relay_hello`.

On the phone the non-cached hello and remote-apps handlers clear `error` (`store.ts:444`, `:455`, `:471`), rewrite the relay cache to IndexedDB, and re-evaluate `isScreenStreamAvailable`, so any status message is wiped within 5 s and a stale Error status keeps calling `stopVideoPeer` until the Mac overwrites it (S4). It also makes "applyRemoteApps was called" useless as evidence.

### S8. The JPEG fallback capture runs for the whole share

`SessionManager.handleRelayScreenAction` (`:738-750`) starts `RelayScreenCapture` on every `start`, and nothing stops it while the WebRTC video is healthy; the phone ignores relay frames once video is ready. That is a second `SCStream` on the Mac, about 2 frames per second of up to roughly half a megabyte of base64 JSON per phone through the Worker, and a storage `setAlarm` write per frame in the Durable Object (`apps/cloudflare-signal/src/index.ts:2064`, `:2227`). The Mac log's two `SCStream` starts 284 ms apart at 12:37:47 are the WebRTC capture and this fallback.

After the Mac's relay client reconnects, `uses(relay:quality:)` (`RelayScreenCapture.swift:77-78`) compares the client by identity, so the running capture keeps publishing into the dead client until the phone sends another `start`. The fallback is therefore absent exactly when the network has just been bad.

### S9. Reconnects briefly mark screen sharing off

`store.ts:381` seeds `remoteApps` from `loadRelayCache`, which passes through `remoteAppsForCachedWorkspace` (`lib/remoteApps.ts:88`) and forces the screen app to `enabled:false`. Until the Worker replays the real list, the panel shows "Screen sharing off", calls `stopVideoPeer`, and then sends an extra `start` when the real list arrives.

### S10. Retry restarts the peer two or three times

`retryScreen` (`ScreenRemotePanel.tsx:401-411`) sends `start`, calls `startVideoPeer()`, then calls `onRetryConnection()`, which is `recoverConnection({ forceRestart: true })` and ends in `startPeer()`; that closes the peer just started and clears the stream, so the start effect starts again. `setScreenSharing(true)` on delivery failure (`:424`) and a failed quality change (`:449`) do the same. It recovers, but slowly and with three `start` actions per tap.

### S11. The Worker never detects a half-dead Mac socket

`RelayHub.alarm()` (`index.ts:2210-2214`) returns early whenever `hostSocket` is set, so `lastHostSeenAt` is never compared while a socket handle exists; there is no server-to-host ping and no auto-response. A Mac whose TCP path died without a FIN or RST stays "online" to every phone until the edge times out the connection or the Mac reconnects and replaces it. During that window `relay_command`s, including screen `start`, are forwarded into the dead socket and acknowledged to the phone. `SignalingHub.handleEnvelope` (`:1525-1549`) has the same shape: a `ping` envelope to a dead host socket is sent rather than queued. With the Mac's path churn above, this window is hit regularly.

### S12. Screen lifecycle logging is not persisted

Every screen lifecycle message is logged at `.info` (`SessionManager.swift:709`, `:719`; `RemoteAppController.swift:627`, `:818`, `:823`), which macOS keeps only in memory. Three days of unified log contain eight such lines. WebRTC and ICE state changes and capture state changes are not logged at all. Without `.notice`-level lifecycle events, neither this audit nor a future incident can reconstruct what happened on the Mac.

### S13. Same-profile duplicate tabs fight over one identity

The phone keypair lives in IndexedDB per browser profile. Both Durable Objects keep one socket per device id and close the previous one ("replaced by newer relay connection"), and the store reconnects with backoff, so two tabs (or a home-screen PWA and a browser tab on the same device) alternate every few seconds and each `ping` replaces the Mac's WebRTC session. No tab coordination exists.

### S14. Smaller defects

- `Session.sendAgentState` keeps the `SignalingClient` captured at session creation; after a Mac signaling reconnect its push `agentStateEvent` envelopes go to a dead socket silently.
- `videoTrackHint` exists in the protocol (proto, Swift, TypeScript) but is never sent; it is the natural carrier for "track paused/resumed" signals.
- `AutoLock`'s doc comment promises "video off" on lock; nothing gates capture on lock, and `autoLock.heartbeat()` runs before every lock check, so the lock gates never fire.
- Closing the Mac app's last window quits the app (`GlassTunnelApp.swift:60-62`), ending every share; phones correctly show "Mac offline".
- `VITE_GLASSTUNNEL_ENABLE_WEBRTC_FALLBACK` is unset in `deploy.yml`, so only the video flow pings the Mac. That is the right setting; keep it.

## Why a refresh fixes it

A refresh discards both panel copies, the stale stream, the stale `RTCPeerConnection`, and any pending timers; it opens one new signaling socket and sends one `ping`; the Mac replaces the session (`SessionManager.swift:1400-1406`), builds a new peer with a new `SCStream`, and sends a fresh offer. Every stale-state defect above is bypassed at once, which is why nothing short of a refresh reliably works today.

## Evidence from the Mac log (2026-09-03)

Collected with `/usr/bin/log show --last 3d --info --debug --predicate 'process == "GlassTunnel"'` (in this repo's shell `log` is a zsh builtin, so the absolute path is required).

- 12:37:47.285 and 12:37:47.569: two `SCStream` instances created and started 284 ms apart (WebRTC capture and JPEG fallback).
- 12:37:57.178 and 12:37:57.179: two `remote app action received remoteAppId=screen ... action=start`, both accepted. Matches S1.
- 12:37:57.387: the second stream stopped and a third started (fallback re-created); 12:39:39: the third stopped. The first stream is still running at the end of the log.
- Socket turnovers to the Worker at 05:51, 06:07 (five in 28 s), 06:13, 06:25, 06:26, 06:31, 06:49, 06:51, 07:15, 07:46 (two peer resets), 07:54, 08:15 (connection no longer viable), 10:11, 10:12, 10:33, 10:34, 11:55, all over `utun4`, each reconnecting after about a second. Kernel TCP faults reported large loss counts on the same path.
- Display attach at 10:37:57 and detach at 12:00:16; no display sleep or screen lock in the last two days.
- No crash, no ScreenCaptureKit error, no permission denial, no WebRTC lines (libwebrtc does not write to the unified log).
- Only eight `io.glasstunnel.host` lines exist in three days (S12), so `start`/`stop` history before 12:37 today is unavailable.

## Recommended fixes, in order

1. Mount one screen panel (S1). Choose the phone or desktop layout in JavaScript (a `matchMedia('(min-width: 768px)')` hook) and render `FocusedChat` in exactly one subtree, or lift the screen panel above both subtrees. Small change; removes the duplicate `start`, the second sink, and the hidden-copy restarts.
2. Add a frame-liveness watchdog (S2). While a stream is attached, poll `inbound-rtp` `framesDecoded` (fallback `framesReceived`) every second; with no progress for about 5 s, move the phase to `stalled`, disable control, and show the relay frame if it is fresh; after about 10 s stalled and while visible and online, send `start` and restart the video peer with backoff (10, 20, 40 s). Keep the evaluator a pure module so it is unit-testable. Depends on fix 3 for the strict thresholds; older hosts get a longer window keyed on `track.muted` and `requestVideoFrameCallback`.
3. Guarantee a minimum frame cadence on the Mac (S2, S4). In `DisplayCaptureBinding`, keep the last frame and re-emit it at 1 fps while ScreenCaptureKit is idle. Bump the protocol patch and advertise it in `hello` so the phone knows it may apply the strict watchdog. Also stops Chrome's mute toggling on static screens.
4. Never remove and re-add the track on a live peer (S3). Keep one sender per agent for the peer's lifetime: on stop, stop the `SCStream` but keep the sender and source; on restart, feed the same source again. If a track must be swapped, use `sender.track = newTrack` (no renegotiation). Send `videoTrackHint(active:)` over the data channel so the phone can show "Screen paused" instead of guessing.
5. Restart dead captures (S4). On `.error`, remove the binding and schedule a restart with backoff while the app stays desired; add `NSWorkspace` display and wake observers that restart the capture.
6. Keep the video peer across signaling drops and add a keepalive (S6). After `connected`, a signaling close should only clear `refs.signaling` and ignore late ICE send failures; send a `ping` control message every 20 s while the socket is open; recreate signaling lazily on the next restart.
7. Retry a failed flow and honour resume (S5). In the video-only `onClosed` and catch paths, schedule a retry with backoff while the screen is enabled, the host is online and the page is visible; on `visibilitychange` to visible, restart when the screen is enabled and there is no stream.
8. Stop republishing unchanged state (S7). `updateWindows` should publish only when the remote-app snapshot changed; the phone should not clear `error` on a byte-identical hello.
9. Pause the JPEG fallback while WebRTC video is healthy, and rebind it on relay reconnect (S8). The phone can report "receiving video" through `videoTrackHint`; the Mac pauses relay frames for that phone and resumes on the hint or on data-channel loss. Compare the capture's relay client by desire, not identity.
10. Detect a half-dead Mac socket in the Worker (S11). In `RelayHub.alarm()`, when `hostSocket` is set but `lastHostSeenAt` is older than about 60 s (the Mac pings every 20 s), close it and broadcast offline; queue signaling envelopes for a host that has not pinged recently.
11. Log screen, capture, and WebRTC lifecycle at `.notice` (S12), including ICE state transitions and capture start, stop, and error with the reason.
12. Clean up the retry paths (S10) and stop marking screen sharing off from the cached workspace when reconnecting to the same host (S9).
13. Optional: a single-tab guard with `navigator.locks` or `BroadcastChannel` (S13).

## Verification plan

- Unit (PWA, vitest in the node environment): pure liveness evaluator with fake stats and fake timers; layout-choice function; `startPeerFlow` keeps the peer on a signaling close after `connected`; store retry scheduling with `vi.advanceTimersByTime`.
- Unit (Mac, `swift test --package-path apps/host-macos`): capture restart after `.error` through a fake binding seam; one sender kept across stop and start; reconciler ordering.
- Unit (Worker, vitest): `alarm()` closes a stale host socket and broadcasts offline; `handleEnvelope` queues for a host that has not pinged.
- Lab: `pnpm lab:e2e:screen` and `:safari` must still pass (they cover the relay frame path only); add a step that closes the phone's signaling socket mid-share and asserts the view survives.
- Live, on the signed app with a phone: run `/usr/bin/log stream --info --predicate 'process == "GlassTunnel"'` while toggling Wi-Fi and the VPN on the Mac, backgrounding the PWA for 1 s, 5 s and 60 s, attaching and detaching a display, and toggling sharing from the Mac window. Each case should end with a rendering picture without a refresh.

## Not covered

- The failure was not reproduced live: reproducing it needs the user's phone and Mac, and the lab host produces relay frames only.
- Chrome and Safari behaviour was verified from their sources for the mute and paint paths; exact iOS background timings and Safari's `framesReceived` support were not verified.
