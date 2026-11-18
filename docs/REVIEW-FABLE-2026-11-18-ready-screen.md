# Review: ready screen = the recording screen; paywall waits for a reinstall's plan

Reviewer: Claude Fable 5.1, 2026-11-18. Read-only review of commit c9013de on
v1-build. Read: the full new lib/features/recording/recording_screen.dart against
`c9013de^` (semantics, not formatting), lib/features/paywall/paywall_screen.dart,
lib/features/onboarding/onboarding_screen.dart, and for context lib/app/router.dart
(paywall route, onDone), lib/features/notes/notes_screen.dart (_onRecord),
lib/app/nav.dart (NavGuard), lib/app_services.dart (startRecording,
canStartRecording), lib/core/billing/storekit_billing_service.dart (refresh,
purchase, restore, _apply), lib/core/billing/billing_service.dart (fake),
lib/core/recording/recording_controller.dart (start, isActive),
lib/features/common/external.dart (showNote = snackbar, not a route),
lib/ui/widgets/sheet.dart (showLnSheet: root navigator, barrier), the changed
tests. `flutter analyze`: no issues. `flutter test`: 238 passed.

## Verdict: CHANGES NEEDED

One major: the 15 s "stuck" timer does not do what its toast says. It clears the
screen's own `_starting` flag, but the Close button and Start are disabled from a
value that also reads the controller's state, which stays `starting` for exactly
the case the timer exists for. The user is told "Close and try again" and cannot.
Pre-existing from the previous commit, but this commit rewrites those lines, the
owner lists the stuck timer among the guards that must hold, and the fix is one
token. Everything else is minor.

The specific questions asked:

- Language sheet vs Start: Start is not reachable under the sheet (modal barrier
  on the root navigator). The only gap is the `await settings.audioLanguage()`
  before the sheet opens (minor 2 below).
- `_pendingLanguage` when `startRecording` throws but capture is live: not
  applied, silently dropped (minor 3).
- Paywall listener vs Restore: `_apply` inside `restore()` fires the listener
  synchronously, which pops with `true`; `_restore` then resumes, finds the widget
  still mounted (exit animation running) and calls `_close(true)` again, which
  `_closed` turns into a no-op. One pop, right value. Same for first_run `onDone`.
- Wrong route popped: `Navigator.of(context).pop(true)` pops the top of the root
  navigator. The only Flutter route this screen ever puts on top of itself is
  TrialStarted, and `_buying` is true for good by then. Restore's Apple sheet and
  Terms/Privacy are native, `showNote` is a snackbar. No path pops the wrong route.
- `second_recording`: the pop with `true` makes Notes `_onRecord` push the ready
  recording screen. Correct and the same as Restore. (Side effect, not a bug: a
  plan arriving minutes later, e.g. Ask to Buy approved, opens the ready screen on
  its own; nothing records.)
- Listener during build: every `_set` is reached from a method-channel callback,
  a purchase/restore future or `refresh()`; none runs inside a build. `_close` is
  never called synchronously from a frame.
- Onboarding refresh: `refresh()` catches everything and is capped at
  `statusTimeout` (5 s). The normal read is a local `currentEntitlements` call and
  returns fast; 5 s is the hang case only. Acceptable; a busy state on the button
  is the missing piece (minor 4), not a shorter timeout.
- Guards: 400 ms open guard, 600 ms Pause guard, failed start stays on ready with
  the right toast (`_ready = !live`), no `_Ended` card and no blank `_leaving`
  scaffold in ready mode (both branches are gated on `!ready`). All hold.
- Ready layout: Discard, Stop & save, Mark moment, Rename all inert (`onTap: null`,
  so `LnPressable` reports them disabled to VoiceOver); timer 00:00:00; waveform
  empty (`current` is null); chip shows `_pendingLanguage`.

## Findings

