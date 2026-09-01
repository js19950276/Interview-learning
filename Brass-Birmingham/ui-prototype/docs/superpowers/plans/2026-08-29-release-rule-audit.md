# Brass Birmingham Release Rule Audit Plan

> Audit baseline: `codex/retry-persistence-button` at `77938809c08f048562834f125c70df88d3bb64fc`. The final evidence below was collected from the intentionally modified, uncommitted worktree after all audit fixes; it must not be described as evidence for the baseline commit alone.

## Goal

Build a traceable release-readiness audit in which every rule family is reviewed by an independent subagent assignment, every suspected defect receives an executable reproduction, and every confirmed defect is fixed test-first before the complete regression and two-device acceptance runs.

This audit cannot honestly promise that no undiscovered defect exists. Release readiness means that every item below has explicit `PASS`, `BUG FIXED`, or `BLOCKED` evidence and that no unresolved P0/P1 software defect remains. The 243 production data rows require a second human verification against a legal physical or authorized reference; tests that reread the same JSON do not count as independent verification.

## Evidence hierarchy

1. Current official Roxley rulebook and published errata/FAQ, with exact page or section.
2. Repository rule contract in `RULES.md`.
3. Production implementation under `IndustrialCityBirmingham/GameCore` and session/UI code.
4. Focused executable tests that fail when the rule is violated.
5. Full regression, Release build, device UI checks, and paired-device gameplay evidence.

When these disagree, the official rulebook is authoritative. A repository test that merely preserves conflicting behavior is evidence of a defect, not evidence that the behavior is correct.

## Subagent protocol

The runtime permits three child-agent identities concurrently. To preserve the user's requirement, each matrix row is dispatched as a separate subagent task/turn; identities are reused only after the preceding rule has completed. Each audit task must:

1. State the rule in one falsifiable sentence and cite its official source.
2. Trace every production path that enforces or projects it.
3. Identify existing tests and whether they exercise the production path.
4. Run the narrowest relevant test command and record the executed test count.
5. Construct an adversarial boundary example and determine whether it is covered.
6. Return exactly one result: `PASS`, `BUG`, or `BLOCKED`, with file/symbol/test evidence.
7. Make no source edits during the audit assignment.

For each `BUG`, use the systematic-debugging workflow to establish root cause, add a failing regression test, implement the smallest correction, rerun the focused suite, request review, and then rerun the complete gates.

## Rule matrix

| ID | Independently audited rule family | Initial state |
|---|---|---|
| R01 | Official source, version, errata, and production ruleset gate | BUG FIXED; R34 tracks unsupported variant handling |
| R02 | Player count, objective, game length, and end condition | BUG FIXED |
| R03 | Public supply and coal/iron markets during setup | BUG FIXED |
| R04 | Card catalog, deck construction, wild cards, dealing, and first order | BUG FIXED |
| R05 | Merchant placement, player-count masks, beer, and rewards during setup | BUG FIXED |
| R06 | Player network versus general connectivity | PASS |
| R07 | Per-turn action count, first round, card consumption, refill, and pass | BUG FIXED |
| R08 | Spending order, turn order, income, and cash floor | BUG FIXED |
| R09 | Forced sale, liquidation order, insufficient assets, and VP floor | BUG FIXED |
| R10 | Build card targeting, legal location/slot, and slot priority | PASS |
| R11 | Build cost, coal/iron requirements, production, and immediate delivery | PASS |
| R12 | Own-industry overbuild | PASS |
| R13 | Opponent coal/iron overbuild and exhaustion prerequisites | PASS |
| R14 | Rural brewery construction and connectivity | PASS |
| R15 | Canal network construction | PASS |
| R16 | Single-rail construction, coal, and total affordability | PASS |
| R17 | Double-rail construction, route order, coal, beer, and total affordability | BUG FIXED |
| R18 | Develop count, lowest tiles, iron, and undevelopable pottery | PASS |
| R19 | Sell eligibility, connectivity, accepted goods, and ordered multi-sell | BUG FIXED |
| R20 | Sell beer ownership, connectivity, and selected-merchant restriction | BUG FIXED |
| R21 | Merchant reward timing and reward type | BUG FIXED |
| R22 | Loan income-track movement, cash, and lower bound | BUG FIXED |
| R23 | Scout card eligibility, exact discard, wild pools, and secrecy | PASS |
| R24 | Coal source priority, distance tiers, market, and unlimited supply | BUG FIXED |
| R25 | Iron source priority, market, and unlimited supply | PASS |
| R26 | Beer source rules outside and during Sell/Network | PASS |
| R27 | Canal-era industry and route restrictions | BUG FIXED |
| R28 | Rail-era industry and route restrictions | PASS |
| R29 | Era-end trigger and last-turn sequencing | BUG FIXED |
| R30 | Link scoring, including merchant connection icons | BUG FIXED |
| R31 | Industry scoring | BUG FIXED |
| R32 | Canal-to-rail cleanup, cards, order, and merchant refill | BUG FIXED |
| R33 | Final winner and all tie-breakers | PASS |
| R34 | Short-game variant support or explicit unsupported-state handling | BUG FIXED |
| R35 | Legal-action enumeration matches authoritative validation | BUG FIXED |
| R36 | Host authority, atomicity, versions, events, replay, and rejection | PASS |
| R37 | Snapshot privacy and hidden-information projection | BUG FIXED |
| R38 | Session identity, reconnect tokens, ordering, replay defense, and roles | BUG FIXED |
| R39 | Disconnect, catch-up, recovery, and host-loss behavior | BUG FIXED |
| R40 | Persistence precommit, retry-save, crash recovery, and no action replay | BUG FIXED |
| R41 | Nearby discovery/transport, permissions, framing, timeout, and LAN security | BUG FIXED |
| R42 | iPhone/iPad layout, map pan/pinch/taps, active-turn indication, and accessibility | BUG FIXED |
| R43 | Independent verification of all 243 production data rows | BLOCKED: second human evidence required |
| R44 | Bundled asset allowlist, provenance, and release packaging | BUG FIXED; asset-license record remains a release review item |

