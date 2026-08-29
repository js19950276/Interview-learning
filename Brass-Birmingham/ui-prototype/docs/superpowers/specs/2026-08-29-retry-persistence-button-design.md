# Retry Persistence Button Design

## Goal

Provide a real, user-triggered save retry when the local session snapshot cannot be persisted. The retry must work for both the authoritative host and a guest's private projection without replaying the original gameplay action.

## User Experience

- Keep the existing full-match interaction blocker while persistence is unsafe.
- Replace the persistence-failure text-only banner with a compact recovery panel containing the error message and a `重试保存` button.
- Show the button only when the current failure is specifically a local persistence failure. Connection loss, invalid recovery material, rule rejection, and other failed states must not expose it.
- Give the button the accessibility identifier `real.persistence.retry` and a minimum 44-point hit target.
- After the user taps it, change the label to `正在保存…`, expose `real.persistence.retrying`, and disable the control until the attempt completes.
- On success, remove the persistence error and button. Let the authoritative session state decide whether the UI becomes `synchronized` or remains `recovering`; gameplay is enabled only when it is synchronized.
- On another failure, keep the session safely paused and make `重试保存` available again.

## Architecture

### SessionCoordinator

Generalize the existing `retryPersistence()` operation so it is role-aware while retaining the existing resolve gate:

- Host: persist the current committed authoritative state with `persistCommittedState()`.
- Guest: persist the current private snapshot with `persistGuestState(newEvent: nil)`.

The retry persists the current in-memory state only. It never resubmits or replays the action that preceded the failure, preventing duplicate builds, payments, discards, or version increments.

### SessionViewStore

Add observable persistence recovery state:

- `hasPersistenceFailure` records the precise failure reason received from `SessionCoordinator.State`.
- `isRetryingPersistence` prevents duplicate retry tasks and drives progress presentation.
- `canRetryPersistence` is true only while a persistence failure exists and no retry is running.
- `retryPersistence()` invokes the coordinator operation, preserves the fail-closed interaction state during the attempt, and leaves failures retryable.

The coordinator's published state remains the source of truth for clearing the error and choosing `synchronized` versus `recovering` after success.

### AuthoritativeMatchBoardView

Extract the existing error banner into a small recovery panel. It retains `real.recovery` on the container and conditionally adds the retry button. The existing `submission.blocker` stays beneath the recovery panel so map and action controls remain blocked while the retry button stays tappable.

## Error Handling

- A retry failure must not clear `persistenceError`, `errorMessage`, or the submission blocker.
- A retry success must not force `synchronized`; pending peer recovery or delivery state may legitimately require `recovering`.
- Repeated taps during an active retry are ignored.
- Guest retries never attempt host-only authority work; they only save the guest's private projection.
- Existing background persistence remains available but is not used as the button implementation.

## Verification

- Coordinator test: a guest persistence failure can be retried through the role-aware retry API.
- View-store test: reproduce a progress-checkpoint failure after an accepted action, retry it, and verify the authority version does not advance again, the persistence error clears, and synchronized interaction returns.
- View-store test: a failed retry remains failed and becomes retryable again.
- View-store test: concurrent retry taps result in only one persistence attempt.
- UI test: the persistence recovery panel exposes a visible, hittable 44-point `重试保存` control with the documented accessibility identifiers.
- Regression verification: focused persistence tests, the broader unit suite, a Debug build, and real iPhone/iPad simulator flow.

## Non-Goals

- Automatically replaying the failed gameplay action.
- Removing the fail-closed persistence safety mechanism.
- Adding retry controls for connectivity, rule validation, or corrupt recovery-material failures.
- Redesigning the surrounding match chrome.
