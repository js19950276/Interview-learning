#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Any

from export_game_data_review import (
    ReviewError,
    strict_loads,
    suggest_manifest_metadata,
    valid_checked_date,
    valid_identity,
    valid_identity_id,
)


RULESET = "v2018.11"
EXPECTED_FILES = {
    "map.json",
    "industries.json",
    "cards.json",
    "merchants.json",
    "income-track.json",
}
EXPECTED_INDUSTRIES = {
    "brewery": 7,
    "coal-mine": 7,
    "cotton-mill": 11,
    "iron-works": 4,
    "manufacturer": 11,
    "pottery": 5,
}
SUPPORTED_PLAYER_COUNTS = {2, 3, 4}
FORBIDDEN_SOURCE_SUFFIXES = {
    ".aac",
    ".aiff",
    ".gif",
    ".heic",
    ".jpeg",
    ".jpg",
    ".m4a",
    ".mp3",
    ".otf",
    ".pdf",
    ".png",
    ".svg",
    ".ttf",
    ".wav",
    ".webp",
}


def load_json(path: Path, errors: list[str]) -> Any:
    try:
        return strict_loads(path.read_text(encoding="utf-8"), path.name)
    except (OSError, ReviewError) as error:
        errors.append(f"{path.name}: invalid JSON: {error}")
        return None


ALLOWED_ORIGINAL_RASTERS = {
    "IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/industrial-map.png":
        "fc384bdecffb59a5a72c20d3aee7c933b5ae575472b0d82b36ee8622ff9b07a6",
}
ALLOWED_MATCH_CHROME_RESOURCES = {
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/Contents.json":
        "10e3b5dc202f1cd9fad1f688c8fc9fe9e9669bf3f8295e67d216b10fd99b6f49",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-brewery-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-brewery-medallion.imageset/asset.png":
        "1c3825c590de4bd4f8d99e200e1c2cd508656f919bef1d6030a6d705252a8531",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-coal-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-coal-medallion.imageset/asset.png":
        "66a585f5f23c968779a5e6759b62d60c45576c9e1908956b60675616d647505e",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-cotton-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-cotton-medallion.imageset/asset.png":
        "f95ed96a555bf4183e0ef87f04eb4040be09c4c7019e78a73879f89cd027215b",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-iron-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-iron-medallion.imageset/asset.png":
        "ecf94ea1167e4364a226ecfb7d229c508f66fe3e5c06d9e87de5ddf2cf7611ca",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-manufacturer-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-manufacturer-medallion.imageset/asset.png":
        "8bdaf3410b7c3401754c8d217a21dae25f41aec2a73ac2640a436e79c0d3b0a6",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-pottery-medallion.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/industry-pottery-medallion.imageset/asset.png":
        "c125762c5b966c03476f7d84d348d59ad26072f07f3bb705dc3d2b28ec7a42cd",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-brass-corner.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-brass-corner.imageset/asset.png":
        "80756a0590aaef48b32ac3f8f1f011af2260cf0917af5f8a922a831a8ae14abf",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-card-texture.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-card-texture.imageset/asset.png":
        "945b3719ac6e096786e9a9014ad3758928e672b8a1f302c74eaa80a350bc1dc3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-horizontal.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-horizontal.imageset/asset.png":
        "aa47a5af4eb3151ed898aa8f81e04d4b4dfc7afdbea6f02db769873eb088b7ad",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-vertical.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-iron-vertical.imageset/asset.png":
        "5675e3964cb4d6511c161db0e8854f5e82fe7770f4899e933859882aae34dfbe",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-parchment-label.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-parchment-label.imageset/asset.png":
        "0923c23e59d7f33e9f8cbf1e510fc9da18f8c3c9319243a427938cbadbadcfd4",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-wood-fill.imageset/Contents.json":
        "a199aa68cc686d81979107fe244fc51bd10b7bf63df94f36a2fefd1194f810f3",
    "IndustrialCityBirmingham/Assets.xcassets/MatchChrome/match-wood-fill.imageset/asset.png":
        "e5b197c44094d02dadd33147e346627d64721d1dd77d167f98c2c9210ff7094d",
}
ALLOWED_FIXED_BUNDLED_RESOURCES = {
    "IndustrialCityBirmingham/Assets.xcassets/AppIcon.appiconset/Contents.json":
        "b3a5afd5c382f750a652b3310fa6f2311ab1090cb7b854991efbddc97420f5de",
    "IndustrialCityBirmingham/Assets.xcassets/AppIcon.appiconset/app-icon.png":
        "a947768619b2d3316fa3d99e8d94b1413659c6217ebe21dc39fcb54c5e893908",
    "IndustrialCityBirmingham/Assets.xcassets/AccentColor.colorset/Contents.json":
        "9af65086fa30b49252fae1a1225731691de794f7775af74d71befeb507d12b7c",
    "IndustrialCityBirmingham/Assets.xcassets/IndustrialMap.imageset/Contents.json":
        "0c786ee122528f35b4bbe5c5b18a28fc6aeec0fd098d96375f48dbf33e239076",
    "IndustrialCityBirmingham/Assets.xcassets/Contents.json":
        "0fd49ba3c3585c709678e0046a821c3c60685ec7063720d30d3a3448be3a208b",
    "IndustrialCityBirmingham/GameData/v2018.11/provenance.md":
        "fc6e7fa3769724095551d7e1ceeb0a0e59a08fa7c613ad1b1288ab40cf97ef1b",
    **ALLOWED_ORIGINAL_RASTERS,
    **ALLOWED_MATCH_CHROME_RESOURCES,
}


