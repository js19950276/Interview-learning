#!/usr/bin/env python3
"""Export and validate a human-auditable review of canonical game data.

The JSON Lines artifact contains one immutable header followed by one line per
reviewable datum. Humans edit only checker, checkerID, checkedOn, status and
notes. This tool never edits manifest.json.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import sys
import tempfile
import unicodedata
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


RULESET = "v2018.11"
CANONICAL_FILES = (
    "map.json",
    "industries.json",
    "cards.json",
    "merchants.json",
    "income-track.json",
)
SCHEMA_VERSION = 1
EDITABLE_ROW_FIELDS = {"checker", "checkerID", "checkedOn", "status", "notes"}
HEADER_FIELDS = {
    "artifactType", "schemaVersion", "rulesetVersion", "baseDataDigest", "fileHashes",
    "coverage", "sourceCatalog", "rowCount",
}
ROW_FIELDS = {
    "recordType", "area", "locator", "sourceFile", "jsonPointer", "canonicalJSON",
    "rowSha256", "sourceRefs", "transcriberIDs", "checker", "checkerID", "checkedOn",
    "status", "notes",
}
SOURCE_REFS = {
    "map.locations": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "brassrl-457519c",
        "npow-brass-birmingham-2b1da2d",
    ),
    "map.routes": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "brassrl-457519c",
        "npow-brass-birmingham-2b1da2d",
    ),
    "map.merchantSlots": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "brassrl-457519c",
        "npow-brass-birmingham-2b1da2d",
    ),
    "industries.levels": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "brassrl-457519c",
        "npow-brass-birmingham-2b1da2d",
    ),
    "cards": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "npow-brass-birmingham-2b1da2d",
    ),
    "merchants": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
        "brassrl-457519c",
        "npow-brass-birmingham-2b1da2d",
    ),
    "income-track.entries": (
        "roxley-rulebook-v2018.11",
        "bge-brass-birmingham-d11d438",
    ),
}


class ReviewError(ValueError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: Path) -> Any:
    return strict_loads(path.read_text(encoding="utf-8"), path.name)


def strict_loads(value: str, label: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ReviewError(f"{label}: duplicate key {key}")
            result[key] = item
        return result

    def reject_constant(constant: str) -> None:
        raise ReviewError(f"{label}: non-finite number {constant}")

    try:
        return json.loads(
            value,
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except json.JSONDecodeError as error:
        raise ReviewError(f"{label}: invalid JSON: {error}") from error


def valid_identity(value: str) -> bool:
    if not value or value != value.strip() or unicodedata.normalize("NFKC", value) != value:
        return False
    return not any(unicodedata.category(character).startswith("C") for character in value)


def valid_identity_id(value: str) -> bool:
    return valid_identity(value) and all(
        character.isascii() and (character.islower() or character.isdigit() or character in "._- ")
        for character in value
    ) and " " not in value


def valid_checked_date(value: str, *, today: date | None = None) -> bool:
    try:
        parsed = date.fromisoformat(value)
        utc_today = today if today is not None else datetime.now(timezone.utc).date()
        return parsed.isoformat() == value and parsed <= utc_today
    except ValueError:
        return False


def source_catalog(manifest: dict[str, Any]) -> list[dict[str, str]]:
    fields = (
        "id", "url", "component", "version", "page", "transcriber", "transcriberID",
        "transcribedOn",
    )
    catalog: list[dict[str, str]] = []
    sources = manifest.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ReviewError("manifest sources are missing")
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ReviewError(f"manifest source {index} is not an object")
        entry: dict[str, str] = {}
        for field in fields:
            value = source.get(field)
            if not isinstance(value, str) or not value.strip():
                raise ReviewError(f"manifest source {index} has incomplete {field}")
            entry[field] = value
        if not valid_identity_id(entry["id"]):
            raise ReviewError(f"manifest source {index} has invalid id")
        if not valid_identity_id(entry["transcriberID"]):
            raise ReviewError(f"manifest source {index} has invalid transcriberID")
        for field in ("url", "component", "version", "page", "transcriber"):
            if not valid_identity(entry[field]):
                raise ReviewError(f"manifest source {index} has ambiguous {field}")
        if not valid_checked_date(entry["transcribedOn"]):
            raise ReviewError(f"manifest source {index} has invalid transcribedOn")
        catalog.append(entry)
    source_ids = [source["id"] for source in catalog]
    if len(source_ids) != len(set(source_ids)):
        raise ReviewError("manifest source IDs must be unique")
    return catalog


def base_data_digest(manifest: dict[str, Any], catalog: list[dict[str, str]]) -> str:
    basis = {
        "rulesetVersion": manifest.get("rulesetVersion"),
        "files": manifest.get("files"),
        "sources": catalog,
    }
    return sha256_bytes(canonical_bytes(basis))


def make_row(
    *,
    area: str,
    locator: str,
    source_file: str,
    pointer: str,
    value: Any,
    transcriber_ids: list[str],
) -> dict[str, Any]:
    return {
        "recordType": "reviewRow",
        "area": area,
        "locator": locator,
        "sourceFile": source_file,
        "jsonPointer": pointer,
        "canonicalJSON": value,
        "rowSha256": sha256_bytes(canonical_bytes(value)),
        "sourceRefs": list(SOURCE_REFS[area]),
        "transcriberIDs": transcriber_ids,
        "checker": "",
        "checkerID": "",
        "checkedOn": "",
        "status": "pending",
        "notes": "",
    }


def build_review(data_dir: Path) -> dict[str, Any]:
    manifest_path = data_dir / "manifest.json"
    manifest = load_json(manifest_path)
    catalog = source_catalog(manifest)
    catalog_ids = {source["id"] for source in catalog}
    referenced_ids = {source_id for refs in SOURCE_REFS.values() for source_id in refs}
    if catalog_ids != referenced_ids:
        raise ReviewError("source provenance must exactly cover every review source reference")
    transcriber_ids = sorted({source["transcriberID"] for source in catalog})
    actual_hashes = {
        name: sha256_bytes((data_dir / name).read_bytes()) for name in CANONICAL_FILES
    }
    declared_hashes = {
        item.get("path"): item.get("sha256")
        for item in manifest.get("files", [])
        if isinstance(item, dict)
    }
    if declared_hashes != actual_hashes:
        raise ReviewError("manifest file hashes do not match canonical files")

    board = load_json(data_dir / "map.json")
    industries = load_json(data_dir / "industries.json")
    cards = load_json(data_dir / "cards.json")
    merchants = load_json(data_dir / "merchants.json")
    income = load_json(data_dir / "income-track.json")
    rows: list[dict[str, Any]] = []

    for area, key in (
        ("map.locations", "locations"),
        ("map.routes", "routes"),
        ("map.merchantSlots", "merchantSlots"),
    ):
        for index, value in enumerate(board[key]):
            rows.append(
                make_row(
                    area=area,
                    locator=f"{area}/{value['id']}",
                    source_file="map.json",
                    pointer=f"/{key}/{index}",
                    value=value,
                    transcriber_ids=transcriber_ids,
                )
            )

    for industry_index, industry in enumerate(industries):
        for level_index, level in enumerate(industry["levels"]):
            rows.append(
                make_row(
                    area="industries.levels",
                    locator=f"industries.levels/{industry['id']}/{level['level']}",
                    source_file="industries.json",
                    pointer=f"/{industry_index}/levels/{level_index}",
                    value=level,
                    transcriber_ids=transcriber_ids,
                )
            )

    for area, filename, values in (
        ("cards", "cards.json", cards),
        ("merchants", "merchants.json", merchants),
    ):
        for index, value in enumerate(values):
            rows.append(
                make_row(
                    area=area,
                    locator=f"{area}/{value['id']}",
                    source_file=filename,
                    pointer=f"/{index}",
                    value=value,
                    transcriber_ids=transcriber_ids,
                )
            )

    for index, value in enumerate(income["entries"]):
        rows.append(
            make_row(
                area="income-track.entries",
                locator=f"income-track.entries/{value['position']}",
                source_file="income-track.json",
                pointer=f"/entries/{index}",
                value=value,
                transcriber_ids=transcriber_ids,
            )
        )

    return {
        "artifactType": "industrial-city-game-data-review",
        "schemaVersion": SCHEMA_VERSION,
        "rulesetVersion": RULESET,
        "baseDataDigest": base_data_digest(manifest, catalog),
        "fileHashes": actual_hashes,
        "coverage": {area: sum(row["area"] == area for row in rows) for area in SOURCE_REFS},
        "sourceCatalog": catalog,
        "rowCount": len(rows),
        "rows": rows,
    }


def write_review(document: dict[str, Any], path: Path) -> None:
    path = Path(os.path.abspath(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        raise ReviewError(f"review target already exists: {path}")
    header = {key: value for key, value in document.items() if key != "rows"}
    lines = [canonical_bytes(header).decode("utf-8")]
    lines.extend(canonical_bytes(row).decode("utf-8") for row in document["rows"])
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary_path, path)
        except OSError as error:
            if error.errno == errno.EEXIST:
                raise ReviewError(f"review target already exists: {path}") from error
            raise
    finally:
        temporary_path.unlink(missing_ok=True)


def read_review(path: Path) -> dict[str, Any]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        raise ReviewError("review artifact is empty")
    try:
        header = strict_loads(lines[0], "review header")
        rows = [strict_loads(line, f"review row {index}") for index, line in enumerate(lines[1:])]
    except ReviewError:
        raise
    if not isinstance(header, dict) or any(not isinstance(row, dict) for row in rows):
        raise ReviewError("review header and rows must be objects")
    if set(header) != HEADER_FIELDS:
        raise ReviewError("review header must contain exactly the allowed keys")
    if canonical_bytes(header).decode("utf-8") != lines[0]:
        raise ReviewError("review header must use canonical JSON serialization")
    for index, (line, row) in enumerate(zip(lines[1:], rows)):
        if set(row) != ROW_FIELDS:
            raise ReviewError(f"review row {index} must contain exactly the allowed keys")
        if canonical_bytes(row).decode("utf-8") != line:
            raise ReviewError(f"review row {index} must use canonical JSON serialization")
    return {**header, "rows": rows}


def validate_review(data_dir: Path, review_path: Path) -> list[str]:
    try:
        actual = read_review(review_path)
        expected = build_review(data_dir)
    except (OSError, KeyError, TypeError, json.JSONDecodeError, ReviewError) as error:
        return [str(error)]

    errors: list[str] = []
    actual_rows = actual.get("rows")
    if not isinstance(actual_rows, list):
        return ["review rows are missing"]
    locators = [row.get("locator") for row in actual_rows if isinstance(row, dict)]
    if len(locators) != len(set(locators)):
        errors.append("duplicate locator in review")
    expected_locators = [row["locator"] for row in expected["rows"]]
    if locators != expected_locators:
        errors.append("review coverage differs from canonical data")

    if actual.get("baseDataDigest") != expected["baseDataDigest"]:
        errors.append("base data digest differs from current manifest and files")
    if actual.get("fileHashes") != expected["fileHashes"]:
        errors.append("file hash binding differs from canonical data")

    expected_header = {key: value for key, value in expected.items() if key not in {"rows", "baseDataDigest", "fileHashes"}}
    actual_header = {key: value for key, value in actual.items() if key not in {"rows", "baseDataDigest", "fileHashes"}}
    if actual_header != expected_header:
        errors.append("immutable review header differs")

    expected_by_locator = {row["locator"]: row for row in expected["rows"]}
    transcriber_ids = {source["transcriberID"] for source in expected["sourceCatalog"]}
    latest_transcribed_on = max(date.fromisoformat(source["transcribedOn"]) for source in expected["sourceCatalog"])
    for index, row in enumerate(actual_rows):
        if not isinstance(row, dict):
            errors.append(f"row {index} is not an object")
            continue
        locator = row.get("locator")
        if set(row) != ROW_FIELDS:
            errors.append(f"row {index}: allowed keys differ")
        baseline = expected_by_locator.get(locator)
        if baseline is None:
            continue
        immutable = {key: value for key, value in row.items() if key not in EDITABLE_ROW_FIELDS}
        expected_immutable = {
            key: value for key, value in baseline.items() if key not in EDITABLE_ROW_FIELDS
        }
        if immutable != expected_immutable:
            errors.append(f"{locator}: immutable row content differs")
        if row.get("status") not in {"pending", "checked"}:
            errors.append(f"{locator}: status must be pending or checked")
        for field in ("checker", "checkerID", "checkedOn", "notes"):
            if not isinstance(row.get(field), str):
                errors.append(f"{locator}: {field} must be a string")
        if row.get("status") == "checked":
            checker = row.get("checker", "")
            checker_id = row.get("checkerID", "")
            checked_on = row.get("checkedOn", "")
            if isinstance(checker, str) and not checker.strip():
                errors.append(f"{locator}: checked row requires checker")
            elif isinstance(checker, str) and not valid_identity(checker):
                errors.append(f"{locator}: checker identity contains normalization, whitespace or control ambiguity")
            if not isinstance(checker_id, str) or not valid_identity_id(checker_id):
                errors.append(f"{locator}: checkerID is invalid")
            elif checker_id in transcriber_ids:
                errors.append(f"{locator}: checker must differ from every transcriber")
            if isinstance(checked_on, str) and not valid_checked_date(checked_on):
                errors.append(f"{locator}: checkedOn must be a valid YYYY-MM-DD date")
            elif isinstance(checked_on, str) and date.fromisoformat(checked_on) < latest_transcribed_on:
                errors.append(f"{locator}: checkedOn cannot precede transcribedOn")
    return errors


def suggest_manifest_metadata(data_dir: Path, review_path: Path) -> dict[str, Any]:
    errors = validate_review(data_dir, review_path)
    if errors:
        raise ReviewError("; ".join(errors))
    document = read_review(review_path)
    rows = document["rows"]
    if any(row["status"] != "checked" for row in rows):
        raise ReviewError("all rows must be checked before metadata can be suggested")
    if any(not row["checker"].strip() or not row["checkedOn"].strip() for row in rows):
        raise ReviewError("all checked rows require checker and checkedOn")
    if any(not valid_checked_date(row["checkedOn"]) for row in rows):
        raise ReviewError("checkedOn must be a valid YYYY-MM-DD date")

    checkers = {row["checker"].strip() for row in rows}
    checker_ids = {row["checkerID"] for row in rows}
    checked_dates = {row["checkedOn"].strip() for row in rows}
    if len(checkers) != 1 or len(checker_ids) != 1 or len(checked_dates) != 1:
        raise ReviewError("all rows must use one checker, checkerID and checkedOn date")
    checker = next(iter(checkers))
    checker_id = next(iter(checker_ids))
    checked_on = next(iter(checked_dates))
    transcriber_ids = {source["transcriberID"] for source in document["sourceCatalog"]}
    if checker_id in transcriber_ids:
        raise ReviewError("checker must differ from every transcriber")

    evidence = {
        "path": review_path.name,
        "sha256": sha256_bytes(review_path.read_bytes()),
        "rowCount": len(rows),
        "baseDataDigest": document["baseDataDigest"],
    }
    return {
        "advisoryOnly": True,
        "rulesetVersion": RULESET,
        "baseDataDigest": document["baseDataDigest"],
        "reviewArtifactSha256": sha256_bytes(review_path.read_bytes()),
        "reviewRowCount": len(rows),
        "verificationStatus": "verified",
        "sources": [
            {
                "id": source["id"], "checker": checker, "checkerID": checker_id,
                "checkedOn": checked_on,
            }
            for source in document["sourceCatalog"]
        ],
        "verificationEvidence": evidence,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo_root", type=Path)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--export", type=Path)
    group.add_argument("--check", type=Path)
    group.add_argument("--suggest-metadata", type=Path)
    arguments = parser.parse_args()
    data_dir = arguments.repo_root.resolve() / "IndustrialCityBirmingham" / "GameData" / RULESET
    try:
        if arguments.export:
            write_review(build_review(data_dir), arguments.export)
            print(f"game data review exported: {arguments.export}")
            return 0
        if arguments.check:
            errors = validate_review(data_dir, arguments.check)
            if errors:
                for error in errors:
                    print(f"BLOCKED: {error}", file=sys.stderr)
                return 1
            print(f"game data review valid: {arguments.check}")
            return 0
        suggestion = suggest_manifest_metadata(data_dir, arguments.suggest_metadata)
        print(json.dumps(suggestion, ensure_ascii=False, sort_keys=True, indent=2))
        return 0
    except (OSError, KeyError, TypeError, json.JSONDecodeError, ReviewError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
