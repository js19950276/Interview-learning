# Original Art Provenance

This record covers project-created raster artwork. It is an engineering provenance record, not a legal opinion or a substitute for a distribution-rights review.

## MatchChrome

- Paths: `IndustrialCityBirmingham/Assets.xcassets/MatchChrome/**`
- Added in commit: `2532b39` (`feat: ship steam-inspired Brass Birmingham prototype`)
- Method: generated as separate original raster assets with the built-in OpenAI image-generation tool, then visually inspected, resized/cropped as needed, and imported into the asset catalog.
- Durable design/prompt record: `docs/superpowers/specs/2026-08-27-steam-inspired-match-ui-design.md` and `docs/superpowers/plans/2026-08-27-steam-inspired-match-ui.md`.
- Input constraint: no official game image was supplied as an edit/reference target. Prompts explicitly prohibited text, logos, maps, recognizable Brass: Birmingham artwork, copied board-game icons, and watermarks.
- Integrity: every PNG and `Contents.json` is individually SHA-256 pinned by `scripts/verify_game_data.py`.

## AppIcon

- Path: `IndustrialCityBirmingham/Assets.xcassets/AppIcon.appiconset/app-icon.png`
- Generated: 2026-08-29 with the built-in OpenAI image-generation tool; no input image was used.
- Final transformation: the generated opaque square was resized to 1024 x 1024 without compositing another work.
- Final SHA-256: `a947768619b2d3316fa3d99e8d94b1413659c6217ebe21dc39fcb54c5e893908`.
- Prompt summary: an original Victorian-industrial iOS icon with a centered aged-brass cog and compact nineteenth-century factory on a charcoal forged-iron field, no text, logo, map, cards, trains, watermark, recognizable Brass: Birmingham artwork, iconography, board layout, branding, or trade dress.
- Integrity and packaging: `scripts/test_export_game_data_review.py` checks the PNG signature, exact 1024-square dimensions, lack of alpha, asset-catalog filename, and allowlist hash.

## Distribution boundary

The project does not claim or bundle official Brass: Birmingham artwork. Before public or commercial distribution, review the game name, rules implementation, generated assets, fonts, and all third-party factual data sources under the applicable platform and jurisdiction requirements.
