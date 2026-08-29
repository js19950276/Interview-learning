import Foundation

extension GameCore {
    nonisolated enum GameDataReviewVerifier {
        private static let headerKeys = Set([
            "artifactType", "schemaVersion", "rulesetVersion", "baseDataDigest", "fileHashes",
            "coverage", "sourceCatalog", "rowCount",
        ])
        private static let rowKeys = Set([
            "recordType", "area", "locator", "sourceFile", "jsonPointer", "canonicalJSON",
            "rowSha256", "sourceRefs", "transcriberIDs", "checker", "checkerID", "checkedOn",
            "status", "notes",
        ])
        private static let editableRowKeys = Set(["checker", "checkerID", "checkedOn", "status", "notes"])
        private static let sourceReferences: [String: [String]] = [
            "map.locations": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "brassrl-457519c", "npow-brass-birmingham-2b1da2d",
            ],
            "map.routes": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "brassrl-457519c", "npow-brass-birmingham-2b1da2d",
            ],
            "map.merchantSlots": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "brassrl-457519c", "npow-brass-birmingham-2b1da2d",
            ],
            "industries.levels": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "brassrl-457519c", "npow-brass-birmingham-2b1da2d",
            ],
            "cards": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "npow-brass-birmingham-2b1da2d",
            ],
            "merchants": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
                "brassrl-457519c", "npow-brass-birmingham-2b1da2d",
            ],
            "income-track.entries": [
                "roxley-rulebook-v2018.11", "bge-brass-birmingham-d11d438",
            ],
        ]

        static func validate(
            artifactData: Data,
            manifest: GameDataManifest,
            files: [String: Data]
        ) -> [GameDataValidationIssue] {
            do {
                guard let evidence = manifest.verificationEvidence else {
                    return [issue(.incompleteCatalog, "manifest.verificationEvidence", "Evidence is missing")]
                }
                var issues: [GameDataValidationIssue] = []
                if evidence.path != URL(fileURLWithPath: evidence.path).lastPathComponent
                    || evidence.path.hasSuffix(".jsonl") == false
                {
                    issues.append(issue(.unexpectedFile, "manifest.verificationEvidence.path", "Safe JSONL basename required"))
                }
                if GameDataLoader.sha256(artifactData) != evidence.sha256 {
                    issues.append(issue(.hashMismatch, evidence.path, "Review artifact SHA-256 mismatch"))
                }

                let expected = try expectedDocument(manifest: manifest, files: files)
                if evidence.rowCount != expected.rows.count || evidence.rowCount != 243 {
                    issues.append(issue(.invalidComponentCount, "manifest.verificationEvidence.rowCount", "Expected 243 rows"))
                }
                if evidence.baseDataDigest != expected.baseDataDigest {
                    issues.append(issue(.hashMismatch, "manifest.verificationEvidence.baseDataDigest", "Base data digest differs"))
                }

                let lines = try parseCanonicalLines(artifactData)
                guard lines.count == expected.rows.count + 1 else {
                    issues.append(issue(.invalidComponentCount, evidence.path, "Expected one header and 243 review rows"))
                    return issues
                }
                guard let header = lines[0] as? [String: Any], Set(header.keys) == headerKeys else {
                    issues.append(issue(.unexpectedFile, "review.header", "Header fields differ"))
                    return issues
                }
                if try StrictJSON.canonicalData(header) != StrictJSON.canonicalData(expected.header) {
                    issues.append(issue(.hashMismatch, "review.header", "Header does not bind current data"))
                }

                let checkerIDs = Set(manifest.sources.compactMap(\.checkerID))
                let checkers = Set(manifest.sources.compactMap(\.checker))
                let checkedDates = Set(manifest.sources.compactMap(\.checkedOn))
                guard checkerIDs.count == 1, checkers.count == 1, checkedDates.count == 1,
                    let checkerID = checkerIDs.first,
                    let checker = checkers.first,
                    let checkedOn = checkedDates.first
                else {
                    issues.append(issue(.unverifiedSource, "manifest.sources", "Review requires one checker identity and date"))
                    return issues
                }

                for (index, expectedRow) in expected.rows.enumerated() {
                    guard let row = lines[index + 1] as? [String: Any], Set(row.keys) == rowKeys else {
                        issues.append(issue(.unexpectedFile, "review.rows[\(index)]", "Row fields differ"))
                        continue
                    }
                    let immutable = row.filter { editableRowKeys.contains($0.key) == false }
                    let expectedImmutable = expectedRow.filter { editableRowKeys.contains($0.key) == false }
                    if try StrictJSON.canonicalData(immutable) != StrictJSON.canonicalData(expectedImmutable) {
                        issues.append(issue(.hashMismatch, "review.rows[\(index)]", "Immutable row differs from current data"))
                    }
                    if row["status"] as? String != "checked"
                        || row["checker"] as? String != checker
                        || row["checkerID"] as? String != checkerID
                        || row["checkedOn"] as? String != checkedOn
                    {
                        issues.append(issue(.unverifiedSource, "review.rows[\(index)]", "Row is not signed by manifest checker"))
                    }
                    if row["notes"] is String == false {
                        issues.append(issue(.unexpectedFile, "review.rows[\(index)].notes", "notes must be a string"))
                    }
                }
                return issues
            } catch {
                return [issue(.unexpectedFile, "manifest.verificationEvidence", "Invalid review artifact: \(error)")]
            }
        }

