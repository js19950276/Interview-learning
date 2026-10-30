import Foundation
import PhoneProtocol

/// Per-conversation catch-up ring (spec: 追赶环).
///
/// A bounded, append-order buffer of the newest normalized events used to
/// replay what a reconnecting phone missed. Capacity is 2000 events OR
/// 8 MiB of accounted payload (`EventLimits.catchUpRingEventCount` /
/// `catchUpRingBytes`), whichever is hit first. When eviction drops events
/// the phone has not yet received, `droppedSeq` becomes non-nil and the
/// phone must re-open the conversation instead of catching up.
///
/// Approximate event size: utf8 counts of `text` + `toolPreview` + `diff`,
/// plus 64 bytes of per-event overhead.
public struct CatchUpRing {

    /// Highest evicted seq, or nil while nothing has been dropped.
    public private(set) var droppedSeq: Int64?

    /// True once any event has been evicted.
    public var overflowed: Bool { droppedSeq != nil }

    private var buffer: [ConversationEvent] = []
    private var accountedBytes = 0

    public init() {}

    /// Number of retained events.
    public var count: Int { buffer.count }

    /// Accounted payload bytes of the retained events.
    public var bytes: Int { accountedBytes }

    /// Append the newest event, evicting from the oldest end while over
    /// either limit.
    public mutating func append(_ event: ConversationEvent) {
        buffer.append(event)
        accountedBytes += Self.approximateSize(of: event)
        while buffer.count > EventLimits.catchUpRingEventCount || accountedBytes > EventLimits.catchUpRingBytes {
            guard let oldest = buffer.first else {
                accountedBytes = 0
                break
            }
            buffer.removeFirst()
            accountedBytes -= Self.approximateSize(of: oldest)
            if let dropped = droppedSeq {
                droppedSeq = max(dropped, oldest.seq)
            } else {
                droppedSeq = oldest.seq
            }
        }
    }

    /// Events with `seq > afterSeq`, oldest first. Cheap when the phone is
    /// near the newest end.
    public func events(afterSeq: Int64) -> [ConversationEvent] {
        guard let firstIndex = buffer.firstIndex(where: { $0.seq > afterSeq }) else { return [] }
        return Array(buffer[firstIndex...])
    }

    /// Whether the phone at `afterSeq` can no longer be caught up from the
    /// ring (events it has not received were evicted) and must re-open.
    public func shouldReopen(afterSeq: Int64) -> Bool {
        guard let dropped = droppedSeq else { return false }
        return dropped > afterSeq
    }

    /// Approximate wire size: text + toolPreview + diff utf8 counts + 64.
    public static func approximateSize(of event: ConversationEvent) -> Int {
        (event.text?.utf8.count ?? 0)
            + (event.toolPreview?.utf8.count ?? 0)
            + (event.diff?.utf8.count ?? 0)
            + 64
    }
}
