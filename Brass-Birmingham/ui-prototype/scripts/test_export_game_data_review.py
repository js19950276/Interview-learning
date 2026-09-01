#!/usr/bin/env python3
from __future__ import annotations

import copy
import hashlib
import json
import os
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export_game_data_review as review
import verify_game_data as verifier


REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "IndustrialCityBirmingham" / "GameData" / "v2018.11"


class GameDataReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = review.build_review(DATA_DIR)

    def write_document(self, document: dict) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="game-data-review-test-")
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "review.jsonl"
        review.write_review(document, path)
        return path

    def checked_document(self) -> dict:
        document = copy.deepcopy(self.document)
        for row in document["rows"]:
            row["checker"] = "Independent Human"
            row["checkerID"] = "independent-human"
            row["checkedOn"] = "2026-08-19"
            row["status"] = "checked"
        return document

    def test_export_is_stable_complete_and_has_auditable_rows(self) -> None:
        self.assertEqual(self.document, review.build_review(DATA_DIR))
        self.assertEqual(len(self.document["rows"]), 243)
        self.assertEqual(len({row["locator"] for row in self.document["rows"]}), 243)
        self.assertEqual(
            set(self.document["coverage"]),
            {"map.locations", "map.routes", "map.merchantSlots", "industries.levels", "cards", "merchants", "income-track.entries"},
        )
        for row in self.document["rows"]:
            self.assertTrue(row["locator"])
            self.assertTrue(row["jsonPointer"])
            self.assertEqual(len(row["rowSha256"]), 64)
            self.assertTrue(row["sourceRefs"])
            self.assertEqual(row["status"], "pending")
            self.assertEqual(row["checker"], "")
            self.assertEqual(row["checkerID"], "")
            self.assertEqual(row["checkedOn"], "")
        source_ids = {source["id"] for source in self.document["sourceCatalog"]}
        referenced = {source_id for row in self.document["rows"] for source_id in row["sourceRefs"]}
        self.assertEqual(referenced, source_ids)

    def test_export_rejects_incomplete_source_provenance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="game-data-source-test-") as temporary:
            copied = Path(temporary) / "v2018.11"
            import shutil

            shutil.copytree(DATA_DIR, copied)
            manifest_path = copied / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["sources"].pop()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(review.ReviewError, "source provenance"):
                review.build_review(copied)

            manifest = json.loads((DATA_DIR / "manifest.json").read_text(encoding="utf-8"))
            manifest["sources"][0]["transcriberID"] = "codex-\uff41gent"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(review.ReviewError, "transcriberID"):
                review.build_review(copied)

    def test_each_canonical_json_value_is_exactly_the_value_at_its_pointer(self) -> None:
        documents = {
            name: json.loads((DATA_DIR / name).read_text(encoding="utf-8"))
            for name in review.CANONICAL_FILES
        }
        for row in self.document["rows"]:
            value = documents[row["sourceFile"]]
            for component in row["jsonPointer"].split("/")[1:]:
                value = value[int(component)] if isinstance(value, list) else value[component]
            self.assertEqual(row["canonicalJSON"], value, row["locator"])

    def test_review_rejects_tamper_missing_duplicate_and_wrong_hash(self) -> None:
        cases: list[tuple[str, dict, str]] = []

        tampered = copy.deepcopy(self.document)
        tampered["rows"][0]["canonicalJSON"]["name"] = "tampered"
        cases.append(("tamper", tampered, "immutable row content differs"))

        missing = copy.deepcopy(self.document)
        missing["rows"].pop()
        cases.append(("missing", missing, "review coverage differs"))

        duplicate = copy.deepcopy(self.document)
        duplicate["rows"].append(copy.deepcopy(duplicate["rows"][0]))
        cases.append(("duplicate", duplicate, "duplicate locator"))

        wrong_hash = copy.deepcopy(self.document)
        wrong_hash["fileHashes"]["map.json"] = "0" * 64
        cases.append(("wrong-hash", wrong_hash, "file hash binding differs"))

        for name, document, expected in cases:
            with self.subTest(name=name):
                errors = review.validate_review(DATA_DIR, self.write_document(document))
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_strict_jsonl_rejects_duplicate_keys_non_finite_and_noncanonical_lines(self) -> None:
        valid_path = self.write_document(self.document)
        lines = valid_path.read_text(encoding="utf-8").splitlines()
        cases = {
            "duplicate-key": lines[0][:-1] + ',"rowCount":243}',
            "non-finite": lines[0].replace('"schemaVersion":1', '"schemaVersion":NaN'),
            "noncanonical": lines[0].replace('"artifactType"', ' "artifactType"', 1),
            "extra-header": lines[0][:-1] + ',"ambiguous":true}',
        }
        for name, header in cases.items():
            with self.subTest(name=name):
                temporary = tempfile.TemporaryDirectory(prefix="strict-review-test-")
                self.addCleanup(temporary.cleanup)
                path = Path(temporary.name) / "review.jsonl"
                path.write_text("\n".join([header, *lines[1:]]) + "\n", encoding="utf-8")
                self.assertTrue(review.validate_review(DATA_DIR, path))

        extra_row = copy.deepcopy(self.document)
        extra_row["rows"][0]["ambiguous"] = True
        errors = review.validate_review(DATA_DIR, self.write_document(extra_row))
        self.assertTrue(any("allowed keys" in error for error in errors), errors)

    def test_review_is_invalidated_by_any_canonical_data_change(self) -> None:
        with tempfile.TemporaryDirectory(prefix="game-data-change-test-") as temporary:
            copied = Path(temporary) / "v2018.11"
            import shutil

            shutil.copytree(DATA_DIR, copied)
            cards = json.loads((copied / "cards.json").read_text(encoding="utf-8"))
            cards[0]["count"] += 1
            (copied / "cards.json").write_text(json.dumps(cards), encoding="utf-8")
            errors = review.validate_review(copied, self.write_document(self.document))
            self.assertTrue(errors)
            self.assertTrue(any("hash" in error for error in errors), errors)

    def test_suggestion_requires_every_row_checked_by_an_independent_person(self) -> None:
        partial = self.checked_document()
        partial["rows"][0]["status"] = "pending"
        with self.assertRaisesRegex(review.ReviewError, "all rows must be checked"):
            review.suggest_manifest_metadata(DATA_DIR, self.write_document(partial))

        self_checked = self.checked_document()
        for row in self_checked["rows"]:
            row["checker"] = "codex"
            row["checkerID"] = "codex-agent"
        with self.assertRaisesRegex(review.ReviewError, "checker must differ from every transcriber"):
            review.suggest_manifest_metadata(DATA_DIR, self.write_document(self_checked))

    def test_review_validation_rejects_self_checker_and_invalid_checked_date(self) -> None:
        self_checked = self.checked_document()
        for row in self_checked["rows"]:
            row["checker"] = "codex"
            row["checkerID"] = "codex-agent"
        errors = review.validate_review(DATA_DIR, self.write_document(self_checked))
        self.assertTrue(any("checker must differ" in error for error in errors), errors)

        invalid_date = self.checked_document()
        invalid_date["rows"][0]["checkedOn"] = "2026-99-99"
        errors = review.validate_review(DATA_DIR, self.write_document(invalid_date))
        self.assertTrue(any("valid YYYY-MM-DD" in error for error in errors), errors)

    def test_identity_audit_rejects_unicode_whitespace_controls_and_future_dates(self) -> None:
        cases = []
        non_nfkc = self.checked_document()
        non_nfkc["rows"][0]["checkerID"] = "fullwidth-\uff41"
        cases.append(non_nfkc)
        whitespace = self.checked_document()
        whitespace["rows"][0]["checkerID"] = " independent-human"
        cases.append(whitespace)
        control = self.checked_document()
        control["rows"][0]["checker"] = "Independent\u200bHuman"
        cases.append(control)
        future = self.checked_document()
        future["rows"][0]["checkedOn"] = "2999-01-01"
        cases.append(future)
        for document in cases:
            errors = review.validate_review(DATA_DIR, self.write_document(document))
            self.assertTrue(errors)

    def test_checked_dates_use_a_utc_civil_today_boundary(self) -> None:
        utc_today = date(2026, 8, 20)
        self.assertTrue(review.valid_checked_date("2026-08-20", today=utc_today))
        self.assertFalse(review.valid_checked_date("2026-08-21", today=utc_today))

    def test_export_refuses_existing_and_symlink_targets_without_changing_them(self) -> None:
        with tempfile.TemporaryDirectory(prefix="safe-review-export-") as temporary:
            directory = Path(temporary)
            existing = directory / "existing.jsonl"
            existing.write_text("keep-me", encoding="utf-8")
            with self.assertRaisesRegex(review.ReviewError, "already exists"):
                review.write_review(self.document, existing)
            self.assertEqual(existing.read_text(encoding="utf-8"), "keep-me")

            destination = directory / "destination.jsonl"
            destination.write_text("keep-destination", encoding="utf-8")
            symlink = directory / "review.jsonl"
            os.symlink(destination, symlink)
            with self.assertRaisesRegex(review.ReviewError, "already exists"):
                review.write_review(self.document, symlink)
            self.assertEqual(destination.read_text(encoding="utf-8"), "keep-destination")

            missing_destination = directory / "missing-destination.jsonl"
            dangling = directory / "dangling.jsonl"
            os.symlink(missing_destination, dangling)
            with self.assertRaisesRegex(review.ReviewError, "already exists"):
                review.write_review(self.document, dangling)
            self.assertFalse(missing_destination.exists())

    def test_verified_manifest_requires_complete_review_evidence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="verified-evidence-test-") as temporary:
            copied = Path(temporary) / "v2018.11"
            import shutil

            shutil.copytree(DATA_DIR, copied)
            manifest_path = copied / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["verificationStatus"] = "verified"
            for source in manifest["sources"]:
                source["checker"] = "Independent Human"
                source["checkerID"] = "independent-human"
                source["checkedOn"] = "2026-08-19"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            errors = verifier.validate(copied)
            self.assertTrue(any("verificationEvidence" in error for error in errors), errors)

    def test_complete_review_evidence_makes_a_verified_manifest_auditable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="complete-evidence-test-") as temporary:
            copied = Path(temporary) / "v2018.11"
            import shutil

            shutil.copytree(DATA_DIR, copied)
            document = review.build_review(copied)
            for row in document["rows"]:
                row["checker"] = "Independent Human"
                row["checkerID"] = "independent-human"
                row["checkedOn"] = "2026-08-19"
                row["status"] = "checked"
            artifact = copied / "verification-review.jsonl"
            review.write_review(document, artifact)
            suggestion = review.suggest_manifest_metadata(copied, artifact)

            manifest_path = copied / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["verificationStatus"] = "verified"
            manifest["verificationEvidence"] = suggestion["verificationEvidence"]
            suggested_sources = {source["id"]: source for source in suggestion["sources"]}
            for source in manifest["sources"]:
                approved = suggested_sources[source["id"]]
                for field in ("checker", "checkerID", "checkedOn"):
                    source[field] = approved[field]
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            self.assertEqual(verifier.validate(copied), [])

    def test_manifest_loader_rejects_duplicate_keys_non_finite_and_duplicate_source_ids(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strict-manifest-test-") as temporary:
            copied = Path(temporary) / "v2018.11"
            import shutil

            shutil.copytree(DATA_DIR, copied)
            manifest_path = copied / "manifest.json"
            original = manifest_path.read_text(encoding="utf-8")
            manifest_path.write_text(original[:-2] + ',\n  "rulesetVersion": "v2018.11"\n}\n', encoding="utf-8")
            self.assertTrue(any("duplicate key" in error for error in verifier.validate(copied)))

            manifest_path.write_text(original.replace('"rulesetVersion": "v2018.11"', '"rulesetVersion": NaN'), encoding="utf-8")
            self.assertTrue(any("non-finite" in error for error in verifier.validate(copied)))

            manifest = json.loads(original)
            manifest["sources"][1]["id"] = manifest["sources"][0]["id"]
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(any("source IDs must be unique" in error for error in verifier.validate(copied)))

    def test_bundled_resource_audit_allows_original_asset_and_rejects_external_map(self) -> None:
        self.assertEqual(verifier.validate_bundled_resources(REPO_ROOT), [])
        with tempfile.TemporaryDirectory(prefix="bundled-resource-test-") as temporary:
            repo = Path(temporary)
            import shutil

            shutil.copytree(REPO_ROOT / "IndustrialCityBirmingham", repo / "IndustrialCityBirmingham")
            project = repo / "IndustrialCityBirmingham.xcodeproj"
            project.mkdir()
            shutil.copy2(
                REPO_ROOT / "IndustrialCityBirmingham.xcodeproj/project.pbxproj",
                project / "project.pbxproj",
            )
            external = repo / "IndustrialCityBirmingham/Assets.xcassets/OfficialMap.imageset"
            external.mkdir()
            (external / "official-map.png").write_bytes(b"external official map")
            errors = verifier.validate_bundled_resources(repo)
            self.assertTrue(any("official-map.png" in error for error in errors), errors)

            forbidden_fixtures = {
                "foreign-map.svg": b"<svg/>",
                "foreign-font.ttf": b"font",
                "foreign-audio.mp3": b"audio",
                "foreign-map.tiff": b"tiff",
                "foreign-map.bmp": b"bmp",
                "foreign-map.avif": b"avif",
                "foreign-map.eps": b"eps",
                "foreign-map.psd": b"psd",
                "foreign-map.ai": b"ai",
                "foreign-font.woff2": b"woff2",
                "foreign-video.mov": b"mov",
                "foreign-video.mp4": b"mp4",
            }
            for name, payload in forbidden_fixtures.items():
                (repo / "IndustrialCityBirmingham" / name).write_bytes(payload)
            symlink_directory = repo / "IndustrialCityBirmingham" / "LinkedReference"
            symlink_directory.symlink_to(repo / "missing-reference-directory", target_is_directory=True)
            errors = verifier.validate_bundled_resources(repo)
            for name in [*forbidden_fixtures, "LinkedReference"]:
                self.assertTrue(any(name in error for error in errors), (name, errors))

    def test_match_chrome_catalog_is_explicitly_hash_pinned(self) -> None:
        asset_names = {
            "industry-brewery-medallion",
            "industry-coal-medallion",
            "industry-cotton-medallion",
            "industry-iron-medallion",
            "industry-manufacturer-medallion",
            "industry-pottery-medallion",
            "match-brass-corner",
            "match-card-texture",
            "match-iron-horizontal",
            "match-iron-vertical",
            "match-parchment-label",
            "match-wood-fill",
        }
        prefix = "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/"
        expected_paths = {f"{prefix}Contents.json"}
        for name in asset_names:
            expected_paths.add(f"{prefix}{name}.imageset/Contents.json")
            expected_paths.add(f"{prefix}{name}.imageset/asset.png")

        catalog_root = REPO_ROOT / "IndustrialCityBirmingham/Assets.xcassets/MatchChrome"
        catalog_paths = {
            path.relative_to(REPO_ROOT).as_posix()
            for path in catalog_root.rglob("*")
            if path.is_file()
        }
        pinned_paths = {
            path
            for path in verifier.ALLOWED_FIXED_BUNDLED_RESOURCES
            if path.startswith(prefix)
        }

        self.assertEqual(len([path for path in expected_paths if path.endswith("asset.png")]), 12)
        self.assertEqual(len([path for path in expected_paths if path.endswith("Contents.json")]), 13)
        self.assertEqual(catalog_paths, expected_paths)
        self.assertEqual(pinned_paths, expected_paths)
        for relative in expected_paths:
            actual_hash = hashlib.sha256((REPO_ROOT / relative).read_bytes()).hexdigest()
            self.assertEqual(verifier.ALLOWED_FIXED_BUNDLED_RESOURCES[relative], actual_hash)

    def test_app_icon_is_an_opaque_hash_pinned_1024_square(self) -> None:
        catalog = REPO_ROOT / "IndustrialCityBirmingham/Assets.xcassets/AppIcon.appiconset"
        contents = json.loads((catalog / "Contents.json").read_text(encoding="utf-8"))
        base_slots = [entry for entry in contents["images"] if "appearances" not in entry]

        self.assertEqual(len(base_slots), 1)
        self.assertEqual(base_slots[0].get("filename"), "app-icon.png")
        icon = catalog / "app-icon.png"
        png = icon.read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(
            (int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big")),
            (1024, 1024),
        )
        self.assertNotIn(png[25], (4, 6), "iOS app icon must not contain an alpha channel")
        chunk_types = []
        cursor = 8
        while cursor + 12 <= len(png):
            length = int.from_bytes(png[cursor:cursor + 4], "big")
            chunk_type = png[cursor + 4:cursor + 8]
            chunk_types.append(chunk_type)
            cursor += 12 + length
            if chunk_type == b"IEND":
                break
        self.assertNotIn(b"tRNS", chunk_types, "iOS app icon must not use PNG transparency")
        self.assertEqual(chunk_types[-1], b"IEND")

        relative = icon.relative_to(REPO_ROOT).as_posix()
        self.assertEqual(
            verifier.ALLOWED_FIXED_BUNDLED_RESOURCES[relative],
            hashlib.sha256(png).hexdigest(),
        )

    def test_bundled_resource_audit_rejects_a_symlinked_app_root(self) -> None:
        with tempfile.TemporaryDirectory(prefix="bundled-root-symlink-test-") as temporary:
            repo = Path(temporary)
            import shutil

            real_app = repo / "RealIndustrialCityBirmingham"
            shutil.copytree(REPO_ROOT / "IndustrialCityBirmingham", real_app)
            (repo / "IndustrialCityBirmingham").symlink_to(real_app, target_is_directory=True)
            project = repo / "IndustrialCityBirmingham.xcodeproj"
            project.mkdir()
            shutil.copy2(
                REPO_ROOT / "IndustrialCityBirmingham.xcodeproj/project.pbxproj",
                project / "project.pbxproj",
            )

            errors = verifier.validate_bundled_resources(repo)
            self.assertTrue(any("app root" in error and "symlink" in error for error in errors), errors)

    def test_bundled_resource_audit_rejects_external_resource_directories_and_symlink_roots(self) -> None:
        with tempfile.TemporaryDirectory(prefix="bundled-external-root-test-") as temporary:
            repo = Path(temporary)
            import shutil

            shutil.copytree(REPO_ROOT / "IndustrialCityBirmingham", repo / "IndustrialCityBirmingham")
            project = repo / "IndustrialCityBirmingham.xcodeproj"
            project.mkdir()
            project_text = (
                REPO_ROOT / "IndustrialCityBirmingham.xcodeproj/project.pbxproj"
            ).read_text(encoding="utf-8")
            project_text = project_text.replace(
                "/* Begin PBXFileReference section */",
                """/* Begin PBXBuildFile section */
		d14a10000000000000000001 /* ReferenceAssets in Resources */ = {fileRef = d14a20000000000000000001 /* ReferenceAssets */; isa = PBXBuildFile; };
		d14a10000000000000000002 /* LinkedAssets in Resources */ = {fileRef = d14a20000000000000000002 /* LinkedAssets */; isa = PBXBuildFile; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */""",
            ).replace(
                "/* End PBXFileReference section */",
                """		d14a20000000000000000001 /* ReferenceAssets */ = {sourceTree = SOURCE_ROOT; path = ReferenceAssets; lastKnownFileType = folder; isa = PBXFileReference; };
		d14a20000000000000000002 /* LinkedAssets */ = {sourceTree = SOURCE_ROOT; path = LinkedAssets; lastKnownFileType = folder; isa = PBXFileReference; };
/* End PBXFileReference section */""",
            ).replace(
                "0A43865630296951007D4985 /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (",
                "0A43865630296951007D4985 /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\td14a10000000000000000001 /* ReferenceAssets in Resources */,\n\t\t\t\td14a10000000000000000002 /* LinkedAssets in Resources */,\n\t\t\t\tdeadbeefdeadbeefdeadbeef /* Unresolved in Resources */,")
            project_text = "\n".join(
                line for line in project_text.splitlines()
                if not ("PBX" in line and "section */" in line)
            ) + "\n"
            (project / "project.pbxproj").write_text(project_text, encoding="utf-8")

            reference_assets = repo / "ReferenceAssets"
            reference_assets.mkdir()
            (reference_assets / "official-map.bin").write_bytes(b"unknown external resource")
            linked_target = repo / "ActualLinkedAssets"
            linked_target.mkdir()
            (linked_target / "official-map.png").write_bytes(b"linked external resource")
            (repo / "LinkedAssets").symlink_to(linked_target, target_is_directory=True)

            errors = verifier.validate_bundled_resources(repo)
            self.assertTrue(any("ReferenceAssets" in error for error in errors), errors)
            self.assertTrue(any("LinkedAssets" in error and "symlink" in error for error in errors), errors)
            self.assertTrue(any("deadbeefdeadbeefdeadbeef" in error for error in errors), errors)

    def test_complete_review_produces_advisory_metadata_without_writing_manifest(self) -> None:
        manifest_path = DATA_DIR / "manifest.json"
        before = manifest_path.read_bytes()
        suggestion = review.suggest_manifest_metadata(
            DATA_DIR, self.write_document(self.checked_document())
        )
        self.assertEqual(manifest_path.read_bytes(), before)
        self.assertEqual(suggestion["verificationStatus"], "verified")
        self.assertEqual(suggestion["baseDataDigest"], self.document["baseDataDigest"])
        self.assertEqual(
            suggestion["reviewArtifactSha256"],
            review.sha256_bytes(self.write_document(self.checked_document()).read_bytes()),
        )
        self.assertEqual(
            {source["checker"] for source in suggestion["sources"]},
            {"Independent Human"},
        )
        self.assertEqual(
            {source["checkedOn"] for source in suggestion["sources"]},
            {"2026-08-19"},
        )
        self.assertEqual(
            {source["checkerID"] for source in suggestion["sources"]},
            {"independent-human"},
        )
        self.assertEqual(suggestion["verificationEvidence"]["rowCount"], 243)
        self.assertEqual(
            suggestion["verificationEvidence"]["baseDataDigest"],
            self.document["baseDataDigest"],
        )


if __name__ == "__main__":
    unittest.main()
