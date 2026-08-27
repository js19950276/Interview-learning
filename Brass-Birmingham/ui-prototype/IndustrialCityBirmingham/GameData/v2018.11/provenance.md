# Brass: Birmingham game-data provenance

Ruleset: `v2018.11`

Status: **DRAFT - STRUCTURALLY COMPLETE, NOT READY FOR GAMEPLAY**

## Source policy

- Official artwork, board scans, player-mat scans, card faces, icons, fonts, audio and the rulebook PDF are not stored in this repository or bundled into the app.
- This directory contains only transcribed structured values, source links, hashes and verification metadata.
- External images or documents may be inspected temporarily as references, but are deleted after transcription.
- Data is not marked `verified` until every row has a named transcriber, a different human checker and dates for both passes.
- `DemoFixture` and the prototype map are not rules sources and must never be used to approve this catalog.

## Sources

| ID | Role | Version / license | URL | Transcriber | Independent checker |
| --- | --- | --- | --- | --- | --- |
| `roxley-rulebook-v2018.11` | Official rules, setup, component totals and era constraints | 2018.11; PDF SHA-256 `bb627a11c769957fbb5f26a210e3957ae27a2bad054ba9cb3b4fadc6c2ba73e5` | https://cdn.shopify.com/s/files/1/0246/2190/8043/files/Brass-Birmingham-Rulebook.pdf?v=1758826281 | Codex, 2026-08-17 | Pending |
| `bge-brass-birmingham-d11d438` | Primary structured transcription reference for map, cards, industries, merchants and income | commit `d11d438c7c22b87c3b10f52116bf2b59bacfcc18`; MIT | https://github.com/a-whitehouse/bge-brass-birmingham/tree/d11d438c7c22b87c3b10f52116bf2b59bacfcc18/src/data | Codex, 2026-08-17 | Pending |
| `brassrl-457519c` | Independent implementation cross-check for map, markets and industries | commit `457519c5c8a7b709969e62279923acde99d043ea`; MIT | https://github.com/LahavBarak/BrassRL/tree/457519c5c8a7b709969e62279923acde99d043ea/Resources | Codex, 2026-08-17 | Pending |
| `npow-brass-birmingham-2b1da2d` | Third factual cross-check for disputed rows and masks; no source code copied | commit `2b1da2d41036f2afaafcab320b2175ba3fd9f877`; no explicit repository license found | https://github.com/npow/brass-birmingham/blob/2b1da2d41036f2afaafcab320b2175ba3fd9f877/js/gameData.js | Codex, 2026-08-17 | Pending |

The official rulebook establishes rules and component totals, but it does not contain every map edge, card identity, player-mat row or merchant distribution in a machine-readable table. The community implementations above were therefore used only as numeric transcription and cross-check references. Their agreement is useful evidence, but it is not a substitute for the required second-person physical-component check.

## Catalog coverage

The draft currently contains:

- 27 board locations, 49 industry slots, 39 routes and 9 merchant-board slots;
- all 64 standard cards, 4 wild-location cards and 4 wild-industry cards, including 2/3/4-player masks;
- all 45 industry tiles per player colour, including costs, resources, production, sale beer, income, victory points, link icons, eras and develop restrictions;
- all 9 merchant tiles, accepted industries and player-count masks;
- all 100 income-track positions.

The verifier also enforces the official component totals:

- 180 industry tiles: 45 per player colour;
- per colour: 11 cotton mills, 11 manufacturers, 7 breweries, 5 potteries, 4 iron works and 7 coal mines;
- 64 standard cards plus 4 cards of each wild type;
- 9 merchant tiles;
- supported player counts 2, 3 and 4.

## Cross-source discrepancy record

- Manufacturer level 4 build cost: the primary MIT source says `14`; BrassRL and the third implementation both say `8`. The draft records `8` and requires the human checker to confirm it against a physical player mat.
- The primary MIT source labels its final two merchant slots as Warrington even though their map positions correspond to Nottingham. The official board context and the third implementation identify Nottingham; the draft records Nottingham and requires physical-board confirmation.

No unresolved discrepancy was silently guessed. Any future disagreement must be added here before changing the catalog.

## Automated checks already complete

- Every JSON file is covered by the SHA-256 manifest.
- Schema, IDs, references, masks, counts, route eras, income progression and representative disputed rows have executable tests.
- `scripts/verify_game_data.sh --self-test` proves that structural corruption, hash mismatch and an unverified manifest are rejected.
- The normal data gate intentionally rejects this catalog while `verificationStatus` remains `draft` or checker metadata is absent.

## Remaining manual gate

One person other than the transcriber must compare every row with a legally held physical copy or another authorized component reference. After that check:

1. record the checker and `checkedOn` date for every source entry in `manifest.json`;
2. resolve and document any discovered discrepancies;
3. change `verificationStatus` from `draft` to `verified`;
4. run the full data gate and unit suite before allowing GameCore to load the catalog.

Until all four steps are complete, this data must not drive a real match.
