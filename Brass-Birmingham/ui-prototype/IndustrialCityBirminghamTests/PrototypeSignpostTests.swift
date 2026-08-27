import Testing
@testable import IndustrialCityBirmingham

@Suite("Prototype performance signposts")
struct PrototypeSignpostTests {
    @Test @MainActor
    func intervalTracksItsNamedLifecycleAndEndsOnlyOnce() {
        let interval = PrototypeSignpost.begin(.cardResponse)

        #expect(interval.name == .cardResponse)
        #expect(interval.hasEnded == false)

        interval.end()
        interval.end()

        #expect(interval.hasEnded)
        #expect(interval.endCount == 1)
    }

    @Test @MainActor
    func renderIntervalStaysOpenUntilMatchingLayoutAcknowledgement() {
        let tracker = PrototypeRenderAcknowledgementTracker()
        let ticket = tracker.begin(.drawerResponse)
        let interval = tracker.latestInterval(for: .drawerResponse)

        #expect(interval?.hasEnded == false)

        tracker.acknowledge(ticket)
        tracker.acknowledge(ticket)

        #expect(interval?.hasEnded == true)
        #expect(interval?.endCount == 1)
    }

    @Test @MainActor
    func latestLayoutAcknowledgementEndsCoalescedIntervalsButStaleAcknowledgementDoesNot() {
        let tracker = PrototypeRenderAcknowledgementTracker()
        let staleTicket = tracker.begin(.targetGlow)
        let firstInterval = tracker.latestInterval(for: .targetGlow)
        let latestTicket = tracker.begin(.targetGlow)
        let secondInterval = tracker.latestInterval(for: .targetGlow)

        tracker.acknowledge(staleTicket)
        #expect(firstInterval?.hasEnded == false)
        #expect(secondInterval?.hasEnded == false)

        tracker.acknowledge(latestTicket)
        tracker.acknowledge(staleTicket)
        tracker.acknowledge(latestTicket)

        #expect(firstInterval?.endCount == 1)
        #expect(secondInterval?.endCount == 1)
        #expect(tracker.ticket(for: .targetGlow) == nil)
    }

    @Test
    func requiredPointsOfInterestNamesRemainStable() {
        #expect(PrototypeSignpost.Name.allCases.map(\.rawValue) == [
            "CardResponse",
            "DrawerResponse",
            "MapPanZoom",
            "TargetGlow",
            "MarketUpdate"
        ])
    }
}
