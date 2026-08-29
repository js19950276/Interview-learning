import Testing
@testable import IndustrialCityBirmingham

struct FakeEventTests {
    @Test func fixtureValidIntentReturnsNextVersionAndVisibleEffects() async throws {
        let transport = FakeTransport()
        let state = DemoFixture.match(playerCount: 4)
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        )

        let event = try await transport.submit(intent: intent, state: state)
        let expectedEvent = try DemoEventFixture.event(for: intent, state: state)

        #expect(event == expectedEvent)
        #expect(event.version == state.actionNumber + 1)
        #expect(event.title.isEmpty == false)
        #expect(event.effects.contains { effect in
            if case .moveResource(kind: .coal, from: "coal-market", to: "birmingham") = effect {
                true
            } else {
                false
            }
        })
        #expect(event.effects.contains { effect in
            if case .marketChanged = effect { true } else { false }
        })
        #expect(event.effects.contains(.industryFlipped("industry-coal")))
        #expect(event.effects.contains(.incomeChanged(from: state.income, to: state.income + 1)))
        #expect(event.effects.contains(.actionAdvanced(from: state.actionNumber, to: state.actionNumber + 1)))
    }

    @Test func invalidTargetIsRejectedWithRecoveryWithoutMutatingMatch() async {
        let transport = FakeTransport()
        let state = DemoFixture.match(playerCount: 4)
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["invalid-target"]
        )

        do {
            _ = try await transport.submit(intent: intent, state: state)
            Issue.record("Expected invalid target to be rejected")
        } catch let rejection as RejectedIntent {
            #expect(rejection.reason.isEmpty == false)
            #expect(rejection.recoverySuggestion.isEmpty == false)
            #expect(rejection.reason.contains("invalid-target"))
        } catch {
            Issue.record("Expected RejectedIntent, got \(error)")
        }

        #expect(state == DemoFixture.match(playerCount: 4))
    }

    @Test @MainActor func reducerBuildsIntentWithoutClearingConfirmedDraft() {
        let reducer = MatchInteractionReducer()
        reducer.selectCard("card-birmingham")
        reducer.selectAction(.build)
        reducer.selectBuildLocation("birmingham", fixture: .standard)

        let intent = reducer.confirmedIntent()

        #expect(intent == DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        ))
        #expect(reducer.flow == .build(BuildDraft(locationID: "birmingham")))
        #expect(reducer.selectedCardID == "card-birmingham")
    }

    @Test func feedbackPlanMapsMarketAndTargetToDistinctResourceEndpoints() throws {
        let state = DemoFixture.match(playerCount: 4)
        let event = try DemoEventFixture.event(
            for: DemoIntent(
                action: .build,
                selectedCardID: "card-birmingham",
                targetIDs: ["birmingham"]
            ),
            state: state
        )

        let plan = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: false,
            hapticsEnabled: true
        )

        let motion = try #require(plan.resourceMotions.first)
        #expect(motion.sourceID == "coal-market")
        #expect(motion.destinationID == "birmingham")
        #expect(motion.source == DemoNormalizedPoint(x: 0.12, y: 0.78))
        #expect(motion.destination == DemoNormalizedPoint(x: 0.50, y: 0.54))
        #expect(motion.source != motion.destination)
    }

    @Test func feedbackPlanCoversMotionFlipHapticsAndAnnouncementContracts() throws {
        let state = DemoFixture.match(playerCount: 4)
        let event = try DemoEventFixture.event(
            for: DemoIntent(
                action: .build,
                selectedCardID: "card-birmingham",
                targetIDs: ["birmingham"]
            ),
            state: state
        )

        let standard = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: false,
            hapticsEnabled: true
        )
        let reduced = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: true,
            hapticsEnabled: false
        )

        #expect(standard.usesMarketNumericTransition)
        #expect(reduced.usesMarketNumericTransition == false)
        #expect(standard.flippedIndustryIDs == ["industry-coal"])
        #expect(standard.haptics == [.light, .medium, .success])
        #expect(reduced.haptics == [])
        #expect(standard.announcementTitle == event.title)
        #expect(standard.resourceMotions.first?.startsAtDestination == false)
        #expect(reduced.resourceMotions.first?.startsAtDestination == true)
    }

    @Test func developFeedbackTracksEveryResourceMotionForNormalAndReducedMotion() throws {
        let state = DemoFixture.match(playerCount: 4)
        let event = try DemoEventFixture.event(
            for: DemoIntent(
                action: .develop,
                selectedCardID: "card-birmingham",
                targetIDs: ["industry-coal", "industry-iron"]
            ),
            state: state
        )

        let standard = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: false,
            hapticsEnabled: false
        )
        let reduced = DemoFeedbackPlan.make(
            event: event,
            state: state,
            reduceMotion: true,
            hapticsEnabled: false
        )

        #expect(standard.resourceMotions.count == 2)
        #expect(Set(standard.resourceMotions.map(\.id)).count == 2)
        #expect(standard.initialDestinationMotionIDs == [])
        #expect(standard.finalDestinationMotionIDs == Set(standard.resourceMotions.map(\.id)))
        #expect(reduced.initialDestinationMotionIDs == Set(reduced.resourceMotions.map(\.id)))
        #expect(reduced.finalDestinationMotionIDs == Set(reduced.resourceMotions.map(\.id)))
    }

    @Test func submissionGateRejectsCancelledChangedOrVersionMismatchedSnapshots() {
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        )
        let replacement = DemoIntent(
            action: .build,
            selectedCardID: "card-coventry",
            targetIDs: ["coventry"]
        )
        var gate = DemoSubmissionGate()
        let snapshot = gate.begin(intent: intent, actionNumber: 1)

        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: intent,
            currentActionNumber: 1,
            eventVersion: 2
        ))
        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: replacement,
            currentActionNumber: 1,
            eventVersion: 2
        ) == false)
        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: intent,
            currentActionNumber: 2,
            eventVersion: 2
        ) == false)
        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: intent,
            currentActionNumber: 1,
            eventVersion: 3
        ) == false)

        gate.invalidate()

        #expect(gate.isSubmitting == false)
        #expect(gate.shouldApply(
            snapshot: snapshot,
            currentIntent: intent,
            currentActionNumber: 1,
            eventVersion: 2
        ) == false)
    }

    @Test func repeatedLegalSubmissionsAdvanceFromCurrentState() async throws {
        let transport = FakeTransport()
        let intent = DemoIntent(
            action: .build,
            selectedCardID: "card-birmingham",
            targetIDs: ["birmingham"]
        )
        let initialState = DemoFixture.match(playerCount: 4)

        let first = try await transport.submit(intent: intent, state: initialState)
        let stateAfterFirst = DemoEventReducer.applying(first, to: initialState)
        let second = try await transport.submit(intent: intent, state: stateAfterFirst)

        #expect(first.version == 2)
        #expect(first.effects.contains(.actionAdvanced(from: 1, to: 2)))
        #expect(first.effects.contains(.incomeChanged(from: 0, to: 1)))
        #expect(second.version == 3)
        #expect(second.effects.contains(.actionAdvanced(from: 2, to: 3)))
        #expect(second.effects.contains(.incomeChanged(from: 1, to: 2)))
        #expect(second.effects.contains { effect in
            guard case .marketChanged(let coalTo, let ironTo) = effect else { return false }
            return coalTo.remaining == stateAfterFirst.coalMarket.remaining - 1
                && coalTo.cheapestPrice == stateAfterFirst.coalMarket.cheapestPrice + 1
                && ironTo == stateAfterFirst.ironMarket
        })
    }

    @Test func fixtureRejectsInvalidIntentShapesAndCards() async {
        let transport = FakeTransport()
        let state = DemoFixture.match(playerCount: 4)
        let invalidIntents = [
            DemoIntent(action: .build, selectedCardID: "card-birmingham", targetIDs: []),
            DemoIntent(action: .build, selectedCardID: "card-birmingham", targetIDs: ["birmingham", "coventry"]),
            DemoIntent(action: .network, selectedCardID: "card-birmingham", targetIDs: []),
            DemoIntent(action: .network, selectedCardID: "card-birmingham", targetIDs: ["birmingham-coventry", "birmingham-walsall", "walsall-cannock"]),
            DemoIntent(action: .develop, selectedCardID: "card-birmingham", targetIDs: []),
            DemoIntent(action: .develop, selectedCardID: "card-birmingham", targetIDs: ["industry-coal", "industry-iron", "industry-coal"]),
            DemoIntent(action: .sell, selectedCardID: "card-birmingham", targetIDs: []),
            DemoIntent(action: .sell, selectedCardID: "card-birmingham", targetIDs: ["sell-cotton-oxford", "sell-manufacturer-warrington"]),
            DemoIntent(action: .scout, selectedCardID: "card-birmingham", targetIDs: ["card-walsall"]),
            DemoIntent(action: .scout, selectedCardID: "card-birmingham", targetIDs: ["card-walsall", "card-iron", "card-coal"]),
            DemoIntent(action: .scout, selectedCardID: "card-walsall", targetIDs: ["card-walsall", "card-iron"]),
            DemoIntent(action: .loan, selectedCardID: "card-birmingham", targetIDs: ["birmingham"]),
            DemoIntent(action: .pass, selectedCardID: "card-birmingham", targetIDs: ["birmingham"]),
            DemoIntent(action: .build, selectedCardID: "missing-card", targetIDs: ["birmingham"])
        ]

        for intent in invalidIntents {
            do {
                _ = try await transport.submit(intent: intent, state: state)
                Issue.record("Expected invalid intent to be rejected: \(intent)")
            } catch is RejectedIntent {
                // Expected domain rejection.
            } catch {
                Issue.record("Expected RejectedIntent, got \(error)")
            }
        }
    }

    @Test func fixtureRejectsCardThatDoesNotAllowAction() async {
        let transport = FakeTransport()
        var state = DemoFixture.match(playerCount: 4)
        let original = state.hand[0]
        state.hand[0] = HandCard(
            id: original.id,
            title: original.title,
            kind: original.kind,
            allowedActions: [.pass]
        )

        do {
            _ = try await transport.submit(
                intent: DemoIntent(
                    action: .build,
                    selectedCardID: original.id,
                    targetIDs: ["birmingham"]
                ),
                state: state
            )
            Issue.record("Expected disallowed card action to be rejected")
        } catch is RejectedIntent {
            // Expected domain rejection.
        } catch {
            Issue.record("Expected RejectedIntent, got \(error)")
        }
    }

    @Test func rejectionAccessibilityContractFocusesRecoveryAndPreservesDraft() {
        let rejection = RejectedIntent(
            reason: "目标 invalid-target 不可用。",
            recoverySuggestion: "请选择高亮目标。"
        )

        let plan = DemoRejectionFeedbackPlan.make(rejection: rejection)

        #expect(plan.shouldFocus)
        #expect(plan.preservesDraft)
        #expect(plan.accessibilityLabel.contains(rejection.reason))
        #expect(plan.accessibilityLabel.contains(rejection.recoverySuggestion))
    }

    @Test func technicalFailureContractPreservesDiagnosticsAndDraft() {
        let failure = TechnicalSubmissionFailure(
            diagnostic: "socket reset by peer",
            retrySuggestion: "请稍后重试。"
        )

        let plan = DemoTechnicalFailureFeedbackPlan.make(failure: failure)

        #expect(plan.shouldFocus)
        #expect(plan.preservesDraft)
        #expect(plan.accessibilityLabel.contains(failure.diagnostic))
        #expect(plan.accessibilityLabel.contains(failure.retrySuggestion))
    }
}