## Confirmed release gates to run

Run from `Brass-Birmingham/ui-prototype` unless noted otherwise.

1. `bash scripts/verify_game_data.sh`
2. Focused test commands produced by every rule assignment.
3. Complete serial unit suite with an explicit result bundle and test-count check.
4. Release build for the generic iOS Simulator destination.
5. iPhone UI suite covering map gestures, rails, action flow, retry-save, and active turn.
6. iPad UI suite covering permanent rails, map interaction, action flow, and retry-save.
7. `scripts/run_two_simulator_room_test.sh` for create, discover, join, ready, start, action, reconnect, catch-up, and persistence failure/retry.
8. Real-device two-player local-network matrix before distribution: permission prompt, same Wi-Fi, proxy/VPN on and off, host background/foreground, guest disconnect/reconnect, host termination, and crash/relaunch persistence.

## Known hypotheses requiring executable confirmation

- Build may incorrectly consume the industry's Sell beer requirement as a construction cost.
- Rail validation may check only the base fee and commit a negative cash balance after market-coal payment.
- Forced sale may be legal in authority but impossible to complete through the legal-query UI when all assets still do not cover the shortage.
- Link scoring may omit connection icons at merchant locations.
- Negative income may be carried as permanent final VP debt instead of immediately reducing existing VP to a floor of zero.
- Several legal-query prefixes may expose choices that cannot reach any complete legal action.
- The release data gate is intentionally blocked while the manifest remains `draft`.
- The closed bundled-resource allowlist currently rejects the original `MatchChrome` asset catalog.

## Running evidence ledger

