import Foundation

@MainActor final class MockBridge: GrokBridgeTransport {
    var stateHandler: (String?, String?) async throws -> BridgeSnapshot = { bot, session in
        fixture(botID: bot ?? "alpha", sessionID: session ?? "")
    }
    var sendHandler: (String, String, String, UUID) async throws -> SendAcceptance = { _, _, _, _ in
        SendAcceptance(accepted: true, nonce: "accepted")
    }
    var olderHandler: (String, String) async throws -> BridgeSnapshot = { bot, session in
        fixture(botID: bot, sessionID: session, older: true)
    }
    var stateCalls = 0
    var sendCalls = 0
    var connectCalls = 0
    func state(botID: String?, sessionID: String?) async throws -> BridgeSnapshot {
        stateCalls += 1
        return try await stateHandler(botID, sessionID)
    }
    func send(botID: String, sessionID: String, text: String, requestID: UUID) async throws -> SendAcceptance {
        sendCalls += 1
        return try await sendHandler(botID, sessionID, text, requestID)
    }
    func connect() async throws { connectCalls += 1 }
    func older(botID: String, sessionID: String) async throws -> BridgeSnapshot {
        try await olderHandler(botID, sessionID)
    }
}

@MainActor func fixture(botID: String, sessionID: String = "", older: Bool = false) -> BridgeSnapshot {
    BridgeSnapshot(connected: true, bots: [
        Bot(id: "alpha", name: "Alpha", role: "", symbol: "person", isRunning: false, awaitingApproval: false),
        Bot(id: "beta", name: "Beta", role: "", symbol: "person", isRunning: true, awaitingApproval: true)
    ], selectedBotId: botID, selectedSessionId: sessionID,
       messages: [ChatMessage(id: "\(botID)-\(sessionID)-\(older)", isUser: false,
                              text: "\(botID):\(sessionID):\(older)", isStreaming: false)],
       sessions: [Conversation(id: "", botID: botID, title: "Principal"),
                  Conversation(id: "thread", botID: botID, title: "Fil")], hasOlder: !older)
}

