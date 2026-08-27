import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class PrototypeRenderAcknowledgementTracker {
    struct Ticket: Equatable, Sendable {
        let name: PrototypeSignpost.Name
        let generation: UInt64
    }

    private struct PendingResponse {
        var ticket: Ticket
        var intervals: [PrototypeSignpost.Interval]
    }

    private var nextGeneration: UInt64 = 0
    private var pendingResponses: [PrototypeSignpost.Name: PendingResponse] = [:]

    @discardableResult
    func begin(_ name: PrototypeSignpost.Name) -> Ticket {
        nextGeneration &+= 1
        let ticket = Ticket(name: name, generation: nextGeneration)
        let interval = PrototypeSignpost.begin(name)

        if var pending = pendingResponses[name] {
            pending.ticket = ticket
            pending.intervals.append(interval)
            pendingResponses[name] = pending
        } else {
            pendingResponses[name] = PendingResponse(ticket: ticket, intervals: [interval])
        }
        return ticket
    }

    func ticket(for name: PrototypeSignpost.Name) -> Ticket? {
        pendingResponses[name]?.ticket
    }

    func latestInterval(for name: PrototypeSignpost.Name) -> PrototypeSignpost.Interval? {
        pendingResponses[name]?.intervals.last
    }

    func acknowledge(_ ticket: Ticket) {
        guard let pending = pendingResponses[ticket.name], pending.ticket == ticket else { return }
        pendingResponses[ticket.name] = nil
        pending.intervals.forEach { $0.end() }
    }
}

extension View {
    func prototypeRenderAcknowledgement(
        _ ticket: PrototypeRenderAcknowledgementTracker.Ticket?,
        tracker: PrototypeRenderAcknowledgementTracker
    ) -> some View {
        overlay {
            PrototypeLayoutAcknowledgementView(ticket: ticket) {
                tracker.acknowledge($0)
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("prototype.renderAcknowledgement")
            .accessibilityHidden(true)
        }
    }
}

private struct PrototypeLayoutAcknowledgementView: UIViewRepresentable {
    let ticket: PrototypeRenderAcknowledgementTracker.Ticket?
    let onLayout: @MainActor (PrototypeRenderAcknowledgementTracker.Ticket) -> Void

    func makeUIView(context: Context) -> LayoutAcknowledgementView {
        let view = LayoutAcknowledgementView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.accessibilityIdentifier = "prototype.renderAcknowledgement"
        view.backgroundColor = .clear
        view.configure(ticket: ticket, onLayout: onLayout)
        return view
    }

    func updateUIView(_ view: LayoutAcknowledgementView, context: Context) {
        view.configure(ticket: ticket, onLayout: onLayout)
    }

    final class LayoutAcknowledgementView: UIView {
        private var pendingTicket: PrototypeRenderAcknowledgementTracker.Ticket?
        private var acknowledgedTicket: PrototypeRenderAcknowledgementTracker.Ticket?
        private var onLayout: (@MainActor (PrototypeRenderAcknowledgementTracker.Ticket) -> Void)?

        func configure(
            ticket: PrototypeRenderAcknowledgementTracker.Ticket?,
            onLayout: @escaping @MainActor (PrototypeRenderAcknowledgementTracker.Ticket) -> Void
        ) {
            self.onLayout = onLayout
            guard pendingTicket != ticket else { return }
            pendingTicket = ticket
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let pendingTicket,
                  pendingTicket != acknowledgedTicket,
                  let onLayout else { return }
            acknowledgedTicket = pendingTicket
            Task { @MainActor in
                onLayout(pendingTicket)
            }
        }
    }
}