| Rule | Result | Executable evidence |
|---|---|---|
| R01 | BUG FIXED | Ruleset/catalog split: 30 SessionCoordinator cases; board player-count masks: 29 data/topology cases |
| R02 | BUG FIXED | End condition, final standings, tie groups, projection and persistent result UI: 55 cases |
| R03 | BUG FIXED | Official iron price ladder and resource setup: 43 cases |
| R04 | BUG FIXED | Card-zone types, exact opening deal/order, bottom cards and wild pools: 63 cases |
| R05 | BUG FIXED | Blank-merchant accessibility wording plus map regression: 40 cases |
| R06 | PASS | Independent connectivity/network audit: 23 exact cases |
| R07 | BUG FIXED | Per-seat remaining-card recovery invariant: 26 TurnScoring cases |
| R08 | BUG FIXED | Authoritative spending order projection and reachable forced-sale phase: included in 48 combined TurnScoring/Projection cases |
| R09 | BUG FIXED | Valued forced-sale projection accepted by protocol-v2 validation: included in the same 48-case bundle |
| R10 | PASS | Independent Build targeting/slot-priority audit: 7 exact cases; stale initial-shape fixture repaired and its exact case rerun 1/1 |
| R11 | PASS | Independent Build cost/resource/production audit: 17 production-path cases plus 2/2 direct total-prefunding and immediate-delivery coverage cases |
| R12 | PASS | Independent own-industry overbuild audit: 4 exact cases |
| R13 | PASS | Independent opponent coal/iron overbuild audit: 4 exact resource-exhaustion boundary cases |
| R14 | PASS | Independent rural-brewery audit; stale fixture repaired, plus 1/1 south-farm Wild Industry/network/query coverage case |
| R15 | PASS | Independent canal-network audit: 7 exact cases |
| R16 | PASS | Independent single-rail audit: 8/8 exact cases after repairing two stale active-hand fixtures |
| R18 | PASS | Independent Develop/iron/query/replay audit: 6/6 after repairing the stale pre-official-iron-price fixture |
| R19 | BUG FIXED | Red 33-selection multi-sell boundary; green 2/2 long-sell and malformed-request cases with the 16 KB guard preserved |
| R20 | BUG FIXED | Red source labels/map targets/action prompt; green 6 tests including four parameterized target-parser cases |
| R21 | BUG FIXED | Red merchant-reward effect ordering; green official reward-before-flip/base-income event order |
| R17 | BUG FIXED | Red second-rail topology regression; green sequential link-then-coal resolution plus 12/12 combined rail/coal/query/replay cases |
| R22 | BUG FIXED | Red overflow/query/display regressions; green 5/5 including stable rejection, displayed-income confirmation, authoritative UI projection, official three-level movement and £-10 floor |
| R23 | PASS | Independent Scout settlement/replay/wild-return/privacy/query/UI audit: 9/9 exact cases |
| R24 | BUG FIXED | Red whole-link nearest-tier and double-rail apply-order regressions; green 2/2 new cases and 12/12 combined rail/coal/query/replay cases |
| R25 | PASS | Independent iron-source/market/delivery/query/replay audit: 16/16 exact cases |
| R26 | PASS | Independent Build/Sell/Network beer-source audit: 18/18 exact authority/query/replay/projection/UI cases |
| R27 | BUG FIXED | Red era-invalid placement, duplicate own canal-city placement, and industry-rail availability regressions; green 3/3 focused and 15/15 combined authority/query/replay/persistence/map/UI cases |
| R28 | PASS | Independent rail-era authority/build/network/query/replay/UI audit: 17/17 exact serial cases on an isolated iPad simulator; rail-only/canal-only routes and Pottery L1 were also checked adversarially against the shared era predicate and catalog data |
| R29 | BUG FIXED | Independent audit found early card exhaustion could strand a later round; red authority/host reproduction accepted the illegal state and mutation, then exact remaining-card/action-slot validation plus repaired official-progress fixtures passed the complete 29-test/36-case TurnScoring suite |
| R30 | BUG FIXED | Independent audit found external-market link icons were counted per merchant tile; red 2/2 showed Gloucester scoring 4 instead of 2 and empty 2-player Warrington scoring 0 instead of 2, then fixed-location scoring passed 3/3 focused and the complete 29-test/36-case TurnScoring suite |
| R31 | BUG FIXED | Independent industry-scoring audit found complete authority accepted a physical tile whose color owner and declared `ownerID` disagreed, allowing points to be awarded to the wrong player. The red authority regression failed before the fix; authority now binds every stacked/placed physical tile to its canonical owner/color identity, the focused regression is green, and the complete serial unit run passed 544/544 (`/tmp/IndustrialCity-all-unit-r31-r32-green-20260829.xcresult`). |
| R32 | BUG FIXED | Independent canal-to-rail audit found complete authority accepted a tampered rail opening hand distribution (`7/8 + deck 25` instead of `8/8 + deck 24`). The red authority regression failed before the fix; authority now derives the exact legal hand/deck distribution from era, round, seat, action progress and Scout deltas, the focused regression is green, and the complete serial unit run passed 544/544 (`/tmp/IndustrialCity-all-unit-r31-r32-green-20260829.xcresult`). |
| R33 | PASS | Independent final-winner audit traced final scoring, ended-state validation, replay, projection, persistence and UI; 13 concrete cases passed, including the adversarial tie order `[[0,3],[2],[1]]` and immediate negative-income VP loss without double deduction |
| R34 | BUG FIXED | Unsupported variants now fail closed across authoritative state, snapshot, session envelope, archive and launch arguments; `.standard` is explicit and the app presents an unsupported-variant stop screen. Focused and compatibility regressions pass (`/tmp/IndustrialCity-r34-green-20260829.xcresult`, `/tmp/IndustrialCity-r34-regressions-green-20260829.xcresult`). |
| R35 | BUG FIXED | Independent legal-enumeration/settlement audit ran 18/18 concrete cases and found a recovery-boundary hole: an untouched rail opening could be restored with a nonblank merchant beer missing even though normal transition logic refills it. The red regression proved authority accepted the mutation; authority now requires every nonblank merchant to be full only at the exact unstarted rail boundary while preserving legal later consumption, and both focused cases pass (`/tmp/IndustrialCity-r35-green-20260829.xcresult`). |
| R36 | PASS | Independent host-authority audit traced identity, version/action-number monotonicity, candidate-state replay, precommit persistence, fanout, catch-up and ended-state behavior. Fifteen selectors / 18 concrete adversarial cases passed serially, including persistence failure with zero broadcast, concurrent submission serialization, forged host events, gaps, rollback and full 2/3/4-player replay (`/tmp/IndustrialCity-r36-final.lP8plE/R36-verify.xcresult`). |
| R37 | BUG FIXED | A nondebtor could receive another player's forced-sale private projection. The recipient filter now keeps it private to the debtor; red/green evidence is `/tmp/IndustrialCity-r37-red-20260829.xcresult` and `/tmp/IndustrialCity-r37-green-20260829.xcresult`. |
| R38 | BUG FIXED | The host could assign an unknown new seat after the game started. Post-start unknown players are rejected while the same seat and token may reconnect; red/green evidence is `/tmp/IndustrialCity-r38-red-20260829.xcresult` and `/tmp/IndustrialCity-r38-green2-20260829.xcresult`. |
| R39 | BUG FIXED | Active-guest loss did not pause every online seat, inactive-guest recovery could block the active host, and the view model hardcoded connectivity. Host-authored presence/pause/resume now drives all clients; four focused regressions pass (`/tmp/IndustrialCity-r39-green2-20260829.xcresult`). |
| R40 | BUG FIXED | A failed first precommit discarded the resolved v1 candidate, so retry saved old v0. The coordinator now retains one immutable pending precommit and only consumes it after saving and publishing once. The exact red/green case and 11-case persistence/R39 regression pass (`/tmp/IndustrialCity-r40-red-isolated.gxcSoH/R40-RED-clean.xcresult`, `/tmp/IndustrialCity-r40-green.167XYL/R40-GREEN-regressions.xcresult`). |
| R41 | BUG FIXED | Real-device nearby TCP could wait forever, admitted unlimited unauthenticated sockets, allowed proxies, and exposed a stable cross-room raw-device token. Lifecycle deadlines, a bounded authentication gate, `preferNoProxies`, and room-scoped SHA-256 reconnect credentials now cover these paths. Review then caught the first auth deadline starting before inbound readiness; it is now split into an 8-second ready window and a 2-second post-ready authentication window. Focused, coordinator-integration, and delayed-ready cases pass (`/tmp/IndustrialCity-r41-green2-20260829.xcresult`, `/tmp/IndustrialCity-r41-integration-20260829.xcresult`, `/tmp/IndustrialCity-r41-ready-green-20260829.xcresult`). |
| R42 | BUG FIXED | Highlighted industry placements now expose stable `map.target.<placementID>` controls with distinct Chinese state labels, and paired semantic/physical tap delivery no longer falls through to the map background. The iPhone map-dismiss regression now hits the authoritative Birmingham fixture point and proves target selection via enabled confirmation; the shell test measures the visible clipped frame. Focused routing tests pass 2/2, iPhone UI passes 7/7, and iPad UI passes 6/6 (`/tmp/IndustrialCity-R42-TapRouting-GREEN.xcresult`, `/tmp/IndustrialCity-R42-iPhone-Focused-FINAL.xcresult`, `/tmp/IndustrialCity-R42-iPad-Focused-FINAL-2.xcresult`). |
| R43 | BLOCKED | The 243-row review artifact is internally complete and automation passes, but every row remains `pending` and no independent human checker evidence exists. The draft manifest must remain fail closed; automated evidence is `/tmp/r43-game-data-audit.x9hrur/R43-GameData.xcresult`. |
| R44 | BUG FIXED | The closed bundled-resource allowlist omitted all 25 MatchChrome files. It now hash-pins the exact 12 PNG plus 13 `Contents.json` files and rejects unknown files; verifier self-test passes 19/19. The release gate now stops only on R43. A real opaque 1024-square AppIcon was also added and hash-pinned with a 20/20 self-test. |