#if DEBUG
        static func makePendingArtifactForTesting(
            manifest: GameDataManifest,
            files: [String: Data]
        ) throws -> Data {
            let expected = try expectedDocument(manifest: manifest, files: files)
            var lines = [try StrictJSON.canonicalData(expected.header)]
            lines.append(contentsOf: try expected.rows.map(StrictJSON.canonicalData))
            var result = Data()
            for line in lines {
                result.append(line)
                result.append(0x0A)
            }
            return result
        }
#endif

        private struct ExpectedDocument {
            let header: [String: Any]
            let rows: [[String: Any]]
            let baseDataDigest: String
        }

        private static func expectedDocument(
            manifest: GameDataManifest,
            files: [String: Data]
        ) throws -> ExpectedDocument {
            let referencedSourceIDs = Set(sourceReferences.values.flatMap { $0 })
            let manifestSourceIDs = Set(manifest.sources.map(\.id))
            guard manifestSourceIDs == referencedSourceIDs else {
                throw StrictJSON.ValidationError(
                    detail: "Manifest source IDs must exactly cover every review source reference"
                )
            }
            let sourceCatalog = manifest.sources.map { source in
                [
                    "id": source.id,
                    "url": source.url,
                    "component": source.component,
                    "version": source.version,
                    "page": source.page,
                    "transcriber": source.transcriber,
                    "transcriberID": source.transcriberID,
                    "transcribedOn": source.transcribedOn,
                ]
            }
            let fileEntries: [[String: String]] = manifest.files.map {
                ["path": $0.path, "sha256": $0.sha256]
            }
            let basis: [String: Any] = [
                "rulesetVersion": manifest.rulesetVersion,
                "files": fileEntries,
                "sources": sourceCatalog,
            ]
            let baseDataDigest = GameDataLoader.sha256(try StrictJSON.canonicalData(basis))
            let transcriberIDs = Array(Set(manifest.sources.map(\.transcriberID))).sorted()
            var rows: [[String: Any]] = []

            guard let map = try object(files, "map.json") as? [String: Any],
                let industries = try object(files, "industries.json") as? [[String: Any]],
                let cards = try object(files, "cards.json") as? [[String: Any]],
                let merchants = try object(files, "merchants.json") as? [[String: Any]],
                let income = try object(files, "income-track.json") as? [String: Any]
            else {
                throw StrictJSON.ValidationError(detail: "Canonical files have unexpected root types")
            }

            for (area, key) in [
                ("map.locations", "locations"),
                ("map.routes", "routes"),
                ("map.merchantSlots", "merchantSlots"),
            ] {
                guard let values = map[key] as? [[String: Any]] else {
                    throw StrictJSON.ValidationError(detail: "Missing \(key)")
                }
                for (index, value) in values.enumerated() {
                    guard let identifier = value["id"] as? String else {
                        throw StrictJSON.ValidationError(detail: "Missing row ID")
                    }
                    rows.append(try row(
                        area: area,
                        locator: "\(area)/\(identifier)",
                        sourceFile: "map.json",
                        pointer: "/\(key)/\(index)",
                        value: value,
                        transcriberIDs: transcriberIDs
                    ))
                }
            }

            for (industryIndex, industry) in industries.enumerated() {
                guard let identifier = industry["id"] as? String,
                    let levels = industry["levels"] as? [[String: Any]]
                else {
                    throw StrictJSON.ValidationError(detail: "Invalid industry rows")
                }
                for (levelIndex, level) in levels.enumerated() {
                    guard let levelNumber = level["level"] as? NSNumber else {
                        throw StrictJSON.ValidationError(detail: "Invalid industry level")
                    }
                    rows.append(try row(
                        area: "industries.levels",
                        locator: "industries.levels/\(identifier)/\(levelNumber.intValue)",
                        sourceFile: "industries.json",
                        pointer: "/\(industryIndex)/levels/\(levelIndex)",
                        value: level,
                        transcriberIDs: transcriberIDs
                    ))
                }
            }

            for (area, filename, values) in [
                ("cards", "cards.json", cards),
                ("merchants", "merchants.json", merchants),
            ] {
                for (index, value) in values.enumerated() {
                    guard let identifier = value["id"] as? String else {
                        throw StrictJSON.ValidationError(detail: "Missing row ID")
                    }
                    rows.append(try row(
                        area: area,
                        locator: "\(area)/\(identifier)",
                        sourceFile: filename,
                        pointer: "/\(index)",
                        value: value,
                        transcriberIDs: transcriberIDs
                    ))
                }
            }

            guard let entries = income["entries"] as? [[String: Any]] else {
                throw StrictJSON.ValidationError(detail: "Missing income entries")
            }
            for (index, value) in entries.enumerated() {
                guard let position = value["position"] as? NSNumber else {
                    throw StrictJSON.ValidationError(detail: "Invalid income position")
                }
                rows.append(try row(
                    area: "income-track.entries",
                    locator: "income-track.entries/\(position.intValue)",
                    sourceFile: "income-track.json",
                    pointer: "/entries/\(index)",
                    value: value,
                    transcriberIDs: transcriberIDs
                ))
            }

            let fileHashes = Dictionary(uniqueKeysWithValues: files.map {
                ($0.key, GameDataLoader.sha256($0.value))
            })
            let coverage = Dictionary(uniqueKeysWithValues: sourceReferences.keys.map { area in
                (area, rows.count { $0["area"] as? String == area })
            })
            let header: [String: Any] = [
                "artifactType": "industrial-city-game-data-review",
                "schemaVersion": 1,
                "rulesetVersion": manifest.rulesetVersion,
                "baseDataDigest": baseDataDigest,
                "fileHashes": fileHashes,
                "coverage": coverage,
                "sourceCatalog": sourceCatalog,
                "rowCount": rows.count,
            ]
            return ExpectedDocument(header: header, rows: rows, baseDataDigest: baseDataDigest)
        }

        private static func object(_ files: [String: Data], _ path: String) throws -> Any {
            guard let data = files[path] else {
                throw StrictJSON.ValidationError(detail: "Missing \(path)")
            }
            return try StrictJSON.object(from: data)
        }

        private static func row(
            area: String,
            locator: String,
            sourceFile: String,
            pointer: String,
            value: Any,
            transcriberIDs: [String]
        ) throws -> [String: Any] {
            [
                "recordType": "reviewRow",
                "area": area,
                "locator": locator,
                "sourceFile": sourceFile,
                "jsonPointer": pointer,
                "canonicalJSON": value,
                "rowSha256": GameDataLoader.sha256(try StrictJSON.canonicalData(value)),
                "sourceRefs": sourceReferences[area] ?? [],
                "transcriberIDs": transcriberIDs,
                "checker": "",
                "checkerID": "",
                "checkedOn": "",
                "status": "pending",
                "notes": "",
            ]
        }

        private static func parseCanonicalLines(_ data: Data) throws -> [Any] {
            guard data.last == 0x0A, let text = String(data: data, encoding: .utf8) else {
                throw StrictJSON.ValidationError(detail: "Review must be UTF-8 JSONL ending in newline")
            }
            let lineStrings = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            return try lineStrings.enumerated().map { index, line in
                let lineData = Data(line.utf8)
                let value = try StrictJSON.object(from: lineData)
                guard try StrictJSON.canonicalData(value) == lineData else {
                    throw StrictJSON.ValidationError(detail: "Review line \(index) is not canonical JSON")
                }
                return value
            }
        }

        private static func issue(
            _ code: GameDataValidationIssue.Code,
            _ path: String,
            _ detail: String
        ) -> GameDataValidationIssue {
            .init(code: code, path: path, detail: detail)
        }
    }
}
