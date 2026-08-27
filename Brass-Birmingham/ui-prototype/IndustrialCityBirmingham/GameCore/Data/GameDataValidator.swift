import Foundation

extension GameCore {
    nonisolated struct GameDataValidationIssue: Codable, Equatable, Hashable, Sendable {
        enum Code: String, Codable, Equatable, Hashable, Sendable {
            case duplicateID
            case invalidID
            case missingReference
            case invalidPlayerCount
            case invalidLevel
            case invalidComponentCount
            case invalidIncomeTrack
            case missingFile
            case hashMismatch
            case unexpectedRuleset
            case incompleteCatalog
            case unverifiedSource
            case unexpectedFile
        }

        var code: Code
        var path: String
        var detail: String
    }

    nonisolated enum GameDataValidator {
        private static let supportedPlayerCounts = Set([2, 3, 4])
        private static let expectedIndustryCounts = [
            "brewery": 7,
            "coal-mine": 7,
            "cotton-mill": 11,
            "iron-works": 4,
            "manufacturer": 11,
            "pottery": 5,
        ]

        static func validate(_ catalog: GameDataCatalog) -> [GameDataValidationIssue] {
            var issues: [GameDataValidationIssue] = []

            if catalog.rulesetVersion != "v2018.11" {
                issues.append(issue(.unexpectedRuleset, "rulesetVersion", "Expected v2018.11"))
            }

            validateUniqueIDs(catalog.board.locations.map(\.id), path: "board.locations", into: &issues)
            validateUniqueIDs(catalog.board.routes.map(\.id), path: "board.routes", into: &issues)
            validateUniqueIDs(
                catalog.board.merchantSlots.map(\.id),
                path: "board.merchantSlots",
                into: &issues
            )
            validateUniqueIDs(catalog.industries.map(\.id), path: "industries", into: &issues)
            validateUniqueIDs(catalog.cards.map(\.id), path: "cards", into: &issues)
            validateUniqueIDs(catalog.merchants.map(\.id), path: "merchants", into: &issues)

            let locationIDs = Set(catalog.board.locations.map(\.id))
            let locationPlayerCounts = catalog.board.locations.reduce(
                into: [String: Set<Int>]()
            ) { counts, location in
                counts[location.id, default: []].formUnion(location.playerCounts)
            }
            let industryIDs = Set(catalog.industries.map(\.id))

            for (index, location) in catalog.board.locations.enumerated() {
                validateID(location.id, path: "board.locations[\(index)].id", into: &issues)
                validatePlayerCounts(
                    location.playerCounts,
                    path: "board.locations[\(index)].playerCounts",
                    into: &issues
                )
                let requiresIndustrySlots = location.kind != .merchant
                if requiresIndustrySlots == location.industrySlots.isEmpty {
                    issues.append(
                        issue(
                            .invalidComponentCount,
                            "board.locations[\(index)].industrySlots",
                            "Cities and brewery farms require slots; merchant locations cannot have them"
                        )
                    )
                }
                for (slotIndex, slot) in location.industrySlots.enumerated() {
                    if slot.isEmpty || Set(slot).count != slot.count {
                        issues.append(
                            issue(
                                .invalidComponentCount,
                                "board.locations[\(index)].industrySlots[\(slotIndex)]",
                                "Industry slots must be non-empty and cannot repeat an industry"
                            )
                        )
                    }
                    for industryID in slot where industryIDs.contains(industryID) == false {
                        issues.append(
                            issue(
                                .missingReference,
                                "board.locations[\(index)].industrySlots[\(slotIndex)]",
                                "Unknown industry \(industryID)"
                            )
                        )
                    }
                }
                if location.kind == .breweryFarm && location.industrySlots != [["brewery"]] {
                    issues.append(
                        issue(
                            .invalidComponentCount,
                            "board.locations[\(index)].industrySlots",
                            "A brewery farm must contain exactly one brewery-only slot"
                        )
                    )
                }
            }

            for (index, route) in catalog.board.routes.enumerated() {
                validateID(route.id, path: "board.routes[\(index)].id", into: &issues)
                validatePlayerCounts(
                    route.playerCounts,
                    path: "board.routes[\(index)].playerCounts",
                    into: &issues
                )
                if route.endpoints.count != 2 || Set(route.endpoints).count != 2 {
                    issues.append(
                        issue(
                            .missingReference,
                            "board.routes[\(index)].endpoints",
                            "A route must connect two distinct locations"
                        )
                    )
                }
                for endpoint in route.endpoints where locationIDs.contains(endpoint) == false {
                    issues.append(
                        issue(
                            .missingReference,
                            "board.routes[\(index)].endpoints",
                            "Unknown location \(endpoint)"
                        )
                    )
                }
                let adjacency = Set(route.adjacentLocationIDs)
                if route.adjacentLocationIDs.count < 2
                    || route.adjacentLocationIDs.count > 3
                    || adjacency.count != route.adjacentLocationIDs.count
                    || Set(route.endpoints).isSubset(of: adjacency) == false
                {
                    issues.append(
                        issue(
                            .missingReference,
                            "board.routes[\(index)].adjacentLocationIDs",
                            "Route adjacency must contain its endpoints and at most one brewery farm"
                        )
                    )
                }
                for locationID in route.adjacentLocationIDs where locationIDs.contains(locationID) == false {
                    issues.append(
                        issue(
                            .missingReference,
                            "board.routes[\(index)].adjacentLocationIDs",
                            "Unknown location \(locationID)"
                        )
                    )
                }
                for playerCount in Set(route.playerCounts).sorted() {
                    let activeAdjacentCount = adjacency.reduce(into: 0) { count, locationID in
                        if locationPlayerCounts[locationID]?.contains(playerCount) == true {
                            count += 1
                        }
                    }
                    if activeAdjacentCount < 2 {
                        issues.append(
                            issue(
                                .invalidPlayerCount,
                                "board.routes[\(index)].playerCounts",
                                "Player count \(playerCount) requires at least two active adjacent locations"
                            )
                        )
                    }
                }
                let eraSet = Set(route.eras)
                if route.eras.isEmpty || eraSet.count != route.eras.count {
                    issues.append(
                        issue(
                            .invalidComponentCount,
                            "board.routes[\(index)].eras",
                            "Route eras must be non-empty and unique"
                        )
                    )
                }
            }

            validateIndustries(catalog.industries, into: &issues)
            validateCards(catalog.cards, locationIDs: locationIDs, industryIDs: industryIDs, into: &issues)
            validateMerchantSlots(
                catalog.board.merchantSlots,
                locations: catalog.board.locations,
                into: &issues
            )
            validateMerchants(catalog.merchants, industryIDs: industryIDs, into: &issues)
            validateIncomeTrack(catalog.incomeTrack, into: &issues)

            if catalog.board.locations.count != 27 {
                issues.append(issue(.invalidComponentCount, "board.locations", "Expected 27 board locations"))
            }
            if catalog.board.routes.count != 39 {
                issues.append(issue(.invalidComponentCount, "board.routes", "Expected 39 link routes"))
            }

            return issues.sorted { lhs, rhs in
                (lhs.path, lhs.code.rawValue, lhs.detail) < (rhs.path, rhs.code.rawValue, rhs.detail)
            }
        }

        static func validateReadiness(
            _ manifest: GameDataManifest,
            now: Date = Date()
        ) -> [GameDataValidationIssue] {
            var issues: [GameDataValidationIssue] = []
            let todayUTC = auditDate(utcCivilDate(now))!
            if manifest.verificationStatus != .verified {
                issues.append(
                    issue(
                        .incompleteCatalog,
                        "manifest.verificationStatus",
                        "Catalog must be independently checked before it can be marked verified"
                    )
                )
            }
            if manifest.sources.isEmpty {
                issues.append(
                    issue(
                        .unverifiedSource,
                        "manifest.sources",
                        "At least one independently checked source is required"
                    )
                )
            }
            let sourceIDs = manifest.sources.map(\.id)
            if Set(sourceIDs).count != sourceIDs.count {
                issues.append(
                    issue(.duplicateID, "manifest.sources", "Source IDs must be unique")
                )
            }
            if manifest.verificationStatus == .verified, manifest.verificationEvidence == nil {
                issues.append(
                    issue(
                        .incompleteCatalog,
                        "manifest.verificationEvidence",
                        "Verified catalog requires a complete checked review artifact"
                    )
                )
            }
            let allTranscriberIDs = Set(manifest.sources.map(\.transcriberID))
            for (index, source) in manifest.sources.enumerated() {
                let requiredValues = [
                    source.id,
                    source.url,
                    source.component,
                    source.version,
                    source.page,
                    source.transcriber,
                    source.transcriberID,
                    source.transcribedOn,
                    source.checker ?? "",
                    source.checkerID ?? "",
                    source.checkedOn ?? "",
                ]
                let normalizedValues = requiredValues.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if normalizedValues.contains(where: { $0.isEmpty || $0.lowercased() == "pending" }) {
                    issues.append(
                        issue(
                            .unverifiedSource,
                            "manifest.sources[\(index)]",
                            "Source transcription needs complete transcriber and checker metadata"
                        )
                    )
                } else if allTranscriberIDs.contains(source.checkerID ?? "") {
                    issues.append(
                        issue(
                            .unverifiedSource,
                            "manifest.sources[\(index)]",
                            "Source transcriber and checker must identify different people"
                        )
                    )
                } else if isAuditableIdentity(source.transcriber) == false
                    || isAuditableIdentity(source.checker ?? "") == false
                    || isStableIdentityID(source.id) == false
                    || isStableIdentityID(source.transcriberID) == false
                    || isStableIdentityID(source.checkerID ?? "") == false
                {
                    issues.append(
                        issue(
                            .unverifiedSource,
                            "manifest.sources[\(index)]",
                            "Source identities must be NFKC-normalized and free of whitespace/control ambiguity"
                        )
                    )
                } else if let transcribedOn = auditDate(source.transcribedOn),
                    let checkedOn = auditDate(source.checkedOn ?? "")
                {
                    if transcribedOn > checkedOn || checkedOn > todayUTC {
                        issues.append(
                            issue(
                                .unverifiedSource,
                                "manifest.sources[\(index)]",
                                "Audit dates must satisfy transcribedOn <= checkedOn <= today"
                            )
                        )
                    }
                } else {
                    issues.append(
                        issue(
                            .unverifiedSource,
                            "manifest.sources[\(index)]",
                            "Audit dates must be real ISO YYYY-MM-DD dates"
                        )
                    )
                }
            }
            return issues
        }

        private static func isAuditableIdentity(_ value: String) -> Bool {
            guard value.isEmpty == false,
                value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                value == value.precomposedStringWithCompatibilityMapping
            else {
                return false
            }
            return value.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            } == false
        }