PBX_ID_PATTERN = r"[A-Fa-f0-9]{24}"


def pbx_object_body(project_text: str, identifier: str) -> str | None:
    match = re.search(rf"(?m)^[ \t]*{re.escape(identifier)}\b[^=\r\n]*=\s*\{{", project_text)
    if match is None:
        return None
    start = match.end() - 1
    depth = 0
    for index in range(start, len(project_text)):
        if project_text[index] == "{":
            depth += 1
        elif project_text[index] == "}":
            depth -= 1
            if depth == 0:
                return project_text[start + 1:index]
    return None


def pbx_objects(project_text: str) -> dict[str, str]:
    identifiers = re.findall(
        rf"(?m)^[ \t]*({PBX_ID_PATTERN})\b[^=\r\n]*=\s*\{{",
        project_text,
    )
    return {
        identifier: body
        for identifier in identifiers
        if (body := pbx_object_body(project_text, identifier)) is not None
    }


def pbx_list_ids(body: str, field: str) -> tuple[list[str], list[str]]:
    match = re.search(rf"\b{re.escape(field)}\s*=\s*\((.*?)\);", body, re.DOTALL)
    if match is None:
        return [], [f"missing {field} list"]
    uncommented = re.sub(r"/\*.*?\*/", "", match.group(1), flags=re.DOTALL)
    identifiers: list[str] = []
    errors: list[str] = []
    for raw_entry in uncommented.split(","):
        entry = raw_entry.strip()
        if not entry:
            continue
        if re.fullmatch(PBX_ID_PATTERN, entry):
            identifiers.append(entry)
        else:
            errors.append(f"unparseable {field} entry: {entry}")
    return identifiers, errors


def pbx_scalar(body: str, field: str) -> str | None:
    match = re.search(rf"\b{re.escape(field)}\s*=\s*(.*?);", body, re.DOTALL)
    if match is None:
        return None
    value = re.sub(r"/\*.*?\*/", "", match.group(1), flags=re.DOTALL).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


def pbx_path(body: str) -> str | None:
    return pbx_scalar(body, "path")


