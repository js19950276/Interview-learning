# Task 14 visual and accessibility review

Date: 2026-08-11

## Review captures

These are review-only captures, not Task 15 snapshot baselines or tooling.

- `/tmp/industrial-city-task14-review/iphone-match-normal.png`
- `/tmp/industrial-city-task14-review/iphone-match-reduced-color-assist.png`
- `/tmp/industrial-city-task14-review/iphone-rejected-action.png`
- `/tmp/industrial-city-task14-review/ipad-match-normal.png`
- `/tmp/industrial-city-task14-review/ipad-match-reduced-color-assist.png`
- `/tmp/industrial-city-task14-review/iphone-release-players2.png`

The iPhone capture is stored with the simulator framebuffer's portrait pixel orientation while the app content is landscape. The iPad simulator was in its existing Stage Manager window state; the app viewport itself remained landscape and was not resized for this review.

The final capture installs the Release simulator build and launches it with the explicit `-fixture players2` arguments. It displays the two-player match directly, confirming fixture routing remains compiled into Release while still requiring the explicit fixture flag.

## Five-point visual check

1. **Cold fog industrial map — pass.** The desaturated aerial map, smoke layers, dark coal panels, and cool iron/fog surfaces establish the industrial atmosphere on both device classes.
2. **Restrained warm brass focus — pass.** Brass is reserved for the current player, header metrics, actionable controls, selected targets, and panel edges; it does not replace the neutral map palette.
3. **Modern panel hierarchy — pass.** Header, rails, market, hand, confirmation, and rejection feedback use consistent shape, spacing, translucent material, and type hierarchy.
4. **Map remains the first visual subject — pass.** The map occupies the dominant central area on phone and iPad. Even the deterministic rejection state leaves map context visible around the confirmation and recovery panels.
5. **Decoration never obscures game information — pass for reviewed fixtures.** Fog and texture remain behind routes and locations. Panel borders and symbols do not overlap labels, prices, player status, confirmation deltas, or recovery text.

## Accessibility hierarchy and executable checks

Source-level inspection records these named focus groups and labels:

1. `match.header` — era, round, action, deck, money, income, and victory-point summary.
2. `match.playerRail` — player order, name, color name, color-assist shape, spend, readiness, connection, current-player, and host state.
3. `match.map` plus `map.target.*` / `flow.target.*` — map summary followed by named map targets when a flow requests them.
4. `match.industryRail` and `industry.select.*` — industry information and selectable industries.
5. `market.coal`, `market.iron`, and `market.expand` — resource counts, prices, and expansion control.
6. `match.hand` and `hand.card.*` — eight named cards and selection state.
7. `match.actionButton`, `action.*`, `action.confirmation`, `action.cancel`, and `action.confirm` — action entry, choices, draft details, and completion controls.
8. `event.rejected` / `event.technicalFailure` — recovery feedback requests accessibility focus while preserving the editable draft.

Executable UI checks cover normal, reduced-motion, and color-assist launches. Fixture assertions inspect the real player rail, rejection feedback, disconnected status, nearby preflight panel, and online state panel; the error fixtures also use the real selectors to recover and prove the blocked controls become enabled. Critical controls have non-empty accessibility labels and frames of at least 44 × 44 points. The Gallery renders a real 4 × 8 component matrix—Button, BrassPanel, player item, and resource chip across normal, pressed, disabled, selected, illegal, waiting, disconnected, and reduced-motion states—with stable `gallery.<component>.<state>` identifiers. All eight Gallery button variants additionally prove a non-empty label and a minimum 44 × 44 point hit area. The checks also exercise selected and mutually exclusive overlays, map targets, disabled and enabled confirmation states, accepted/rejected feedback, disconnected players, long bilingual names, and all four color-assist symbols. A separate launch verifies that disabling color assist removes shape symbols and shape names from the real player rail and phone player drawer.

The `rejectedAction`, `disconnected`, `wirelessOff`, and `versionMismatch` fixtures are parsed into immutable launch configuration before `RootView` is constructed. `MatchView`, `NearbyRoomView`, and `OnlineRoomView` initialize their real feature state directly; `MatchView.onAppear` only requests accessibility focus. This removes post-first-frame fixture mutation and avoids test-only overlay markers.

Final executable evidence: 100 unit tests passed; all 22 UI test methods passed on the dedicated iPhone simulator with 0 failures and 0 skips; the same 22 methods passed on the dedicated iPad simulator with 0 failures and 0 skips. Release build and static analysis also succeeded.

XCUITest validates the accessibility hierarchy that VoiceOver consumes, but the simulator command-line tools do not provide a reliable way to issue real VoiceOver next/previous swipe gestures. A physical-device VoiceOver swipe-through remains the final assistive-technology check.