        private static func isStableIdentityID(_ value: String) -> Bool {
            isAuditableIdentity(value) && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 46, 48 ... 57, 95, 97 ... 122:
                    true
                default:
                    false
                }
            }
        }

        private static func auditDate(_ value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else {
                return nil
            }
            return parsed
        }

        private static func utcCivilDate(_ instant: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: instant)
        }

        private static func validateIndustries(
            _ industries: [IndustryDefinition],
            into issues: inout [GameDataValidationIssue]
        ) {
            let actualCounts = industries.reduce(into: [String: Int]()) { counts, industry in
                counts[industry.id, default: 0] += industry.levels.reduce(0) {
                    $0 + $1.copiesPerColor
                }
            }
            if actualCounts != expectedIndustryCounts {
                issues.append(
                    issue(
                        .invalidComponentCount,
                        "industries",
                        "Expected 45 tiles per color with the official six-industry distribution"
                    )
                )
            }

            for (industryIndex, industry) in industries.enumerated() {
                validateID(industry.id, path: "industries[\(industryIndex)].id", into: &issues)
                let levels = industry.levels.map(\.level)
                if levels.isEmpty || Set(levels).count != levels.count || levels.contains(where: { $0 <= 0 }) {
                    issues.append(
                        issue(
                            .invalidLevel,
                            "industries[\(industryIndex)].levels",
                            "Levels must be non-empty, positive and unique"
                        )
                    )
                }
                for (levelIndex, level) in industry.levels.enumerated() {
                    let values = [
                        level.copiesPerColor,
                        level.buildCost,
                        level.coalCost,
                        level.ironCost,
                        level.beerCost,
                        level.incomeReward,
                        level.victoryPoints,
                        level.linkPoints,
                    ]
                    if level.copiesPerColor <= 0 || values.dropFirst().contains(where: { $0 < 0 }) {
                        issues.append(
                            issue(
                                .invalidLevel,
                                "industries[\(industryIndex)].levels[\(levelIndex)]",
                                "Copies must be positive and numeric values cannot be negative"
                            )
                        )
                    }
                    if let production = level.production {
                        if production.canalCount < 0 || production.railCount < 0 {
                            issues.append(
                                issue(
                                    .invalidLevel,
                                    "industries[\(industryIndex)].levels[\(levelIndex)].production",
                                    "Production counts cannot be negative"
                                )
                            )
                        }
                        if level.canalEra == false && production.canalCount != 0
                            || level.railEra == false && production.railCount != 0
                        {
                            issues.append(
                                issue(
                                    .invalidLevel,
                                    "industries[\(industryIndex)].levels[\(levelIndex)].production",
                                    "Production must be zero in an era where the tile cannot be built"
                                )
                            )
                        }
                    }
                }
            }
        }

        private static func validateCards(
            _ cards: [CardDefinition],
            locationIDs: Set<String>,
            industryIDs: Set<String>,
            into issues: inout [GameDataValidationIssue]
        ) {
            let standardCount = cards
                .filter { $0.kind == .location || $0.kind == .industry }
                .reduce(0) { $0 + $1.count }
            let wildLocationCount = cards.filter { $0.kind == .wildLocation }.reduce(0) { $0 + $1.count }
            let wildIndustryCount = cards.filter { $0.kind == .wildIndustry }.reduce(0) { $0 + $1.count }
            if standardCount != 64 || wildLocationCount != 4 || wildIndustryCount != 4 {
                issues.append(
                    issue(
                        .invalidComponentCount,
                        "cards",
                        "Expected 64 standard, 4 wild-location and 4 wild-industry cards"
                    )
                )
            }

            for (index, card) in cards.enumerated() {
                validateID(card.id, path: "cards[\(index)].id", into: &issues)
                validatePlayerCounts(card.playerCounts, path: "cards[\(index)].playerCounts", into: &issues)
                if card.count <= 0 {
                    issues.append(issue(.invalidComponentCount, "cards[\(index)].count", "Count must be positive"))
                }
                switch card.kind {
                case .location:
                    if card.targetIDs.count != 1 || locationIDs.contains(card.targetIDs[0]) == false {
                        issues.append(issue(.missingReference, "cards[\(index)].targetIDs", "Unknown location"))
                    }
                case .industry:
                    if card.targetIDs.isEmpty
                        || Set(card.targetIDs).count != card.targetIDs.count
                        || card.targetIDs.contains(where: { industryIDs.contains($0) == false })
                    {
                        issues.append(issue(.missingReference, "cards[\(index)].targetIDs", "Unknown industry"))
                    }
                case .wildLocation, .wildIndustry:
                    if card.targetIDs.isEmpty == false {
                        issues.append(issue(.missingReference, "cards[\(index)].targetIDs", "Wild cards cannot target an ID"))
                    }
                }
            }
        }

        private static func validateMerchantSlots(
            _ slots: [BoardDefinition.MerchantSlot],
            locations: [BoardDefinition.Location],
            into issues: inout [GameDataValidationIssue]
        ) {
            if slots.count != 9 {
                issues.append(issue(.invalidComponentCount, "board.merchantSlots", "Expected 9 merchant slots"))
            }
            let merchantLocationIDs = Set(locations.filter { $0.kind == .merchant }.map(\.id))
            for (index, slot) in slots.enumerated() {
                validateID(slot.id, path: "board.merchantSlots[\(index)].id", into: &issues)
                validatePlayerCounts(
                    slot.playerCounts,
                    path: "board.merchantSlots[\(index)].playerCounts",
                    into: &issues
                )
                if merchantLocationIDs.contains(slot.locationID) == false {
                    issues.append(
                        issue(.missingReference, "board.merchantSlots[\(index)].locationID", "Unknown merchant location")
                    )
                }
                if slot.bonus.amount <= 0 {
                    issues.append(
                        issue(.invalidComponentCount, "board.merchantSlots[\(index)].bonus.amount", "Bonus must be positive")
                    )
                }
            }
        }

        private static func validateMerchants(
            _ merchants: [MerchantDefinition],
            industryIDs: Set<String>,
            into issues: inout [GameDataValidationIssue]
        ) {
            if merchants.reduce(0, { $0 + $1.count }) != 9 {
                issues.append(issue(.invalidComponentCount, "merchants", "Expected 9 merchant tiles"))
            }
            for (index, merchant) in merchants.enumerated() {
                validateID(merchant.id, path: "merchants[\(index)].id", into: &issues)
                validatePlayerCounts(
                    merchant.playerCounts,
                    path: "merchants[\(index)].playerCounts",
                    into: &issues
                )
                if merchant.count <= 0 {
                    issues.append(issue(.invalidComponentCount, "merchants[\(index)].count", "Count must be positive"))
                }
                if Set(merchant.acceptedIndustryIDs).count != merchant.acceptedIndustryIDs.count
                    || merchant.acceptedIndustryIDs.contains(where: { industryIDs.contains($0) == false })
                {
                    issues.append(
                        issue(.missingReference, "merchants[\(index)].acceptedIndustryIDs", "Unknown industry")
                    )
                }
            }
        }

        private static func validateIncomeTrack(
            _ incomeTrack: IncomeTrack,
            into issues: inout [GameDataValidationIssue]
        ) {
            let expected = (0...99).map { position in
                let income: Int
                switch position {
                case 0...10:
                    income = position - 10
                case 11...30:
                    income = Int(ceil(Double(position - 10) / 2.0))
                case 31...60:
                    income = 10 + Int(ceil(Double(position - 30) / 3.0))
                case 61...96:
                    income = 20 + Int(ceil(Double(position - 60) / 4.0))
                default:
                    income = 30
                }
                return IncomeTrack.Entry(position: position, income: income)
            }
            if incomeTrack.entries != expected {
                issues.append(
                    issue(
                        .invalidIncomeTrack,
                        "incomeTrack.entries",
                        "Expected the complete 100-space official income track"
                    )
                )
            }
        }

        private static func validateUniqueIDs(
            _ ids: [String],
            path: String,
            into issues: inout [GameDataValidationIssue]
        ) {
            var seen = Set<String>()
            for id in ids where seen.insert(id).inserted == false {
                issues.append(issue(.duplicateID, path, "Duplicate ID \(id)"))
            }
        }

        private static func validateID(
            _ id: String,
            path: String,
            into issues: inout [GameDataValidationIssue]
        ) {
            let allowed = id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
            }
            if id.isEmpty || id != id.lowercased() || allowed == false {
                issues.append(issue(.invalidID, path, "IDs must use lowercase ASCII letters, digits and hyphens"))
            }
        }

        private static func validatePlayerCounts(
            _ counts: [Int],
            path: String,
            into issues: inout [GameDataValidationIssue]
        ) {
            let set = Set(counts)
            if counts.isEmpty || set.count != counts.count || set.isSubset(of: supportedPlayerCounts) == false {
                issues.append(
                    issue(.invalidPlayerCount, path, "Player counts must be a unique subset of 2, 3 and 4")
                )
            }
        }

        private static func issue(
            _ code: GameDataValidationIssue.Code,
            _ path: String,
            _ detail: String
        ) -> GameDataValidationIssue {
            GameDataValidationIssue(code: code, path: path, detail: detail)
        }
    }
}