The result bundles are under `/tmp/IndustrialCity-*` on the audit machine. They are ephemeral supporting evidence; the regression tests in the repository are the durable evidence.

## Post-matrix defects fixed during final integration

- Lobby start now rejects a previously ready seat that has disconnected. Both the coordinator and view-store entry point require the token roster, ready set, and connected set to agree.
- An existing seat reconnect no longer rewrites its already durable token or evicts the seat when the secure store later becomes unavailable.
- New seat assignment is now a two-phase operation: a pending seat is excluded from the roster, readiness, capacity completion, and game start until its reconnect token is durably saved. A failed save rolls the pending assignment back and returns `persistenceUnavailable`.
- Guest and preflight UI now preserve `persistenceUnavailable` as a distinct save/retry failure instead of misreporting it as room capacity or network distance.
- Focused red/green evidence is retained in `/tmp/IndustrialCity-existing-seat-reconnect-RED-20260829.xcresult`, `/tmp/IndustrialCity-existing-seat-reconnect-GREEN-20260829.xcresult`, `/tmp/IndustrialCity-pending-seat-RED3-20260830.xcresult`, `/tmp/IndustrialCity-seat-persistence-GREEN2-20260830.xcresult`, `/tmp/IndustrialCity-seat-error-ui-RED-20260830.xcresult`, and `/tmp/IndustrialCity-seat-error-ui-GREEN-20260830.xcresult`.
- An independent post-fix review approved the final session/persistence changes with 0 critical, high, medium, or low findings.

