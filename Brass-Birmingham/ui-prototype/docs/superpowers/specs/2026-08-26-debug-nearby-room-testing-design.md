# Debug Nearby Room Testing Design

## Goal

Allow two Debug simulator builds to exercise the real nearby-room create, browse, join, lobby, and match flow even while the packaged production rules catalog intentionally remains unverified.

## Design

- Add a Debug-only `-nearby-fixture-catalog` launch argument.
- Keep the real `ProductionNearbyRoomView`; do not use the deterministic demo-room UI or the direct local script harness.
- Resolve the launch argument to a catalog source. The default source remains the packaged production catalog, while the Debug argument selects `loadBundledFixtureCatalog()`.
- Pass the catalog that passed preflight into host and guest session construction so room creation does not reload a different catalog.
- Compile the fixture source and launch handling only in Debug. Release behavior remains fail-closed until the independent data review is complete.

## Alternatives Rejected

- Direct local harness launch skips the create/search screen and therefore cannot validate the user's current flow.
- Marking the production manifest as verified would bypass an intentional integrity gate without the required independent review artifact.

## Verification

- A UI regression test launches without the normal demo fixture, supplies `-nearby-fixture-catalog`, opens the real nearby-room page, and requires the create button to be enabled.
- Targeted unit/UI tests, a Debug build, and a two-simulator manual smoke check must pass before handoff.