@MainActor func waitUntil(_ label: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        precondition(Date() < deadline, "Timed out: \(label)")
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@main struct ModelChecks {
    @MainActor static func main() async throws {
        var tracker = BotUpdateTracker()
        let now = Date(timeIntervalSince1970: 1000)
        var tracked = Bot(id: "alpha", name: "Alpha", role: "", symbol: "person", isRunning: false, awaitingApproval: false)
        tracked.lastMessageID = "message-1"; tracked.preview = "Ancien message"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty, "Startup must not replay history")
        tracked.lastMessageID = "message-2"; tracked.preview = "Nouvelle réponse"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).count == 1)
        tracked.preview = "Nouvelle réponse, suite en streaming"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty, "Do not notify for every streamed fragment")
        tracked.lastMessageID = "message-3"; tracked.lastMessageIsUser = true; tracked.preview = "Mon message"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty, "Own messages must not generate incoming notifications")
        tracker.noteOutgoing(botID: "alpha", text: "Message depuis la notch", now: now)
        tracked.lastMessageID = "message-4"; tracked.lastMessageIsUser = false; tracked.preview = "Message depuis la notch"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty, "Suppress own echo when role metadata is late")
        tracked.lastMessageID = "message-5"; tracked.preview = "Réponse dans le chat visible"
        precondition(tracker.ingest([tracked], visibleBotID: "alpha", now: now).isEmpty)
        tracked.lastMessageID = "message-6"; tracked.preview = ""
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty)
        tracked.preview = "Texte arrivé après l’identifiant"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).count == 1, "Late text must still notify")
        tracked.lastMessageID = "message-7"; tracked.preview = "Début"; tracked.lastMessageIsStreaming = true
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now).isEmpty, "Let the first fragments settle")
        tracked.preview = "Réponse en cours plus complète"
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now.addingTimeInterval(4)).count == 1)
        tracked.preview = "Réponse terminée"; tracked.lastMessageIsStreaming = false
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now.addingTimeInterval(5)).isEmpty)
        tracked.lastMessageID = "message-8"; tracked.preview = "Réponse déjà visible"; tracked.lastMessageIsStreaming = true
        precondition(tracker.ingest([tracked], visibleBotID: "alpha", now: now).isEmpty)
        tracked.lastMessageIsStreaming = false
        precondition(tracker.ingest([tracked], visibleBotID: nil, now: now.addingTimeInterval(6)).isEmpty, "Closing a visible chat must not replay its response")
        // Exercise the actual store, not just the reducer: preferences consume
        // muted events, and a live preview updates without re-alerting.
        let notificationBridge = MockBridge()
        var liveBot = tracked
        liveBot.lastMessageIsStreaming = false
        func noticeSnapshot() -> BridgeSnapshot {
            let base = fixture(botID: "alpha")
            return BridgeSnapshot(connected: true, bots: [liveBot], selectedBotId: "alpha", selectedSessionId: "",
                messages: base.messages, sessions: base.sessions, hasOlder: false)
        }
        notificationBridge.stateHandler = { _, _ in noticeSnapshot() }
        let notificationStore = ChatStore(transport: notificationBridge, pollInterval: .seconds(3600))
        var received = 0
        notificationStore.onIncomingMessage = { _ in received += 1 }
        notificationStore.start()
        await waitUntil("notification baseline") { notificationStore.isConnected }
        notificationStore.messageNotificationsEnabled = false
        liveBot.lastMessageID = "muted"; liveBot.preview = "Message silencieux"
        await notificationStore.refresh()
        precondition(received == 0 && notificationStore.latestNotice == nil)
        notificationStore.messageNotificationsEnabled = true
        await notificationStore.refresh()
        precondition(received == 0, "Re-enabling must not replay muted messages")
        liveBot.lastMessageID = "live"; liveBot.preview = "Début de réponse"
        await notificationStore.refresh()
        precondition(received == 1 && notificationStore.latestNotice?.preview == "Début de réponse")
        liveBot.preview = "Réponse complète"
        await notificationStore.refresh()
        precondition(received == 1 && notificationStore.latestNotice?.preview == "Réponse complète")
        notificationStore.conversationVisibility(true)
        precondition(notificationStore.latestNotice == nil)
        notificationStore.shutdown()
        let bridge = MockBridge()
        let store = ChatStore(transport: bridge, pollInterval: .seconds(3600))
        store.start()
        await waitUntil("initial real state") { store.isConnected }
        precondition(store.bots.count == 2 && store.selectedBotID == "alpha")

        // A cancelled, slow request for Beta must never overwrite a newer Alpha selection.
        var betaReply: CheckedContinuation<BridgeSnapshot, Never>?
        bridge.stateHandler = { bot, session in
            if bot == "beta" {
                return await withCheckedContinuation { betaReply = $0 }
            }
            return fixture(botID: bot ?? "alpha", sessionID: session ?? "")
        }
        store.draft = "Brouillon Alpha"
        store.select(store.bots[1])
        await waitUntil("slow Beta request") { betaReply != nil }
        store.select(store.bots[0])
        await waitUntil("new Alpha request") { store.messages.first?.text.hasPrefix("alpha:") == true }
        betaReply?.resume(returning: fixture(botID: "beta"))
        await Task.yield()
        precondition(store.selectedBotID == "alpha" && store.draft == "Brouillon Alpha")

        bridge.stateHandler = { bot, session in fixture(botID: bot ?? "alpha", sessionID: session ?? "") }
        store.select(store.bots[1])
        await waitUntil("Beta state") { store.messages.first?.text.hasPrefix("beta:") == true }
        precondition(store.awaitingApproval && store.isWorking)
        store.draft = "Brouillon Beta"
        store.selectSession(store.history.first { $0.id == "thread" }!)
        await waitUntil("thread state") { store.messages.first?.text.hasPrefix("beta:thread:") == true }
        precondition(store.draft.isEmpty)
        store.draft = "Brouillon du fil"
        store.selectSession(store.history.first { $0.id == "" }!)
        await waitUntil("base session") { store.selectedSessionID.isEmpty && !store.messages.isEmpty }
        precondition(store.draft == "Brouillon Beta")

        // While awaiting acknowledgement the draft survives, including edits made during the request.
        var acceptance: CheckedContinuation<SendAcceptance, Error>?
        bridge.sendHandler = { bot, session, text, _ in
            precondition(bot == "beta" && session.isEmpty && text == "Brouillon Beta")
            return try await withCheckedThrowingContinuation { acceptance = $0 }
        }
        store.send()
        store.send()
        await waitUntil("pending acceptance") { acceptance != nil }
        precondition(store.draft == "Brouillon Beta" && bridge.sendCalls == 1)
        store.draft = "Modifié pendant l’envoi"
        acceptance?.resume(returning: SendAcceptance(accepted: true, nonce: "nonce-1"))
        await waitUntil("accepted") { !store.isSending }
        precondition(store.draft == "Modifié pendant l’envoi")

        // A successful acknowledgement clears only the draft that was submitted.
        bridge.sendHandler = { _, _, _, _ in SendAcceptance(accepted: true, nonce: "nonce-2") }
        store.send()
        await waitUntil("successful clear") { !store.isSending && store.draft.isEmpty }

        // Ambiguous failure retains the text and does not auto-retry the POST.
        bridge.sendHandler = { _, _, _, _ in throw URLError(.timedOut) }
        store.draft = "Conserver si délai dépassé"
        let beforeFailure = bridge.sendCalls
        store.send()
        await waitUntil("failed send") { !store.isSending && store.notice != nil }
        precondition(store.draft == "Conserver si délai dépassé" && bridge.sendCalls == beforeFailure + 1)
        try await Task.sleep(for: .milliseconds(30))
        precondition(bridge.sendCalls == beforeFailure + 1)

        store.loadOlder()
        await waitUntil("older page") { !store.isLoadingOlder && !store.hasOlder }
        precondition(store.messages.first?.text == "beta::true")

        // A response received after deactivation cannot reconnect or mutate the view.
        var finalReply: CheckedContinuation<BridgeSnapshot, Never>?
        bridge.stateHandler = { _, _ in await withCheckedContinuation { finalReply = $0 } }
        store.refreshNow()
        await waitUntil("read before shutdown") { finalReply != nil }
        let messagesBeforeShutdown = store.messages
        store.shutdown()
        finalReply?.resume(returning: fixture(botID: "alpha"))
        await Task.yield()
        precondition(!store.isConnected && store.messages == messagesBeforeShutdown)
        print("PASS: notification baseline/dedup/streaming/late-text/echo/visible-chat, live data, stale-response isolation, per-session drafts, acceptance, no automatic POST retry, pagination, shutdown")
    }
}