## Final current-source gate evidence (2026-08-30)

- Complete serial unit suite: 568/568 passed, 0 failed (`/tmp/IndustrialCity-Final4-Unit-Serial-20260830.xcresult`). A prior default-parallel run was rejected as evidence after simulator saturation produced join timeouts.
- Generic iOS Simulator Release build: `** BUILD SUCCEEDED **` (`/tmp/IndustrialCity-Final4-Release-20260830.log`).
- Release fixture boundary: all six forbidden fixture/debug symbols were 0 in source, binary, and module; `Release fixture boundary verified.`
- Real two-simulator room smoke: iPhone host and iPad guest created, joined, started, submitted an intent, and converged to authoritative version 2; `two-simulator local room smoke passed` (`/tmp/IndustrialCity-Final4-TwoSimulator-20260830.log`).
- Complete iPhone UI suite: 44 total, 42 passed, 2 device-conditional skips, 0 failed (`/tmp/IndustrialCity-Final5-UI-iPhone-20260830.xcresult`).
- Complete iPad UI suite: 44 total, 39 passed, 5 device-conditional skips, 0 failed (`/tmp/IndustrialCity-Final5-UI-iPad-20260830.xcresult`).
- Visual regression gate initially failed because all 12 baselines predated the approved Chinese-map, era-route, and Victorian-industrial UI. The current captures were visually reviewed, recorded through the repository's baseline workflow, then independently recaptured. All 12 comparisons passed; maximum changed-pixel ratio was 0.0811% against the 0.5% threshold (`/tmp/IndustrialCity-Final6-SnapshotGate-GREEN-20260830.log`).
- `git diff --check`, shell syntax, verifier fixture tests, game-data verifier self-test (20/20), two-simulator script self-test, and physical-metrics validator self-test passed.
- The production data gate intentionally remains fail closed with exactly `manifest.verificationStatus: expected verified; data remains a draft and cannot drive gameplay`. No automated test may replace the second-human R43 sign-off.
- The only attached physical iPhone is currently reported as `unavailable` by `devicectl` and is absent from Xcode destinations. Physical-device local-network, VoiceOver, and 30-minute performance evidence therefore remain not run; simulator evidence does not satisfy those gates.

## Completion criteria

- Every matrix row has a subagent result and supporting evidence.
- Every confirmed software defect has a red regression test, a reviewed minimal fix, and a green focused test.
- No unresolved P0/P1 software defects remain.
- The complete unit/UI/build/paired-device gates pass from a clean checkout.
- R43 is signed off independently and the manifest is promoted only with that evidence.
- Any remaining environmental or product limitation is stated explicitly in the release report rather than hidden behind a green unit-test count.