### 1. major: after the 15 s stuck timer, Close and Start stay disabled
`lib/features/recording/recording_screen.dart:124-128` (timer sets `_starting = false`
and toasts "Close and try again"), `:256` (`starting = ready && (_starting ||
c.state == CaptureState.starting)`), `:352` (`onPressed: starting ? null : _minimise`),
`:498` (`onTap: starting ? null : _start`).
Scenario: tap Start; iOS never answers the mic/audio-session call, so the controller
sits in `CaptureState.starting` (it set that state and notified before the await at
recording_controller.dart:100-107). At 15 s the timer clears `_starting` and shows
the toast. But `starting` in build is still true through `c.state`, so Close keeps
`onPressed: null`, Start keeps its spinner, the chevron is greyed. The user has been
told to Close and cannot; the only exit is killing the app. This is the exact case
the timer was added for (previous review, finding 1), and no test covers it (nothing
in test/ or integration_test/ references the toast).
Fix: disable Close on the screen's own flag only: `onPressed: _starting ? null :
_minimise`. Leave Start on `starting` (a second Start while the controller is still
`starting` would only get `StateError('already recording')` and a wrong toast), or
better, also key Start on `_starting` and let `_start` show "Still starting, please
wait" when `c.state == CaptureState.starting`. Add a widget test with a source whose
`start()` never completes: pump 15 s, expect Close enabled.

### 2. minor: Start tapped during the language chip's settings read loses the pick
`lib/features/recording/recording_screen.dart:227-233`.
Scenario: on the ready screen, tap the language chip, then Start within the few
milliseconds of `await _s.settings.audioLanguage()` (a kv read). `_start` runs,
then the sheet opens on top of "Starting…"; the recording goes live underneath and
`_ready` becomes false. The user picks Bengali; `_chooseLanguage` hits `!_ready`
and returns, the pick is dropped without a word, the chip shows the Settings
default. Narrow window, but a tap on the chip followed by Start is a natural
gesture.
Fix: when the sheet returns and `_ready` is false, apply the pick to the live note
(`c.current?.id` -> `setNoteOptions`) instead of returning. Or read the setting
before showing the chip (cache it in `initState`) so there is no await before the
sheet.

### 3. minor: `_pendingLanguage` is not applied when capture started but `startRecording` threw
`lib/features/recording/recording_screen.dart:131-149`, `lib/app_services.dart:448-465`.
Scenario: pick Hindi on the ready screen, tap Start. `recorder.start()` succeeds,
then `settings.defaultStyle()` or the first `setNoteOptions` throws. The catch sees
`live == true`, flips to the live screen and returns without a toast (correct), but
the pending Hindi is never written: the note keeps the language the failed
`setNoteOptions` left (null -> "Auto-detect"). The user chose a language and the
transcript runs in auto-detect with no sign anything was skipped.
Fix: move the `_pendingLanguage` write into a block that runs on both exits when
`_s.recorder.current != null` (e.g. a `finally` that checks `isActive`), still in a
try/catch of its own.

### 4. minor: onboarding's last button has no busy state while StoreKit is asked
`lib/features/onboarding/onboarding_screen.dart:33`, `:129-136` (FilledButton,
`onPressed` never null).
Scenario: a user taps "Allow microphone" / "Continue" on a phone where the StoreKit
status call is slow. Nothing changes on screen for up to 5 s; the button still
accepts taps, each tap runs `_finish` again (another kv write and another refresh;
all end in the same `goNamed`, so no wrong screen, just wasted calls and a dead-
looking button). Before this commit the transition was immediate.
Fix: a `_busy` flag set in `_finish`, `onPressed: _busy ? null : ...`, and the
button's label or a small indicator while busy. The 5 s cap itself is fine: the
normal path returns in well under a second.

### 5. minor: 'pending' purchase that is approved before `purchase()` returns leaves the paywall open
`lib/features/paywall/paywall_screen.dart:103-109`.
Scenario (Ask to Buy): `_buying = true`; while the purchase call is in flight the
native 'changed' fires and `refresh()` sets an active entitlement; the listener sees
`_buying` and ignores it. `purchase()` then returns `pending` (StoreKit reported
pending before the approval landed), `_buying = false`, "Waiting for approval" is
shown, and the paywall stays open although the user is entitled. Nothing re-fires
unless the renewal fetch changes the entitlement value. Very narrow in practice
(an approval inside the call window usually returns success), and X or Restore
recover.
Fix: after `if (!res.success) _buying = false;` add
`if (_billing.entitlement.value.isActive) { _close(true); return; }`.

### 6. minor (cosmetic): the live chip flashes the default language before the pick lands
`lib/features/recording/recording_screen.dart:151-166`, `:278`.
Scenario: pick Bengali on the ready screen, Start. `startRecording` writes the
Settings default, the repo notifies, `_loadNote` sets `_language = 'auto'`; the
controller is already `recording`, so `ready` is false and the chip reads
`_language` ("Auto-detect") until the second `setNoteOptions` with the pick
notifies. One DB write long. Fix if wanted: `language = (_ready ? _pendingLanguage
: null) ?? _pendingLanguage ?? _language` while `_starting`, or pass the pick into
`startRecording` so there is one write.

## Not findings (checked and fine)

- `_closed` prevents every double close: listener + `_restore`, listener + `_buy`,
  listener + X.
- `late final _billing = _s.billing` resolved in `initState` via `context.read`:
  allowed (no `watch`).
- `_buying` is reset on `!res.success` before the `mounted` check, so an unmounted
  paywall does not keep a stale flag; the listener is removed in `dispose` anyway.
- `_leaving` is only set from `_stop`/`_discard`, both `onTap: null` in ready.
- `late bool _ready = widget.ready && !_s.recorder.isActive` still gives the live
  view for a stale `/record?ready=1` while recording.
- `shortDate(clock.now())` on the ready screen uses the clock package (golden
  tests pin it); `c0_ready.png` regenerated.
- Hit geometry: Start is 84 wide at the centre; Discard/Stop centres are at
  +-128, each 84 wide, so a second tap inside Start cannot reach them. The 600 ms
  Pause guard covers the double tap on Start.
- Test harness `clock: clock` for `TrialReminderService`: a straight wiring fix;
  the 'Wed, Nov 18 · 8:24 AM' assertions depend on it.
- New paywall test ('a plan that arrives while the paywall is open closes it')
  exercises the first_run `onDone` path; the Navigator-pop path is the same `_close`.

---

# Re-review: commit 2ab3f68 (fixes for findings 1-6)

Reviewer: Claude Fable 5.1, 2026-11-18. Diff-only (`git show 2ab3f68`), plus
recording_repository.dart:150-153 and :79-83 for the ordering note below.
Coordinator reports `flutter test`: 239 pass.

## Verdict: APPROVED

| # | Fix | Status |
|---|-----|--------|
| 1 | `closeLocked = ready && _starting`; Close keyed on the screen flag only, Start still on `starting` (so a second Start while the controller is stuck gets nothing, not `StateError`). Test 'a start that hangs unlocks Close after 15 s' uses `FakePcm.startGate`, asserts Close disabled at 0 s, enabled plus toast at 16 s, screen gone after Close, then releases the gate and drains. | Fixed, covered |
| 2 | Sheet returns with `_ready` false: pick applied to `recorder.current` and shown at once; `_ready` true: stored as pending. If the start failed meanwhile `_ready` is true again (`_ready = !live`), so the pending branch is the right one. | Fixed |
| 3 | `_applyPendingLanguage()` on both exits: success path, and the catch path when `live`. `_starting` stays true during the await, so Pause remains blocked; `mounted` re-checked before the following `setState`. | Fixed |
| 4 | `_finishing` set before the kv write, cleared after the refresh when mounted; button `onPressed: null` with a 20 px spinner. Re-entry guard at the top of `_finish`. | Fixed |
| 5 | After `_busy` is cleared: `!res.success && isActive` -> `_close(true)`; `_closed` still guards a race with the listener. | Fixed |
| 6 | `_language = pick` set synchronously in `_applyPendingLanguage`. | Fixed, with a residual (below) |

## Residual (minor, cosmetic, not blocking)

`recording_screen.dart:165-175` (`_applyPendingLanguage`), `:102-114` (`_loadNote`),
`recording_repository.dart:151-152`.
`startRecording`'s own `setNoteOptions(language: <Settings default>)` notifies the
repo after its write; `_loadNote` issues `repo.get(id)` (an async DB read) at that
moment. `_start` then resumes, `_applyPendingLanguage` sets `_language = pick`
synchronously and starts the pick's write. The earlier `get` can resolve in between
with the default and `_loadNote` writes it back into `_language` until the pick's
write notifies and a fresh `get` reads the pick. So the one-write flash from
finding 6 is shortened, not removed, depending on how the two DB round-trips
interleave. Fix if wanted: have `_loadNote` leave `_language` alone while
`_pendingLanguage != null`, and clear `_pendingLanguage` after the pick's write
succeeds (or pass the pick into `startRecording` so there is a single write).

## Checked and fine

- Closing the ready screen while the controller is still `starting`: if the start
  later lands, recording runs with the Notes pill showing it (the behaviour the
  previous review accepted); if it fails, the controller returns to idle with
  nothing kept. The new test exercises the first half (gate released after Close).
- `_applyPendingLanguage` is a no-op when `current` is null, so a failed start
  with a pending pick keeps the pick for the next Start.
- Onboarding `_askMic` -> `_finish`: `_askMic` itself has no guard, but the button
  is disabled while `_finishing`, and `_finish` returns early on re-entry.
