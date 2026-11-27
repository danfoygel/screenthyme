import Foundation

/// Items whose use lists show as another's. Apple's data has the call screen (`BuiltInApps.callScreen`) apart from
/// Phone: Phone's own time is dialing, recents and voicemail, and the call screen's is a call with the screen on. The
/// call screen also shows FaceTime calls and other apps' calls (CallKit), but Apple doesn't say whose, so it's shown as
/// Phone's, which it mostly is. Their seconds never matched (three phones, Nov 2026), so adding them counts nothing
/// twice. Samples keep Apple's item; lists and timelines go through `apply`.
public enum ItemAliases {
    /// Item → the item its use is shown as, for a kid with both.
    public static func build(_ items: some Collection<TrackedItem>) -> [UUID: UUID] {
        var aliases: [UUID: UUID] = [:]
        let ids = Set(items.map(\.id))
        for item in items where item.kind == .app && item.identifier == BuiltInApps.callScreen {
            let phone = TrackedItem.id(kid: item.kidID, kind: .app, identifier: BuiltInApps.phone)
            if ids.contains(phone) { aliases[item.id] = phone }
        }
        return aliases
    }

    /// The samples with each alias's moved to its item, added to that item's sample of the same fetch when it has one.
    public static func apply(_ aliases: [UUID: UUID], to samples: [UsageSample]) -> [UsageSample] {
        guard !aliases.isEmpty, samples.contains(where: { aliases[$0.itemID] != nil }) else { return samples }
        let targets = Set(aliases.values)
        var result: [UsageSample] = []
        var index: [Fetch: Int] = [:]
        for var sample in samples {
            sample.itemID = aliases[sample.itemID] ?? sample.itemID
            guard targets.contains(sample.itemID) else { result.append(sample); continue }
            if let at = index[Fetch(sample)] {
                result[at].seconds += sample.seconds
            } else {
                index[Fetch(sample)] = result.count
                result.append(sample)
            }
        }
        return result
    }

    /// One item's sample of one fetch.
    private struct Fetch: Hashable {
        var itemID: UUID
        var start: Date
        var end: Date
        var reportedAt: Date?

        init(_ sample: UsageSample) {
            itemID = sample.itemID
            start = sample.start
            end = sample.end
            reportedAt = sample.reportedAt
        }
    }
}
