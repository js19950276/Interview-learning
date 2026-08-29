import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct GameDataTests {
#if DEBUG
    @Test func bundledDebugFixtureCatalogPromotesOnlyTheLocalTestCopy() throws {
        let catalog = try GameCore.GameDataLoader.loadBundledFixtureCatalog()

        #expect(catalog.catalog.rulesetVersion == "v2018.11")
        #expect(catalog.catalog.board.locations.count == 27)
    }
#endif
    @Test func rulesDataModelsPreserveBoardAndComponentSemantics() {
        let route = GameCore.BoardDefinition.Route(
            id: "route-a-b",
            endpoints: ["location-a", "location-b"],
            adjacentLocationIDs: ["location-a", "farm", "location-b"],
            eras: [.canal, .rail],
            playerCounts: [2, 3, 4]
        )
        let card = GameCore.CardDefinition(
            id: "dual-industry",
            kind: .industry,
            targetIDs: ["cotton-mill", "manufacturer"],
            count: 1,
            playerCounts: [3, 4]
        )
        let production = GameCore.IndustryDefinition.ResourceProduction(
            resource: .beer,
            canalCount: 1,
            railCount: 2
        )

        #expect(route.adjacentLocationIDs.count == 3)
        #expect(route.eras == [.canal, .rail])
        #expect(card.targetIDs == ["cotton-mill", "manufacturer"])
        #expect(production.railCount == 2)
    }

    @Test func completeCatalogPassesTheRulesetBaseline() {
        let issues = GameCore.GameDataValidator.validate(completeCatalog())

        #expect(issues.isEmpty)
    }

    @Test func validatorReportsStableStructuralAndCompletenessErrors() {
        var catalog = completeCatalog()
        catalog.board.locations.append(catalog.board.locations[0])
        catalog.board.routes[0].endpoints = ["location-a", "missing-location"]
        catalog.board.routes[0].playerCounts = [1, 4]
        catalog.board.locations[0].industrySlots[0][0] = "unknown-industry"
        catalog.cards[0].count = 63
        catalog.merchants.removeLast()

        let issues = GameCore.GameDataValidator.validate(catalog)
        let codes = Set(issues.map(\.code))

        #expect(codes.contains(.duplicateID))
        #expect(codes.contains(.missingReference))
        #expect(codes.contains(.invalidPlayerCount))
        #expect(codes.contains(.invalidComponentCount))
    }

    @Test func duplicateIndustryIsReportedWithoutCrashingTheValidator() {
        var catalog = completeCatalog()
        catalog.industries.append(catalog.industries[0])

        let issues = GameCore.GameDataValidator.validate(catalog)

        #expect(issues.contains { $0.code == .duplicateID && $0.path == "industries" })
    }

    @Test func manifestRejectsChangedFileBytes() {
        let original = Data("{\"version\":1}".utf8)
        let changed = Data("{\"version\":2}".utf8)
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            files: [
                .init(
                    path: "map.json",
                    sha256: GameCore.GameDataLoader.sha256(original)
                ),
            ],
            sources: []
        )

        #expect(
            GameCore.GameDataLoader.validateManifest(
                manifest,
                files: ["map.json": original]
            ).isEmpty
        )
        #expect(
            GameCore.GameDataLoader.validateManifest(
                manifest,
                files: ["map.json": changed]
            ) == [
                .init(code: .hashMismatch, path: "map.json", detail: "SHA-256 does not match manifest"),
            ]
        )
    }

    @Test func manifestSourceMetadataRoundTripsWithoutBundlingSourceArtwork() throws {
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            files: [],
            sources: [
                .init(
                    id: "roxley-rulebook-v2018.11",
                    url: "https://roxley.com/products/brass-birmingham",
                    component: "component inventory and setup rules",
                    version: "2018.11.20",
                    page: "1, 4",
                    transcriber: "Codex",
                    transcribedOn: "2026-08-17",
                    checker: nil,
                    checkedOn: nil
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(GameCore.GameDataManifest.self, from: encoded)

        #expect(decoded == manifest)
        #expect(String(decoding: encoded, as: UTF8.self).contains(".jpg") == false)
        #expect(String(decoding: encoded, as: UTF8.self).contains(".png") == false)
    }

    @Test func draftOrUncheckedSourcesCannotBecomeReleaseReady() {
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .draft,
            files: [],
            sources: [
                .init(
                    id: "roxley-rulebook-v2018.11",
                    url: "https://roxley.com/products/brass-birmingham",
                    component: "component inventory",
                    version: "2018.11.20",
                    page: "1",
                    transcriber: "Codex",
                    transcribedOn: "2026-08-17",
                    checker: nil,
                    checkedOn: nil
                ),
            ]
        )

        let codes = Set(GameCore.GameDataValidator.validateReadiness(manifest).map(\.code))
        let expected: Set<GameCore.GameDataValidationIssue.Code> = [
            .incompleteCatalog,
            .unverifiedSource,
        ]
        #expect(codes == expected)
    }

    @Test func verifiedManifestRequiresSourcesAndAnIndependentChecker() {
        let noSources = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: [],
            sources: []
        )
        let selfChecked = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: [],
            sources: [
                .init(
                    id: "source",
                    url: "https://example.com/source",
                    component: "test",
                    version: "v2018.11",
                    page: "1",
                    transcriber: "Same Person",
                    transcriberID: "same-person",
                    transcribedOn: "2026-08-17",
                    checker: "same person",
                    checkerID: "same-person",
                    checkedOn: "2026-08-17"
                ),
            ]
        )

        #expect(GameCore.GameDataValidator.validateReadiness(noSources).contains {
            $0.code == .unverifiedSource && $0.path == "manifest.sources"
        })
        #expect(GameCore.GameDataValidator.validateReadiness(selfChecked).contains {
            $0.code == .unverifiedSource && $0.detail.contains("different people")
        })
    }

    @Test func verifiedManifestRequiresReviewEvidenceUniqueSourcesAndStableIdentities() throws {
        let source = GameCore.GameDataManifest.Source(
            id: "source",
            url: "https://example.com/source",
            component: "test",
            version: "v2018.11",
            page: "1",
            transcriber: "Transcriber",
            transcriberID: "transcriber-id",
            transcribedOn: "2026-08-17",
            checker: "Checker",
            checkerID: "checker-id",
            checkedOn: "2026-08-20"
        )
        let noEvidence = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: [],
            sources: [source]
        )
        var duplicateSource = noEvidence
        duplicateSource.sources.append(source)

        #expect(GameCore.GameDataValidator.validateReadiness(noEvidence).contains {
            $0.path == "manifest.verificationEvidence"
        })
        #expect(GameCore.GameDataValidator.validateReadiness(duplicateSource).contains {
            $0.code == .duplicateID && $0.path == "manifest.sources"
        })

        var nextUTCDay = noEvidence
        nextUTCDay.sources[0].checkedOn = "2026-08-21"
        let utcBoundary = try #require(
            ISO8601DateFormatter().date(from: "2026-08-20T16:30:00Z")
        )
        #expect(GameCore.GameDataValidator.validateReadiness(nextUTCDay, now: utcBoundary).contains {
            $0.detail.contains("today")
        })
    }

    @Test func strictManifestDecoderRejectsDuplicateKeysAndNonFiniteNumbers() throws {
        let duplicate = Data("""
        {"rulesetVersion":"v2018.11","rulesetVersion":"v2018.11","verificationStatus":"draft","files":[],"sources":[]}
        """.utf8)
        let nonFinite = Data("""
        {"rulesetVersion":NaN,"verificationStatus":"draft","files":[],"sources":[]}
        """.utf8)

        for malformed in [duplicate, nonFinite] {
            do {
                _ = try GameCore.GameDataLoader.loadVerifiedCatalog(manifestData: malformed, files: [:])
                Issue.record("Expected strict manifest decoding to reject malformed JSON")
            } catch {
                #expect(true)
            }
        }
    }

    @Test func swiftReviewSerializationMatchesThePythonCanonicalArtifact() throws {
        let directory = committedDataDirectory()
        let manifestData = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(GameCore.GameDataManifest.self, from: manifestData)
        let files = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            (entry.path, try Data(contentsOf: directory.appending(path: entry.path)))
        })

        let artifact = try GameCore.GameDataReviewVerifier.makePendingArtifactForTesting(
            manifest: manifest,
            files: files
        )
        let headerLine = try #require(String(data: artifact, encoding: .utf8)?.split(separator: "\n").first)
        let header = try #require(
            try GameCore.StrictJSON.object(from: Data(headerLine.utf8)) as? [String: Any]
        )

        #expect(header["baseDataDigest"] as? String == "6ded83d62d817c484bac91cb6c043673ab7b10ab8ab332af8f21db126b19fc48")
        #expect(GameCore.GameDataLoader.sha256(artifact) == "b16befc9879439cc7f0585883c93d262ffc7e96173f0273abff50d31a493be06")
    }

    @Test func committedDraftDecodesMatchesItsManifestAndContainsNoReferenceArtwork() throws {
        let dataDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let manifestData = try Data(contentsOf: dataDirectory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(GameCore.GameDataManifest.self, from: manifestData)
        let files = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            (entry.path, try Data(contentsOf: dataDirectory.appending(path: entry.path)))
        })

        #expect(GameCore.GameDataLoader.validateManifest(manifest, files: files).isEmpty)

        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: manifest.rulesetVersion,
            mapData: try #require(files["map.json"]),
            industryData: try #require(files["industries.json"]),
            cardData: try #require(files["cards.json"]),
            merchantData: try #require(files["merchants.json"]),
            incomeTrackData: try #require(files["income-track.json"])
        )
        #expect(GameCore.GameDataValidator.validate(catalog).isEmpty)
        #expect(GameCore.GameDataValidator.validateReadiness(manifest).isEmpty == false)

        let forbiddenExtensions: Set<String> = [
            "aac", "aiff", "gif", "heic", "jpeg", "jpg", "m4a", "mp3", "otf", "pdf",
            "png", "svg", "ttf", "wav", "webp",
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: dataDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(contents.contains { forbiddenExtensions.contains($0.pathExtension.lowercased()) } == false)
    }

    @Test func verifiedLoaderRejectsTheCommittedDraftBeforeGameplay() throws {
        let dataDirectory = committedDataDirectory()
        let manifestData = try Data(contentsOf: dataDirectory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(GameCore.GameDataManifest.self, from: manifestData)
        let files = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            (entry.path, try Data(contentsOf: dataDirectory.appending(path: entry.path)))
        })

        do {
            _ = try GameCore.GameDataLoader.loadVerifiedCatalog(
                manifestData: manifestData,
                files: files
            )
            Issue.record("Expected the draft catalog to be rejected")
        } catch GameCore.GameDataLoadError.validationFailed(let issues) {
            #expect(issues.contains { $0.code == .incompleteCatalog })
            #expect(issues.contains { $0.code == .unverifiedSource })
        }
    }

    @Test func committedDraftContainsTheCompleteCrossCheckedNumericCatalog() throws {
        let catalog = completeCatalog()

        #expect(catalog.board.locations.count == 27)
        #expect(catalog.board.routes.count == 39)
        #expect(catalog.board.merchantSlots.count == 9)
        #expect(catalog.board.locations.reduce(0) { $0 + $1.industrySlots.count } == 49)
        #expect(catalog.incomeTrack.entries.count == 100)
        #expect(catalog.incomeTrack.entries[10].income == 0)
        #expect(catalog.incomeTrack.entries[60].income == 20)
        #expect(catalog.incomeTrack.entries[97].income == 30)

        let manufacturer = try #require(catalog.industries.first { $0.id == "manufacturer" })
        let manufacturerFour = try #require(manufacturer.levels.first { $0.level == 4 })
        #expect(manufacturerFour.buildCost == 8)
        #expect(manufacturerFour.beerCost == 1)

        let pottery = try #require(catalog.industries.first { $0.id == "pottery" })
        let potteryThree = try #require(pottery.levels.first { $0.level == 3 })
        #expect(potteryThree.canDevelop == false)
        #expect(potteryThree.beerCost == 2)

        let brewery = try #require(catalog.industries.first { $0.id == "brewery" })
        let breweryTwo = try #require(brewery.levels.first { $0.level == 2 })
        #expect(breweryTwo.production == .init(resource: .beer, canalCount: 1, railCount: 2))

        let standardCards = catalog.cards
            .filter { $0.kind == .location || $0.kind == .industry }
            .reduce(0) { $0 + $1.count }
        #expect(standardCards == 64)
        #expect(catalog.cards.filter { $0.playerCounts.contains(2) && ($0.kind == .location || $0.kind == .industry) }
            .reduce(0) { $0 + $1.count } == 40)
        #expect(catalog.cards.filter { $0.playerCounts.contains(3) && ($0.kind == .location || $0.kind == .industry) }
            .reduce(0) { $0 + $1.count } == 54)
        #expect(catalog.cards.contains {
            $0.targetIDs == ["cotton-mill", "manufacturer"] && $0.playerCounts == [3, 4]
        })
    }

    @Test func verifiedLoaderReturnsOnlyACompleteCheckedCatalog() throws {
        let catalog = completeCatalog()
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifestFiles = try files.keys.sorted().map { path in
            let data = try #require(files[path])
            return GameCore.GameDataManifest.FileDigest(
                path: path,
                sha256: GameCore.GameDataLoader.sha256(data)
            )
        }
        let reviewSourceIDs = [
            "roxley-rulebook-v2018.11",
            "bge-brass-birmingham-d11d438",
            "brassrl-457519c",
            "npow-brass-birmingham-2b1da2d",
        ]
        var manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: manifestFiles,
            sources: reviewSourceIDs.map { sourceID in
                .init(
                    id: sourceID,
                    url: "https://roxley.com/products/brass-birmingham",
                    component: "synthetic test fixture",
                    version: "v2018.11",
                    page: "test",
                    transcriber: "transcriber",
                    transcriberID: "transcriber-id",
                    transcribedOn: "2026-08-17",
                    checker: "checker",
                    checkerID: "checker-id",
                    checkedOn: "2026-08-17"
                )
            }
        )
        let pendingArtifact = try GameCore.GameDataReviewVerifier.makePendingArtifactForTesting(
            manifest: manifest,
            files: files
        )
        let signedArtifact = try signedReviewArtifact(
            pendingArtifact,
            checker: "checker",
            checkerID: "checker-id",
            checkedOn: "2026-08-17"
        )
        let headerLine = try #require(String(data: signedArtifact, encoding: .utf8)?.split(separator: "\n").first)
        let header = try #require(
            try GameCore.StrictJSON.object(from: Data(headerLine.utf8)) as? [String: Any]
        )
        manifest.verificationEvidence = .init(
            path: "verification-review.jsonl",
            sha256: GameCore.GameDataLoader.sha256(signedArtifact),
            rowCount: 243,
            baseDataDigest: try #require(header["baseDataDigest"] as? String)
        )

        let nonStringNotesArtifact = try replacingFirstReviewRowField(
            signedArtifact,
            field: "notes",
            value: 7
        )
        var nonStringNotesManifest = manifest
        nonStringNotesManifest.verificationEvidence?.sha256 = GameCore.GameDataLoader.sha256(nonStringNotesArtifact)
        #expect(GameCore.GameDataReviewVerifier.validate(
            artifactData: nonStringNotesArtifact,
            manifest: nonStringNotesManifest,
            files: files
        ).contains { $0.path.contains("review.rows") && $0.detail.contains("notes") })

        let loaded = try GameCore.GameDataLoader.loadVerifiedCatalog(
            manifestData: encoder.encode(manifest),
            files: files,
            verificationEvidenceData: signedArtifact
        )

        #expect(loaded == catalog)
    }

    @Test func swiftReviewRejectsManifestSourceCoverageMismatch() throws {
        let catalog = completeCatalog()
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: try files.keys.sorted().map { path in
                .init(path: path, sha256: GameCore.GameDataLoader.sha256(try #require(files[path])))
            },
            sources: [
                .init(
                    id: "owned-component-check",
                    url: "https://example.com",
                    component: "fixture",
                    version: "v2018.11",
                    page: "fixture",
                    transcriber: "transcriber",
                    transcriberID: "transcriber-id",
                    transcribedOn: "2026-08-17",
                    checker: "checker",
                    checkerID: "checker-id",
                    checkedOn: "2026-08-17"
                ),
            ]
        )

        do {
            _ = try GameCore.GameDataReviewVerifier.makePendingArtifactForTesting(
                manifest: manifest,
                files: files
            )
            Issue.record("Expected manifest source IDs to exactly cover review source references")
        } catch {
            #expect(true)
        }
    }

    private func committedDataDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
    }

    private func completeCatalog() -> GameCore.GameDataCatalog {
        let directory = committedDataDirectory()
        return try! GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
    }

    private func signedReviewArtifact(
        _ pending: Data,
        checker: String,
        checkerID: String,
        checkedOn: String
    ) throws -> Data {
        let text = try #require(String(data: pending, encoding: .utf8))
        let lines = text.split(separator: "\n")
        var output = Data()
        for (index, line) in lines.enumerated() {
            let value = try GameCore.StrictJSON.object(from: Data(line.utf8))
            if index == 0 {
                output.append(try GameCore.StrictJSON.canonicalData(value))
            } else {
                var row = try #require(value as? [String: Any])
                row["checker"] = checker
                row["checkerID"] = checkerID
                row["checkedOn"] = checkedOn
                row["status"] = "checked"
                output.append(try GameCore.StrictJSON.canonicalData(row))
            }
            output.append(0x0A)
        }
        return output
    }

    private func replacingFirstReviewRowField(
        _ artifact: Data,
        field: String,
        value: Any
    ) throws -> Data {
        let text = try #require(String(data: artifact, encoding: .utf8))
        let lines = text.split(separator: "\n")
        var output = Data()
        for (index, line) in lines.enumerated() {
            var object = try #require(
                try GameCore.StrictJSON.object(from: Data(line.utf8)) as? [String: Any]
            )
            if index == 1 {
                object[field] = value
            }
            output.append(try GameCore.StrictJSON.canonicalData(object))
            output.append(0x0A)
        }
        return output
    }
}