def validate_bundled_resources(repo_root: Path) -> list[str]:
    errors: list[str] = []
    project = repo_root / "IndustrialCityBirmingham.xcodeproj" / "project.pbxproj"
    app_root = repo_root / "IndustrialCityBirmingham"
    if app_root.is_symlink():
        return ["bundled resources: app root symlink is forbidden"]
    if not app_root.is_dir():
        return ["bundled resources: app root must be a real directory"]
    try:
        project_text = project.read_text(encoding="utf-8")
    except OSError as error:
        return [f"bundled resources: cannot read project.pbxproj: {error}"]
    objects = pbx_objects(project_text)
    targets = [
        (identifier, body)
        for identifier, body in objects.items()
        if pbx_scalar(body, "isa") == "PBXNativeTarget"
        and (
            pbx_scalar(body, "name") == "IndustrialCityBirmingham"
            or pbx_scalar(body, "productName") == "IndustrialCityBirmingham"
        )
    ]
    if len(targets) != 1:
        return ["bundled resources: app target cannot be resolved"]
    _, target_body = targets[0]
    synchronized_roots = []
    synchronized_group_ids, synchronized_list_errors = pbx_list_ids(
        target_body, "fileSystemSynchronizedGroups"
    )
    errors.extend(f"bundled resources: {error}" for error in synchronized_list_errors)
    for group_id in synchronized_group_ids:
        group_body = objects.get(group_id)
        root_path = pbx_path(group_body) if group_body is not None else None
        if root_path is None:
            errors.append(f"bundled resources: synchronized root {group_id} cannot be resolved")
            continue
        synchronized_roots.append(root_path)
        root = repo_root / root_path
        if root.is_symlink():
            errors.append(f"bundled resources: synchronized root symlink is forbidden: {root_path}")
        elif not root.is_dir():
            errors.append(f"bundled resources: synchronized root must be a real directory: {root_path}")
        elif root_path != "IndustrialCityBirmingham":
            errors.append(f"bundled resources: unapproved synchronized resource root: {root_path}")
    if synchronized_roots != ["IndustrialCityBirmingham"]:
        errors.append("bundled resources: app target must use only the approved synchronized root")

    manifest_path = app_root / "GameData" / RULESET / "manifest.json"
    dynamic_resources = {
        f"IndustrialCityBirmingham/GameData/{RULESET}/manifest.json": None,
    }
    try:
        manifest = strict_loads(manifest_path.read_text(encoding="utf-8"), "manifest.json")
        for entry in manifest.get("files", []):
            if isinstance(entry, dict) and isinstance(entry.get("path"), str):
                dynamic_resources[
                    f"IndustrialCityBirmingham/GameData/{RULESET}/{entry['path']}"
                ] = entry.get("sha256")
        evidence = manifest.get("verificationEvidence")
        if isinstance(evidence, dict) and isinstance(evidence.get("path"), str):
            dynamic_resources[
                f"IndustrialCityBirmingham/GameData/{RULESET}/{evidence['path']}"
            ] = evidence.get("sha256")
    except (OSError, ReviewError) as error:
        errors.append(f"bundled resources: manifest cannot define data allowlist: {error}")

    for path in sorted(app_root.rglob("*")):
        relative = path.relative_to(repo_root).as_posix()
        if path.is_symlink():
            errors.append(f"bundled resources: symlink is forbidden: {relative}")
            continue
        if not path.is_file():
            continue
        if path.suffix == ".swift" or relative == "IndustrialCityBirmingham/Info.plist":
            continue
        if relative in ALLOWED_FIXED_BUNDLED_RESOURCES:
            expected_hash = ALLOWED_FIXED_BUNDLED_RESOURCES[relative]
            actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            if expected_hash != actual_hash:
                errors.append(f"bundled resources: approved resource hash mismatch: {relative}")
        elif relative in dynamic_resources:
            expected_hash = dynamic_resources[relative]
            if isinstance(expected_hash, str):
                actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
                if expected_hash != actual_hash:
                    errors.append(f"bundled resources: data resource hash mismatch: {relative}")
        else:
            errors.append(f"bundled resources: resource is not in the closed allowlist: {relative}")

    build_phase_ids, build_phase_list_errors = pbx_list_ids(target_body, "buildPhases")
    errors.extend(f"bundled resources: {error}" for error in build_phase_list_errors)
    resource_phase_bodies: list[tuple[str, str]] = []
    for phase_id in build_phase_ids:
        phase_body = objects.get(phase_id)
        if phase_body is None:
            errors.append(f"bundled resources: app build phase ID cannot be resolved: {phase_id}")
        elif pbx_scalar(phase_body, "isa") == "PBXResourcesBuildPhase":
            resource_phase_bodies.append((phase_id, phase_body))
    if len(resource_phase_bodies) != 1:
        errors.append("bundled resources: app target must have exactly one resolvable resources build phase")

    for phase_id, phase_body in resource_phase_bodies:
        resource_build_ids, resource_list_errors = pbx_list_ids(phase_body, "files")
        errors.extend(
            f"bundled resources: resources phase {phase_id}: {error}"
            for error in resource_list_errors
        )
        for build_id in resource_build_ids:
            build_body = objects.get(build_id)
            if build_body is None:
                errors.append(f"bundled resources: resource build file ID cannot be resolved: {build_id}")
                continue
            if pbx_scalar(build_body, "isa") != "PBXBuildFile":
                errors.append(f"bundled resources: resource phase entry is not a PBXBuildFile: {build_id}")
                continue
            reference_id = pbx_scalar(build_body, "fileRef")
            if reference_id is None or re.fullmatch(PBX_ID_PATTERN, reference_id) is None:
                errors.append(f"bundled resources: PBXBuildFile fileRef cannot be resolved: {build_id}")
                continue
            reference_body = objects.get(reference_id)
            if reference_body is None:
                errors.append(f"bundled resources: resource fileRef ID cannot be resolved: {reference_id}")
                continue
            if pbx_scalar(reference_body, "isa") != "PBXFileReference":
                errors.append(f"bundled resources: resource fileRef is not a PBXFileReference: {reference_id}")
                continue
            reference_path = pbx_path(reference_body)
            if reference_path is None:
                errors.append(f"bundled resources: Copy Bundle Resources reference {reference_id} cannot be resolved")
                continue
            source_tree = pbx_scalar(reference_body, "sourceTree")
            if source_tree not in {"SOURCE_ROOT", "<group>"}:
                errors.append(
                    f"bundled resources: unsupported Copy Bundle Resources sourceTree for {reference_path}"
                )
                continue
            resource_root = repo_root / reference_path
            if resource_root.is_symlink():
                errors.append(f"bundled resources: Copy Bundle Resources symlink is forbidden: {reference_path}")
            else:
                errors.append(f"bundled resources: unapproved Copy Bundle Resources entry: {reference_path}")
    return errors


