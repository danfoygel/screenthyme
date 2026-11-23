import Foundation
import ThymeCore

/// What goes over the nearby link (PLAN.md §17). Kid → parent: today's and yesterday's usage, a fresh heartbeat,
/// alerts and requests for more time. Parent → kid: that kid's rules, policy and answers. Received records go where
/// CloudKit's copies would, and CloudKit's copies overwrite them later (same ids).
extension AppModel {
    /// Runs the link while this phone is open, has a role and has the family's secret.
    func updateNearby() {
        guard let key = data.linkKey, config.family != nil else { return stopNearby() }
        let configuration: NearbyLink.Configuration
        switch config.role {
        case .kid:
            guard let kid = config.kid else { return stopNearby() }
            configuration = .init(key: key, role: .kid, kidID: kid.id, name: kid.displayName)
        case .parent:
            configuration = .init(key: key, role: .parent, kidID: nil, name: senderName)
        case .unset:
            return stopNearby()
        }
        nearby.bundleFor = { [unowned self] peer in nearbyBundle(for: peer) }
        nearby.received = { [unowned self] bundle, peer in receivedNearby(bundle, from: peer) }
        nearby.start(configuration)
        guard nearbyTicker == nil else { return }
        nearbyTicker = Task { [weak self] in
            var lastSample = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, nearby.isRunning else { return }
                // Fresher numbers for a parent watching: the extension samples only every minute of use.
                if isKid, !nearby.peers.isEmpty, Date().timeIntervalSince(lastSample) >= 60 {
                    lastSample = Date()
                    await sampleNow()
                }
                nearby.sendUpdates()
            }
        }
    }

    func stopNearby() {
        nearbyTicker?.cancel()
        nearbyTicker = nil
        nearby.stop()
    }

    private func nearbyBundle(for peer: LinkHello) -> LinkBundle {
        switch (config.role, peer.role) {
        case (.kid, .parent): kidBundle()
        case (.parent, .kid): peer.kidID.map(parentBundle) ?? LinkBundle()
        default: LinkBundle()
        }
    }

    private func kidBundle() -> LinkBundle {
        guard let kid = config.kid else { return LinkBundle() }
        let journal = AppGroup.journal
        let today = DayKey(Date(), calendar: journal.calendar)
        let days: Set = [today.adding(days: -1, calendar: journal.calendar), today]
        func recent(_ date: Date) -> Bool { days.contains(DayKey(date, calendar: journal.calendar)) }
        var bundle = LinkBundle()
        bundle.kids = [kid]
        bundle.items = AppGroup.loadItems()
        bundle.epochs = config.epoch.map { [$0] } ?? []
        bundle.fires = Uploader.fires(from: days.flatMap { journal.entries(on: $0) }, kid: kid, epochID: config.epoch?.id,
                                      calendar: journal.calendar)
        bundle.samples = AppGroup.samples.readAll().filter { days.contains($0.day) }
        bundle.heartbeats = makeHeartbeat(.nearby).map { [$0] } ?? []
        bundle.alerts = AppGroup.outbox.readAll().filter { recent($0.at) }
        bundle.requests = AppGroup.requests.readAll().filter { recent($0.at) }
        bundle.extraMinutes = AppGroup.extraMinuteUses.readAll().filter { recent($0.at) }
        bundle.grants = AppGroup.selfGrants.readAll().filter { recent($0.at) }
        bundle.pairing = pairingShown.map { [$0] }  // so a parent's phone that connects later knows
        return bundle
    }

    private func parentBundle(kid: UUID) -> LinkBundle {
        var bundle = LinkBundle()
        // Only the rule set this phone published: an older one would be refused anyway, and a mirror still loading
        // has no rules to speak for.
        bundle.ruleSets = publishedRuleSet(kid: kid).map { [$0] } ?? []
        bundle.policies = data.storedPolicy(for: kid).map { [$0] } ?? []
        let since = DayKey(Date()).adding(days: -1).start()
        bundle.grants = data.grants.values.filter { $0.kidID == kid && $0.at >= since }
        return bundle
    }

    private func receivedNearby(_ bundle: LinkBundle, from peer: LinkHello) {
        for message in bundle.pairing ?? [] { receivedPairing(message, from: peer) }
        var bundle = bundle
        bundle.pairing = nil
        guard !bundle.isEmpty else { return }
        switch (config.role, peer.role) {
        case (.parent, .kid):
            guard let kidID = peer.kidID else { return }
            let usage = bundle.only(kid: kidID)
            let newAlerts = data.ingest(IngestBatch(kids: usage.kids, items: usage.items, epochs: usage.epochs,
                                                    fires: usage.fires, samples: usage.samples,
                                                    heartbeats: usage.heartbeats, alerts: usage.alerts,
                                                    requests: usage.requests,
                                                    // A kid's phone answers only its own requests, when it self-approves.
                                                    grants: usage.grants.filter(\.isSelfApproved),
                                                    extraMinutes: usage.extraMinutes ?? []))
            // Offline there's no CloudKit push; "asks for more time" is one of these. Once ingested, a later fetch
            // doesn't notify again (the owner's CloudKit push may still come when the kid's phone uploads).
            newAlerts.filter { Date().timeIntervalSince($0.at) < 3600 }.forEach(Notifier.post)
            notifyHealthIssues()
        case (.kid, .parent):
            guard let kid = config.kid else { return }
            let answers = bundle.only(kid: kid.id)
            data.ingest(IngestBatch(policies: answers.policies, grants: answers.grants))
            Task {
                await Enforcer.offMain {
                    for set in answers.ruleSets { KidSync.saveRules(set) }
                    for policy in answers.policies { KidSync.savePolicy(policy) }
                    for grant in answers.grants { Enforcer.apply(grant) }
                }
            }
        default:
            break
        }
    }

    // MARK: - Matching by a parent's camera (PLAN.md §15.6)

    /// Kid: what the pairing screen shows now (nil: it closed), to every parent's phone nearby.
    func showPairing(_ progress: LinkPairing?) {
        pairingShown = progress
        nearby.send([progress ?? .progress(showing: nil, done: 0, total: 0)]) { $0.role == .parent }
    }

    /// Kid: what pairing found, to every parent's phone nearby.
    func sendPairingResult(_ text: String) {
        nearby.send([.result(text)]) { $0.role == .parent }
    }

    /// Parent: the codes read so far, to that kid's phone.
    func sendPairingCodes(_ texts: [String], to kid: UUID) {
        nearby.send([.codes(texts)]) { $0.role == .kid && $0.kidID == kid }
    }

    private func receivedPairing(_ message: LinkPairing, from peer: LinkHello) {
        switch (config.role, peer.role, message) {
        case let (.kid, .parent, .codes(texts)):
            pairingCodes.formUnion(texts)
        case let (.parent, .kid, .progress(showing, done, total)):
            guard let kid = peer.kidID else { return }
            pairingPeers[kid, default: PairingPeer()].showing = showing
            pairingPeers[kid, default: PairingPeer()].done = done
            pairingPeers[kid, default: PairingPeer()].total = total
        case let (.parent, .kid, .result(text)):
            guard let kid = peer.kidID else { return }
            pairingPeers[kid, default: PairingPeer()].result = text
        default:
            break
        }
    }

    // MARK: - Rule sets this phone published

    func rememberPublished(_ set: RuleSet) {
        UserDefaults.standard.set(try? JSONEncoder.thyme.encode(set), forKey: "publishedRuleSet.\(set.kidID)")
    }

    private func publishedRuleSet(kid: UUID) -> RuleSet? {
        UserDefaults.standard.data(forKey: "publishedRuleSet.\(kid)").flatMap { try? JSONDecoder.thyme.decode(RuleSet.self, from: $0) }
    }
}

/// A kid's pairing screen, as a parent's phone hears of it.
struct PairingPeer: Equatable {
    /// The report it shows; nil once it has shown them all, or closed (`total` 0).
    var showing: String?
    var done = 0
    var total = 0
    var result: String?
}
