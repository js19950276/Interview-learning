import CryptoKit
import Foundation

extension GameCore {
    nonisolated struct VerifiedGameDataCatalog: Equatable, Sendable {
        // Trust boundary: production instances come from the code-signed app bundle.
        // Manifest hashes, a complete bound review artifact, and independent checker
        // metadata express project approval; they are not a source-signature scheme.
        let catalog: GameDataCatalog

        fileprivate init(catalog: GameDataCatalog) {
            self.catalog = catalog
        }
    }

    nonisolated enum GameDataLoadError: Error, Equatable, Sendable {
        case validationFailed([GameDataValidationIssue])
        case bundledResourceMissing(String)
    }

    nonisolated enum GameDataLoader {
        private static let canonicalPaths = Set([
            "map.json",
            "industries.json",
            "cards.json",
            "merchants.json",
            "income-track.json",
        ])

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        static func validateManifest(
            _ manifest: GameDataManifest,
            files: [String: Data]
        ) -> [GameDataValidationIssue] {
            manifest.files.compactMap { entry in
                guard let data = files[entry.path] else {
                    return GameDataValidationIssue(
                        code: .missingFile,
                        path: entry.path,
                        detail: "File is missing"
                    )
                }
                guard sha256(data) == entry.sha256 else {
                    return GameDataValidationIssue(
                        code: .hashMismatch,
                        path: entry.path,
                        detail: "SHA-256 does not match manifest"
                    )
                }
                return nil
            }
        }

        static func loadVerifiedCatalog(
            manifestData: Data,
            files: [String: Data],
            verificationEvidenceData: Data? = nil
        ) throws -> GameDataCatalog {
            let manifestObject = try StrictJSON.object(from: manifestData)
            let manifest = try JSONDecoder().decode(GameDataManifest.self, from: manifestData)
            var issues = validateManifestShape(manifestObject)
            issues.append(contentsOf: validateManifest(manifest, files: files))
            issues.append(contentsOf: GameDataValidator.validateReadiness(manifest))

            let manifestPaths = manifest.files.map(\.path)
            let manifestPathSet = Set(manifestPaths)
            if manifestPathSet != canonicalPaths {
                for missing in canonicalPaths.subtracting(manifestPathSet).sorted() {
                    issues.append(
                        .init(code: .missingFile, path: missing, detail: "Canonical data file is not listed")
                    )
                }
                for unexpected in manifestPathSet.subtracting(canonicalPaths).sorted() {
                    issues.append(
                        .init(code: .unexpectedFile, path: unexpected, detail: "File is not part of the ruleset")
                    )
                }
            }
            if manifestPaths.count != manifestPathSet.count {
                issues.append(
                    .init(code: .duplicateID, path: "manifest.files", detail: "File paths must be unique")
                )
            }

            guard
                let mapData = files["map.json"],
                let industryData = files["industries.json"],
                let cardData = files["cards.json"],
                let merchantData = files["merchants.json"],
                let incomeTrackData = files["income-track.json"]
            else {
                throw GameDataLoadError.validationFailed(sorted(issues))
            }

            let catalog = try decodeCatalog(
                rulesetVersion: manifest.rulesetVersion,
                mapData: mapData,
                industryData: industryData,
                cardData: cardData,
                merchantData: merchantData,
                incomeTrackData: incomeTrackData
            )
            issues.append(contentsOf: GameDataValidator.validate(catalog))
            if manifest.verificationStatus == .verified {
                if let verificationEvidenceData {
                    issues.append(
                        contentsOf: GameDataReviewVerifier.validate(
                            artifactData: verificationEvidenceData,
                            manifest: manifest,
                            files: files
                        )
                    )
                } else {
                    issues.append(
                        .init(
                            code: .missingFile,
                            path: "manifest.verificationEvidence.path",
                            detail: "Checked review artifact is missing"
                        )
                    )
                }
            }
            guard issues.isEmpty else {
                throw GameDataLoadError.validationFailed(sorted(issues))
            }
            return catalog
        }

        static func loadBundledSetupCatalog() throws -> VerifiedGameDataCatalog {
            let bundle = Bundle.main
            guard let manifestURL = bundle.url(
                forResource: "manifest",
                withExtension: "json"
            ) else {
                throw GameDataLoadError.bundledResourceMissing("manifest.json")
            }
            let manifestData = try Data(contentsOf: manifestURL)
            _ = try StrictJSON.object(from: manifestData)
            let manifest = try JSONDecoder().decode(GameDataManifest.self, from: manifestData)
            let files = try Dictionary(uniqueKeysWithValues: canonicalPaths.sorted().map { path in
                let name = String(path.dropLast(".json".count))
                guard let url = bundle.url(
                    forResource: name,
                    withExtension: "json"
                ) else {
                    throw GameDataLoadError.bundledResourceMissing(path)
                }
                return (path, try Data(contentsOf: url))
            })
            let evidenceData: Data?
            if let evidence = manifest.verificationEvidence {
                guard evidence.path.hasSuffix(".jsonl"),
                    evidence.path == URL(fileURLWithPath: evidence.path).lastPathComponent
                else {
                    throw GameDataLoadError.validationFailed([
                        .init(
                            code: .unexpectedFile,
                            path: "manifest.verificationEvidence.path",
                            detail: "Safe JSONL basename required"
                        ),
                    ])
                }
                let evidenceURL = bundle.url(
                    forResource: String(evidence.path.dropLast(".jsonl".count)),
                    withExtension: "jsonl"
                )
                guard let evidenceURL else {
                    throw GameDataLoadError.bundledResourceMissing(evidence.path)
                }
                evidenceData = try Data(contentsOf: evidenceURL)
            } else {
                evidenceData = nil
            }
            return VerifiedGameDataCatalog(
                catalog: try loadVerifiedCatalog(
                    manifestData: manifestData,
                    files: files,
                    verificationEvidenceData: evidenceData
                )
            )
        }

#if DEBUG
        /// Builds a verified catalog only for deterministic DEBUG fixtures. The bundled
        /// manifest remains draft, so production continues to fail closed until the
        /// independent review metadata is actually checked in.
        static func loadBundledFixtureCatalog() throws -> VerifiedGameDataCatalog {
            let bundle = Bundle.main
            guard let manifestURL = bundle.url(forResource: "manifest", withExtension: "json") else {
                throw GameDataLoadError.bundledResourceMissing("manifest.json")
            }
            var manifest = try JSONDecoder().decode(
                GameDataManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            let files = try Dictionary(uniqueKeysWithValues: canonicalPaths.sorted().map { path in
                let name = String(path.dropLast(".json".count))
                guard let url = bundle.url(forResource: name, withExtension: "json") else {
                    throw GameDataLoadError.bundledResourceMissing(path)
                }
                return (path, try Data(contentsOf: url))
            })
            manifest.verificationStatus = .verified
            manifest.sources = manifest.sources.map { source in
                var fixtureSource = source
                fixtureSource.checker = "DEBUG fixture"
                fixtureSource.checkedOn = "1970-01-01"
                return fixtureSource
            }
            return try loadVerifiedSetupCatalogForTesting(
                manifestData: JSONEncoder().encode(manifest),
                files: files
            )
        }

#endif

#if DEBUG
        static func loadVerifiedSetupCatalogForTesting(
            manifestData: Data,
            files: [String: Data]
        ) throws -> VerifiedGameDataCatalog {
            let manifestObject = try StrictJSON.object(from: manifestData)
            let manifest = try JSONDecoder().decode(GameDataManifest.self, from: manifestData)
            var issues = validateManifestShape(manifestObject)
            issues.append(contentsOf: validateManifest(manifest, files: files))
            issues.append(contentsOf: validateTestingReadiness(manifest))
            let catalog = try decodeCatalog(
                rulesetVersion: manifest.rulesetVersion,
                mapData: files["map.json"] ?? Data(),
                industryData: files["industries.json"] ?? Data(),
                cardData: files["cards.json"] ?? Data(),
                merchantData: files["merchants.json"] ?? Data(),
                incomeTrackData: files["income-track.json"] ?? Data()
            )
            issues.append(contentsOf: GameDataValidator.validate(catalog))
            guard issues.isEmpty else {
                throw GameDataLoadError.validationFailed(sorted(issues))
            }
            return VerifiedGameDataCatalog(catalog: catalog)
        }

        private static func validateTestingReadiness(
            _ manifest: GameDataManifest
        ) -> [GameDataValidationIssue] {
            var issues: [GameDataValidationIssue] = []
            if manifest.verificationStatus != .verified {
                issues.append(
                    .init(
                        code: .incompleteCatalog,
                        path: "manifest.verificationStatus",
                        detail: "DEBUG fixture must explicitly opt into verified status"
                    )
                )
            }
            if manifest.sources.isEmpty {
                issues.append(
                    .init(
                        code: .unverifiedSource,
                        path: "manifest.sources",
                        detail: "DEBUG fixture requires source metadata"
                    )
                )
            }
            for (index, source) in manifest.sources.enumerated() {
                let transcriber = source.transcriber.trimmingCharacters(in: .whitespacesAndNewlines)
                let checker = (source.checker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if transcriber.isEmpty || checker.isEmpty || source.checkedOn?.isEmpty != false {
                    issues.append(
                        .init(
                            code: .unverifiedSource,
                            path: "manifest.sources[\(index)]",
                            detail: "DEBUG fixture requires explicit transcriber/checker metadata"
                        )
                    )
                } else if transcriber.caseInsensitiveCompare(checker) == .orderedSame {
                    issues.append(
                        .init(
                            code: .unverifiedSource,
                            path: "manifest.sources[\(index)]",
                            detail: "DEBUG transcriber and checker must differ"
                        )
                    )
                }
            }
            return issues
        }
#endif

        static func decodeCatalog(
            rulesetVersion: String,
            mapData: Data,
            industryData: Data,
            cardData: Data,
            merchantData: Data,
            incomeTrackData: Data
        ) throws -> GameDataCatalog {
            _ = try StrictJSON.object(from: mapData)
            _ = try StrictJSON.object(from: industryData)
            _ = try StrictJSON.object(from: cardData)
            _ = try StrictJSON.object(from: merchantData)
            _ = try StrictJSON.object(from: incomeTrackData)
            let decoder = JSONDecoder()
            return try GameDataCatalog(
                rulesetVersion: rulesetVersion,
                board: decoder.decode(BoardDefinition.self, from: mapData),
                industries: decoder.decode([IndustryDefinition].self, from: industryData),
                cards: decoder.decode([CardDefinition].self, from: cardData),
                merchants: decoder.decode([MerchantDefinition].self, from: merchantData),
                incomeTrack: decoder.decode(IncomeTrack.self, from: incomeTrackData)
            )
        }

        private static func sorted(
            _ issues: [GameDataValidationIssue]
        ) -> [GameDataValidationIssue] {
            issues.sorted { lhs, rhs in
                (lhs.path, lhs.code.rawValue, lhs.detail) < (rhs.path, rhs.code.rawValue, rhs.detail)
            }
        }

        private static func validateManifestShape(_ value: Any) -> [GameDataValidationIssue] {
            guard let object = value as? [String: Any] else {
                return [.init(code: .unexpectedFile, path: "manifest", detail: "Manifest must be an object")]
            }
            let allowed = Set(["rulesetVersion", "verificationStatus", "files", "sources", "verificationEvidence"])
            var issues: [GameDataValidationIssue] = []
            if Set(object.keys).isSubset(of: allowed) == false {
                issues.append(.init(code: .unexpectedFile, path: "manifest", detail: "Manifest has unknown fields"))
            }
            if let files = object["files"] as? [[String: Any]], files.contains(where: {
                Set($0.keys) != Set(["path", "sha256"])
            }) {
                issues.append(.init(code: .unexpectedFile, path: "manifest.files", detail: "File digest has unknown fields"))
            }
            let sourceFields = Set([
                "id", "url", "component", "version", "page", "transcriber", "transcriberID",
                "transcribedOn", "checker", "checkerID", "checkedOn",
            ])
            if let sources = object["sources"] as? [[String: Any]], sources.contains(where: {
                Set($0.keys).isSubset(of: sourceFields) == false
            }) {
                issues.append(.init(code: .unexpectedFile, path: "manifest.sources", detail: "Source has unknown fields"))
            }
            if let evidence = object["verificationEvidence"] as? [String: Any],
                Set(evidence.keys) != Set(["path", "sha256", "rowCount", "baseDataDigest"])
            {
                issues.append(.init(code: .unexpectedFile, path: "manifest.verificationEvidence", detail: "Evidence fields differ"))
            }
            return issues
        }
    }
}