def valid_player_counts(value: Any) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, int) for item in value)
        and len(value) == len(set(value))
        and set(value).issubset(SUPPORTED_PLAYER_COUNTS)
    )


def duplicate_ids(items: list[dict[str, Any]]) -> set[str]:
    seen: set[str] = set()
    duplicates: set[str] = set()
    for item in items:
        identifier = item.get("id")
        if not isinstance(identifier, str):
            continue
        if identifier in seen:
            duplicates.add(identifier)
        seen.add(identifier)
    return duplicates


def validate(data_dir: Path) -> list[str]:
    errors: list[str] = []
    manifest_path = data_dir / "manifest.json"
    manifest = load_json(manifest_path, errors)
    if not isinstance(manifest, dict):
        return errors or ["manifest.json: expected an object"]

    if manifest.get("rulesetVersion") != RULESET:
        errors.append(f"manifest.rulesetVersion: expected {RULESET}")
    allowed_manifest_fields = {
        "rulesetVersion", "verificationStatus", "files", "sources", "verificationEvidence",
    }
    unexpected_manifest_fields = set(manifest).difference(allowed_manifest_fields)
    if unexpected_manifest_fields:
        errors.append(f"manifest: unexpected fields {sorted(unexpected_manifest_fields)}")

    entries = manifest.get("files")
    if not isinstance(entries, list):
        errors.append("manifest.files: expected an array")
        entries = []
    paths = [entry.get("path") for entry in entries if isinstance(entry, dict)]
    if (
        len(paths) != len(EXPECTED_FILES)
        or not all(isinstance(path, str) for path in paths)
        or set(paths) != EXPECTED_FILES
    ):
        errors.append("manifest.files: expected each canonical data file exactly once")

    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("manifest.files: every entry must be an object")
            continue
        if set(entry) != {"path", "sha256"}:
            errors.append("manifest.files: entries must contain exactly path and sha256")
        relative_path = entry.get("path")
        expected_digest = entry.get("sha256")
        if not isinstance(relative_path, str) or not isinstance(expected_digest, str):
            errors.append("manifest.files: path and sha256 must be strings")
            continue
        if relative_path not in EXPECTED_FILES:
            errors.append(f"manifest.files: unexpected file path {relative_path}")
            continue
        source_path = data_dir / relative_path
        if not source_path.is_file():
            errors.append(f"{relative_path}: file is missing")
            continue
        actual_digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
        if actual_digest != expected_digest:
            errors.append(f"{relative_path}: SHA-256 does not match manifest")

    forbidden = sorted(
        path.relative_to(data_dir).as_posix()
        for path in data_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in FORBIDDEN_SOURCE_SUFFIXES
    )
    if forbidden:
        errors.append(f"official/reference assets cannot be bundled in GameData: {', '.join(forbidden)}")

    if manifest.get("verificationStatus") != "verified":
        errors.append(
            "manifest.verificationStatus: expected verified; data remains a draft and cannot drive gameplay"
        )

    sources = manifest.get("sources")
    if not isinstance(sources, list) or not sources:
        errors.append("manifest.sources: at least one source is required")
    else:
        source_ids = [source.get("id") for source in sources if isinstance(source, dict)]
        if not all(isinstance(source_id, str) for source_id in source_ids) or len(source_ids) != len(set(source_ids)):
            errors.append("manifest.sources: source IDs must be unique")
        all_transcriber_ids = {
            source.get("transcriberID") for source in sources
            if isinstance(source, dict) and isinstance(source.get("transcriberID"), str)
        }
        for index, source in enumerate(sources):
            if not isinstance(source, dict):
                errors.append(f"manifest.sources[{index}]: expected an object")
                continue
            required_source_fields = (
                "id",
                "url",
                "component",
                "version",
                "page",
                "transcriber",
                "transcriberID",
                "transcribedOn",
            )
            allowed_source_fields = set(required_source_fields).union({"checker", "checkerID", "checkedOn"})
            if not set(source).issubset(allowed_source_fields):
                errors.append(f"manifest.sources[{index}]: unexpected fields are not allowed")
            verification_fields = ("checker", "checkerID", "checkedOn")
            fields = required_source_fields + verification_fields
            for field in fields:
                value = source.get(field)
                required_now = field in required_source_fields or manifest.get("verificationStatus") == "verified"
                if required_now and (
                    not isinstance(value, str)
                    or not value.strip()
                    or value.strip().lower() == "pending"
                ):
                    errors.append(f"manifest.sources[{index}].{field}: verified metadata is required")
            transcriber = source.get("transcriber")
            transcriber_id = source.get("transcriberID")
            checker = source.get("checker")
            checker_id = source.get("checkerID")
            if (
                isinstance(transcriber, str) and not valid_identity(transcriber)
                or isinstance(checker, str) and not valid_identity(checker)
            ):
                errors.append(f"manifest.sources[{index}]: identity contains normalization, whitespace or control ambiguity")
            if not isinstance(transcriber_id, str) or not valid_identity_id(transcriber_id):
                errors.append(f"manifest.sources[{index}].transcriberID: stable identity is invalid")
            if not isinstance(source.get("id"), str) or not valid_identity_id(source["id"]):
                errors.append(f"manifest.sources[{index}].id: stable identity is invalid")
            if isinstance(checker_id, str) and checker_id:
                if not valid_identity_id(checker_id):
                    errors.append(f"manifest.sources[{index}].checkerID: stable identity is invalid")
                elif checker_id in all_transcriber_ids:
                    errors.append(
                        f"manifest.sources[{index}]: transcriber and checker must identify different people"
                    )
            transcribed_on = source.get("transcribedOn")
            checked_on = source.get("checkedOn")
            if not isinstance(transcribed_on, str) or not valid_checked_date(transcribed_on):
                errors.append(f"manifest.sources[{index}].transcribedOn: valid non-future ISO date is required")
            if isinstance(checked_on, str) and checked_on:
                if not valid_checked_date(checked_on):
                    errors.append(f"manifest.sources[{index}].checkedOn: valid non-future ISO date is required")
                elif isinstance(transcribed_on, str) and valid_checked_date(transcribed_on):
                    if date.fromisoformat(checked_on) < date.fromisoformat(transcribed_on):
                        errors.append(f"manifest.sources[{index}]: checkedOn cannot precede transcribedOn")

    evidence = manifest.get("verificationEvidence")
    if manifest.get("verificationStatus") == "verified":
        if not isinstance(evidence, dict):
            errors.append("manifest.verificationEvidence: complete checked review evidence is required")
        elif set(evidence) != {"path", "sha256", "rowCount", "baseDataDigest"}:
            errors.append("manifest.verificationEvidence: expected path, sha256, rowCount and baseDataDigest")
        else:
            evidence_path_value = evidence.get("path")
            if (
                not isinstance(evidence_path_value, str)
                or Path(evidence_path_value).name != evidence_path_value
                or not evidence_path_value.endswith(".jsonl")
            ):
                errors.append("manifest.verificationEvidence.path: safe JSONL basename is required")
            else:
                evidence_path = data_dir / evidence_path_value
                if not evidence_path.is_file() or evidence_path.is_symlink():
                    errors.append("manifest.verificationEvidence.path: review artifact is missing or unsafe")
                else:
                    actual_evidence_hash = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
                    if actual_evidence_hash != evidence.get("sha256"):
                        errors.append("manifest.verificationEvidence.sha256: review artifact hash mismatch")
                    try:
                        suggestion = suggest_manifest_metadata(data_dir, evidence_path)
                    except ReviewError as error:
                        errors.append(f"manifest.verificationEvidence: {error}")
                    else:
                        if suggestion["verificationEvidence"] != evidence:
                            errors.append("manifest.verificationEvidence: review binding metadata differs")
                        suggested_sources = {source["id"]: source for source in suggestion["sources"]}
                        for index, source in enumerate(sources if isinstance(sources, list) else []):
                            if not isinstance(source, dict) or source.get("id") not in suggested_sources:
                                continue
                            expected = suggested_sources[source["id"]]
                            for field in ("checker", "checkerID", "checkedOn"):
                                if source.get(field) != expected[field]:
                                    errors.append(
                                        f"manifest.sources[{index}].{field}: does not match checked review"
                                    )
    elif evidence is not None:
        errors.append("manifest.verificationEvidence: draft manifests cannot claim verification evidence")

    board = load_json(data_dir / "map.json", errors)
    industries = load_json(data_dir / "industries.json", errors)
    cards = load_json(data_dir / "cards.json", errors)
    merchants = load_json(data_dir / "merchants.json", errors)
    income_track = load_json(data_dir / "income-track.json", errors)
    if not isinstance(board, dict):
        board = {}
    if not isinstance(industries, list):
        industries = []
    if not isinstance(cards, list):
        cards = []
    if not isinstance(merchants, list):
        merchants = []

    locations = board.get("locations")
    routes = board.get("routes")
    merchant_slots = board.get("merchantSlots")
    if not isinstance(locations, list) or not locations:
        errors.append("map.locations: complete non-empty location data is required")
        locations = []
    if not isinstance(routes, list) or not routes:
        errors.append("map.routes: complete non-empty route data is required")
        routes = []
    if not isinstance(merchant_slots, list) or not merchant_slots:
        errors.append("map.merchantSlots: complete non-empty merchant slot data is required")
        merchant_slots = []

    if len(locations) != 27:
        errors.append("map.locations: expected 27 board locations")
    if len(routes) != 39:
        errors.append("map.routes: expected 39 link routes")
    if len(merchant_slots) != 9:
        errors.append("map.merchantSlots: expected 9 merchant slots")

    for label, items in (
        ("map.locations", locations),
        ("map.routes", routes),
        ("map.merchantSlots", merchant_slots),
        ("industries", industries),
        ("cards", cards),
        ("merchants", merchants),
    ):
        duplicates = duplicate_ids([item for item in items if isinstance(item, dict)])
        if duplicates:
            errors.append(f"{label}: duplicate IDs {sorted(duplicates)}")

    location_ids = {
        item.get("id") for item in locations if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    industry_ids = {
        item.get("id") for item in industries if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    merchant_location_ids = {
        item.get("id")
        for item in locations
        if isinstance(item, dict) and item.get("kind") == "merchant" and isinstance(item.get("id"), str)
    }

    for index, location in enumerate(locations):
        if not isinstance(location, dict) or not valid_player_counts(location.get("playerCounts")):
            errors.append(f"map.locations[{index}].playerCounts: expected a unique subset of 2, 3 and 4")
            continue
        kind = location.get("kind")
        slots = location.get("industrySlots")
        if kind not in {"city", "breweryFarm", "merchant"}:
            errors.append(f"map.locations[{index}].kind: unknown location kind")
        if not isinstance(slots, list):
            errors.append(f"map.locations[{index}].industrySlots: expected an array")
            continue
        if kind == "merchant" and slots:
            errors.append(f"map.locations[{index}].industrySlots: merchant locations cannot contain slots")
        if kind in {"city", "breweryFarm"} and not slots:
            errors.append(f"map.locations[{index}].industrySlots: buildable locations require slots")
        for slot_index, slot in enumerate(slots):
            if (
                not isinstance(slot, list)
                or not slot
                or len(slot) != len(set(slot))
                or any(industry not in industry_ids for industry in slot)
            ):
                errors.append(
                    f"map.locations[{index}].industrySlots[{slot_index}]: missing, duplicate or unknown industry"
                )
        if kind == "breweryFarm" and slots != [["brewery"]]:
            errors.append(f"map.locations[{index}].industrySlots: brewery farm must have one brewery slot")

    for index, route in enumerate(routes):
        if not isinstance(route, dict) or not valid_player_counts(route.get("playerCounts")):
            errors.append(f"map.routes[{index}].playerCounts: expected a unique subset of 2, 3 and 4")
            continue
        endpoints = route.get("endpoints")
        if (
            not isinstance(endpoints, list)
            or len(endpoints) != 2
            or len(set(endpoints)) != 2
            or any(endpoint not in location_ids for endpoint in endpoints)
        ):
            errors.append(f"map.routes[{index}].endpoints: expected two known distinct locations")
        adjacent = route.get("adjacentLocationIDs")
        if (
            not isinstance(adjacent, list)
            or not 2 <= len(adjacent) <= 3
            or len(adjacent) != len(set(adjacent))
            or not isinstance(endpoints, list)
            or not set(endpoints).issubset(set(adjacent))
            or any(location not in location_ids for location in adjacent)
        ):
            errors.append(
                f"map.routes[{index}].adjacentLocationIDs: expected endpoints and at most one brewery farm"
            )
        eras = route.get("eras")
        if (
            not isinstance(eras, list)
            or not eras
            or len(eras) != len(set(eras))
            or not set(eras).issubset({"canal", "rail"})
        ):
            errors.append(f"map.routes[{index}].eras: expected a unique subset of canal and rail")

    for index, slot in enumerate(merchant_slots):
        if not isinstance(slot, dict):
            errors.append(f"map.merchantSlots[{index}]: expected an object")
            continue
        if not valid_player_counts(slot.get("playerCounts")):
            errors.append(f"map.merchantSlots[{index}].playerCounts: expected a unique subset of 2, 3 and 4")
        if slot.get("locationID") not in merchant_location_ids:
            errors.append(f"map.merchantSlots[{index}].locationID: unknown merchant location")
        bonus = slot.get("bonus")
        if (
            not isinstance(bonus, dict)
            or bonus.get("kind") not in {"develop", "income", "money", "victoryPoints"}
            or not isinstance(bonus.get("amount"), int)
            or bonus.get("amount") <= 0
        ):
            errors.append(f"map.merchantSlots[{index}].bonus: invalid merchant bonus")

    industry_counts: dict[str, int] = {}
    for index, industry in enumerate(industries):
        if not isinstance(industry, dict):
            errors.append(f"industries[{index}]: expected an object")
            continue
        levels = industry.get("levels")
        if not isinstance(levels, list) or not levels:
            errors.append(f"industries[{index}].levels: complete non-empty levels are required")
            continue
        copies = [level.get("copiesPerColor") for level in levels if isinstance(level, dict)]
        if len(copies) != len(levels) or any(not isinstance(value, int) or value <= 0 for value in copies):
            errors.append(f"industries[{index}].levels: copiesPerColor must be positive integers")
            continue
        identifier = industry.get("id")
        if isinstance(identifier, str):
            industry_counts[identifier] = sum(copies)
        for level_index, level in enumerate(levels):
            if not isinstance(level, dict):
                continue
            for field in (
                "buildCost",
                "coalCost",
                "ironCost",
                "beerCost",
                "incomeReward",
                "victoryPoints",
                "linkPoints",
            ):
                value = level.get(field)
                if not isinstance(value, int) or value < 0:
                    errors.append(f"industries[{index}].levels[{level_index}].{field}: expected a non-negative integer")
            if not isinstance(level.get("canalEra"), bool) or not isinstance(level.get("railEra"), bool):
                errors.append(f"industries[{index}].levels[{level_index}]: era flags must be booleans")
            if not isinstance(level.get("canDevelop"), bool):
                errors.append(f"industries[{index}].levels[{level_index}].canDevelop: expected a boolean")
            production = level.get("production")
            if production is not None:
                if (
                    not isinstance(production, dict)
                    or production.get("resource") not in {"beer", "coal", "iron"}
                    or not isinstance(production.get("canalCount"), int)
                    or not isinstance(production.get("railCount"), int)
                    or production.get("canalCount") < 0
                    or production.get("railCount") < 0
                ):
                    errors.append(f"industries[{index}].levels[{level_index}].production: invalid production")
    if industry_counts != EXPECTED_INDUSTRIES:
        errors.append("industries: expected the official 45-tile per-colour distribution")

    standard_count = 0
    wild_location_count = 0
    wild_industry_count = 0
    for index, card in enumerate(cards):
        if not isinstance(card, dict):
            errors.append(f"cards[{index}]: expected an object")
            continue
        if not valid_player_counts(card.get("playerCounts")):
            errors.append(f"cards[{index}].playerCounts: expected a unique subset of 2, 3 and 4")
        count = card.get("count")
        if not isinstance(count, int) or count <= 0:
            errors.append(f"cards[{index}].count: expected a positive integer")
            continue
        kind = card.get("kind")
        targets = card.get("targetIDs")
        if kind == "location":
            standard_count += count
            if not isinstance(targets, list) or len(targets) != 1 or targets[0] not in location_ids:
                errors.append(f"cards[{index}].targetIDs: unknown location")
        elif kind == "industry":
            standard_count += count
            if (
                not isinstance(targets, list)
                or not targets
                or len(targets) != len(set(targets))
                or any(target not in industry_ids for target in targets)
            ):
                errors.append(f"cards[{index}].targetIDs: unknown industry")
        elif kind == "wildLocation":
            wild_location_count += count
            if targets != []:
                errors.append(f"cards[{index}].targetIDs: wild cards cannot target a location")
        elif kind == "wildIndustry":
            wild_industry_count += count
            if targets != []:
                errors.append(f"cards[{index}].targetIDs: wild cards cannot target an industry")
        else:
            errors.append(f"cards[{index}].kind: unknown card kind")
    if (standard_count, wild_location_count, wild_industry_count) != (64, 4, 4):
        errors.append("cards: expected 64 standard, 4 wild-location and 4 wild-industry cards")

    merchant_count = 0
    for index, merchant in enumerate(merchants):
        if not isinstance(merchant, dict):
            errors.append(f"merchants[{index}]: expected an object")
            continue
        if not valid_player_counts(merchant.get("playerCounts")):
            errors.append(f"merchants[{index}].playerCounts: expected a unique subset of 2, 3 and 4")
        count = merchant.get("count")
        if isinstance(count, int) and count > 0:
            merchant_count += count
        else:
            errors.append(f"merchants[{index}].count: expected a positive integer")
        accepted = merchant.get("acceptedIndustryIDs")
        if (
            not isinstance(accepted, list)
            or len(accepted) != len(set(accepted))
            or any(industry not in industry_ids for industry in accepted)
        ):
            errors.append(f"merchants[{index}].acceptedIndustryIDs: unknown or duplicate industry")
    if merchant_count != 9:
        errors.append("merchants: expected 9 merchant tiles")

    entries = income_track.get("entries") if isinstance(income_track, dict) else None
    if not isinstance(entries, list) or not entries:
        errors.append("income-track.entries: complete non-empty data is required")
    else:
        def expected_income(position: int) -> int:
            if position <= 10:
                return position - 10
            if position <= 30:
                return (position - 10 + 1) // 2
            if position <= 60:
                return 10 + (position - 30 + 2) // 3
            if position <= 96:
                return 20 + (position - 60 + 3) // 4
            return 30

        expected_entries = [
            {"position": position, "income": expected_income(position)} for position in range(100)
        ]
        if entries != expected_entries:
            errors.append("income-track.entries: expected the complete 100-space official income track")

    return errors


def run_self_test(repo_root: Path) -> int:
    source = repo_root / "IndustrialCityBirmingham" / "GameData" / RULESET
    baseline = validate(source)
    if not any("verificationStatus" in error for error in baseline):
        print("FAIL: draft fixture did not block verificationStatus", file=sys.stderr)
        return 1
    if any("SHA-256" in error for error in baseline):
        print("FAIL: committed draft fixture has a stale manifest hash", file=sys.stderr)
        return 1
    structural = [
        error
        for error in baseline
        if not error.startswith("manifest.verificationStatus:")
        and "verified metadata is required" not in error
    ]
    if structural:
        print(f"FAIL: committed draft has structural errors: {structural}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="industrial-city-game-data-") as temporary:
        fixture = Path(temporary) / RULESET
        shutil.copytree(source, fixture)
        with (fixture / "map.json").open("a", encoding="utf-8") as stream:
            stream.write("\n")
        tampered = validate(fixture)
        if not any("map.json: SHA-256" in error for error in tampered):
            print("FAIL: tampered file was accepted", file=sys.stderr)
            return 1

        (fixture / "reference-map.jpg").write_bytes(b"not-an-app-resource")
        bundled_art = validate(fixture)
        if not any("reference-map.jpg" in error for error in bundled_art):
            print("FAIL: reference artwork was accepted", file=sys.stderr)
            return 1

        (fixture / "income-track.json").write_text(
            '{"entries":[{"position":1,"income":0},{"position":"bad","income":1}]}',
            encoding="utf-8",
        )
        malformed = validate(fixture)
        if not any("income-track.entries" in error for error in malformed):
            print("FAIL: malformed income track was accepted", file=sys.stderr)
            return 1

        manifest_path = fixture / "manifest.json"
        malformed_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        malformed_manifest["files"][0]["path"] = ["map.json"]
        manifest_path.write_text(json.dumps(malformed_manifest), encoding="utf-8")
        malformed_path = validate(fixture)
        if not any("path and sha256 must be strings" in error for error in malformed_path):
            print("FAIL: non-string manifest path was accepted", file=sys.stderr)
            return 1

        traversal_manifest = json.loads(source.joinpath("manifest.json").read_text(encoding="utf-8"))
        traversal_manifest["files"][0]["path"] = "../outside.json"
        manifest_path.write_text(json.dumps(traversal_manifest), encoding="utf-8")
        traversal = validate(fixture)
        if not any("unexpected file path ../outside.json" in error for error in traversal):
            print("FAIL: traversing manifest path was accepted", file=sys.stderr)
            return 1

        self_checked_manifest = json.loads(source.joinpath("manifest.json").read_text(encoding="utf-8"))
        self_checked_manifest["verificationStatus"] = "verified"
        for source_entry in self_checked_manifest["sources"]:
            source_entry["transcriber"] = "Same Person"
            source_entry["transcriberID"] = "same-person"
            source_entry["transcribedOn"] = "2026-08-17"
            source_entry["checker"] = "same person"
            source_entry["checkerID"] = "same-person"
            source_entry["checkedOn"] = "2026-08-17"
        manifest_path.write_text(json.dumps(self_checked_manifest), encoding="utf-8")
        self_checked = validate(fixture)
        if not any("transcriber and checker must identify different people" in error for error in self_checked):
            print("FAIL: self-checked source metadata was accepted", file=sys.stderr)
            return 1

    print("game data verifier self-test passed")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: verify_game_data.py REPO_ROOT [--self-test]", file=sys.stderr)
        return 2
    repo_root = Path(sys.argv[1]).resolve()
    if len(sys.argv) > 2 and sys.argv[2] == "--self-test":
        return run_self_test(repo_root)

    data_dir = repo_root / "IndustrialCityBirmingham" / "GameData" / RULESET
    errors = validate(data_dir)
    errors.extend(validate_bundled_resources(repo_root))
    if errors:
        for error in errors:
            print(f"BLOCKED: {error}", file=sys.stderr)
        return 1
    print(f"game data verified: {RULESET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
