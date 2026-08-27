import Foundation

extension GameCore {
    nonisolated struct GameDataCatalog: Codable, Equatable, Sendable {
        var rulesetVersion: String
        var board: BoardDefinition
        var industries: [IndustryDefinition]
        var cards: [CardDefinition]
        var merchants: [MerchantDefinition]
        var incomeTrack: IncomeTrack
    }

    nonisolated struct GameDataManifest: Codable, Equatable, Sendable {
        enum VerificationStatus: String, Codable, Equatable, Sendable {
            case draft
            case verified
        }

        struct FileDigest: Codable, Equatable, Sendable {
            var path: String
            var sha256: String
        }

        struct Source: Codable, Equatable, Sendable {
            var id: String
            var url: String
            var component: String
            var version: String
            var page: String
            var transcriber: String
            var transcriberID: String
            var transcribedOn: String
            var checker: String?
            var checkerID: String?
            var checkedOn: String?

            init(
                id: String,
                url: String,
                component: String,
                version: String,
                page: String,
                transcriber: String,
                transcriberID: String = "",
                transcribedOn: String,
                checker: String? = nil,
                checkerID: String? = nil,
                checkedOn: String? = nil
            ) {
                self.id = id
                self.url = url
                self.component = component
                self.version = version
                self.page = page
                self.transcriber = transcriber
                self.transcriberID = transcriberID
                self.transcribedOn = transcribedOn
                self.checker = checker
                self.checkerID = checkerID
                self.checkedOn = checkedOn
            }
        }

        struct VerificationEvidence: Codable, Equatable, Sendable {
            var path: String
            var sha256: String
            var rowCount: Int
            var baseDataDigest: String
        }

        var rulesetVersion: String
        var verificationStatus: VerificationStatus
        var files: [FileDigest]
        var sources: [Source]
        var verificationEvidence: VerificationEvidence?

        init(
            rulesetVersion: String,
            verificationStatus: VerificationStatus = .draft,
            files: [FileDigest],
            sources: [Source],
            verificationEvidence: VerificationEvidence? = nil
        ) {
            self.rulesetVersion = rulesetVersion
            self.verificationStatus = verificationStatus
            self.files = files
            self.sources = sources
            self.verificationEvidence = verificationEvidence
        }
    }
}
