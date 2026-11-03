import Combine
import Foundation

struct Bot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String
    let symbol: String
    let isRunning: Bool
    let awaitingApproval: Bool
    var avatarDataURL: String? = nil
    var avatarNeedsContrast: Bool? = nil
    var preview: String? = nil
    var lastMessageID: String? = nil
    var lastActivityAt: Double? = nil
    var hasUnread: Bool? = nil
    var unreadCount: Int? = nil
    var lastMessageIsUser: Bool? = nil
    var lastMessageIsStreaming: Bool? = nil

    var previewText: String { preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

struct BotNotice: Identifiable, Equatable, Sendable {
    let id: String
    let bot: Bot
    let preview: String
    let receivedAt: Date
}

/// Polling changes are reduced to message identities, never to streaming text chunks.
struct BotUpdateTracker {
    private struct Pending { let identity: String; let startedAt: Date }
    private var baseline = false
    private var seen: [String: String] = [:]
    private var pending: [String: Pending] = [:]
    private var outgoing: [String: (text: String, expiry: Date)] = [:]

    mutating func noteOutgoing(botID: String, text: String, now: Date = Date()) {
        outgoing[botID] = (text, now.addingTimeInterval(45))
    }
    mutating func ingest(_ bots: [Bot], visibleBotID: String?, now: Date = Date()) -> [BotNotice] {
        let first = !baseline
        baseline = true
        var notices: [BotNotice] = []
        let active = Set(bots.map(\.id))
        seen = seen.filter { active.contains($0.key) }
        pending = pending.filter { active.contains($0.key) }
        outgoing = outgoing.filter { $0.value.expiry > now }
        for bot in bots {
            let identity = bot.lastMessageID ?? ""
            let preview = bot.previewText
            let prior = seen.updateValue(identity, forKey: bot.id)
            if !first, let prior, !identity.isEmpty, identity != prior {
                pending[bot.id] = Pending(identity: identity, startedAt: now)
            }
            guard let update = pending[bot.id], update.identity == identity else { continue }
            if bot.lastMessageIsUser == true || visibleBotID == bot.id {
                pending[bot.id] = nil
                continue
            }
            if let echo = outgoing[bot.id] {
                let normalized = preview.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty && (echo.text == preview || echo.text.hasPrefix(normalized)) {
                    outgoing[bot.id] = nil
                    pending[bot.id] = nil
                    continue
                }
            }
            // A roster ID can arrive before its text; keep it pending rather than
            // consuming the notification. Streaming gets a brief grace period.
            guard !preview.isEmpty else { continue }
            if (bot.lastMessageIsStreaming == true || bot.isRunning), now.timeIntervalSince(update.startedAt) < 4 { continue }
            pending[bot.id] = nil
            notices.append(BotNotice(id: bot.id + ":" + identity, bot: bot, preview: preview, receivedAt: now))
        }
        return notices.sorted { ($0.bot.lastActivityAt ?? 0) < ($1.bot.lastActivityAt ?? 0) }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let isUser: Bool
    let text: String
    let isStreaming: Bool
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let botID: String
    let title: String
}

struct BridgeSnapshot: Codable, Sendable {
    let connected: Bool
    let bots: [Bot]
    let selectedBotId: String
    let selectedSessionId: String
    let messages: [ChatMessage]
    let sessions: [Conversation]
    let hasOlder: Bool
}

struct SendAcceptance: Codable, Sendable {
    let accepted: Bool
    let nonce: String
}

@MainActor protocol GrokBridgeTransport {
    func state(botID: String?, sessionID: String?) async throws -> BridgeSnapshot
    func connect() async throws
    func older(botID: String, sessionID: String) async throws -> BridgeSnapshot
    func send(botID: String, sessionID: String, text: String, requestID: UUID) async throws -> SendAcceptance
}

private struct BridgeConnection: Decodable {
    let port: Int
    let token: String
}

private struct BridgeErrorBody: Decodable { let error: String }
private struct ConnectedReply: Decodable { let connected: Bool }
private struct OlderBody: Encodable { let botId: String; let sessionId: String }
private struct SendBody: Encodable {
    let botId: String
    let sessionId: String
    let text: String
    let requestId: String
}

enum BridgeFailure: LocalizedError {
    case unavailable
    case invalidConfiguration
    case disconnected
    case rejected(String)
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .unavailable: "Le bridge Grok Bot n’est pas disponible sur ce Mac."
        case .invalidConfiguration: "La connexion locale au bridge doit être reconfigurée."
        case .disconnected: "Grok Bot n’est pas connecté. Ouvrez l’application, puis reconnectez le Droplet."
        case .rejected(let message): message
        case .invalidReply: "Le bridge a renvoyé une réponse inattendue."
        }
    }
}

private final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The only network destination is the authenticated bridge on IPv4 loopback.
/// Grok Bot retains ownership of the account session and conversation storage.
@MainActor final class LoopbackBridgeClient: GrokBridgeTransport {
    private let connectionURL: URL
    private let session: URLSession

    init(connectionURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Notch Bridge/connection.json")) {
        self.connectionURL = connectionURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
    }

    func state(botID: String?, sessionID: String?) async throws -> BridgeSnapshot {
        var query: [URLQueryItem] = []
        if let botID { query.append(URLQueryItem(name: "botId", value: botID)) }
        if let sessionID { query.append(URLQueryItem(name: "sessionId", value: sessionID)) }
        return try await request(path: "/v1/state", query: query, timeout: 12)
    }

    func connect() async throws {
        let reply: ConnectedReply = try await request(path: "/v1/connect", method: "POST", timeout: 60)
        guard reply.connected else { throw BridgeFailure.disconnected }
    }

    func older(botID: String, sessionID: String) async throws -> BridgeSnapshot {
        let body = try JSONEncoder().encode(OlderBody(botId: botID, sessionId: sessionID))
        return try await request(path: "/v1/older", method: "POST", body: body, timeout: 20)
    }

    func send(botID: String, sessionID: String, text: String, requestID: UUID) async throws -> SendAcceptance {
        let body = try JSONEncoder().encode(SendBody(botId: botID, sessionId: sessionID,
            text: text, requestId: requestID.uuidString))
        return try await request(path: "/v1/send", method: "POST", body: body, timeout: 45)
    }

    private func request<T: Decodable>(path: String, method: String = "GET", query: [URLQueryItem] = [],
                                       body: Data? = nil, timeout: TimeInterval) async throws -> T {
        let connection: BridgeConnection
        do { connection = try JSONDecoder().decode(BridgeConnection.self, from: Data(contentsOf: connectionURL)) }
        catch { throw BridgeFailure.unavailable }
        guard (1...65535).contains(connection.port), !connection.token.isEmpty else {
            throw BridgeFailure.invalidConfiguration
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = connection.port
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BridgeFailure.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BridgeFailure.invalidReply }
        guard (200...299).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(BridgeErrorBody.self, from: data)
            throw BridgeFailure.rejected(error?.error ?? "Connexion au bridge refusée (\(response.statusCode)).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw BridgeFailure.invalidReply }
    }
}

/// Real account data only. Drafts live in memory; no chat copies are persisted in Droppy.
@MainActor final class ChatStore: ObservableObject {
    private struct DraftKey: Hashable { let botID: String; let sessionID: String }
    @Published private(set) var bots: [Bot] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var selectedBotID = ""
    @Published private(set) var selectedSessionID = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasOlder = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var connectionError: String?
    @Published var showsHistory = false
    @Published var notice: String?
    @Published private var draftRevision = 0
    var onActivity: ((Bool) -> Void)?
    var onPresentationChange: (() -> Void)?
    var messageNotificationsEnabled = true
    var onIncomingMessage: ((BotNotice) -> Void)?
    @Published private(set) var latestNotice: BotNotice?
    @Published var showsTeamDirectory = false
    @Published private(set) var chatIsVisible = false
    private var updates = BotUpdateTracker()
    private var sendingBotID: String?
    private var waitingForReply: [String: Date] = [:]

    var sortedBots: [Bot] {
        bots.sorted { a, b in
            if a.hasUnread != b.hasUnread { return a.hasUnread == true }
            return (a.lastActivityAt ?? 0) > (b.lastActivityAt ?? 0)
        }
    }
    var activityBot: Bot? {
        if let id = sendingBotID, let bot = bots.first(where: { $0.id == id }) { return bot }
        if let latestNotice, let bot = bots.first(where: { $0.id == latestNotice.bot.id }) { return bot }
        if let bot = sortedBots.first(where: { ($0.awaitingApproval || $0.isRunning) && !(chatIsVisible && !showsTeamDirectory && $0.id == selectedBotID) }) { return bot }
        return sortedBots.first { waitingForReply[$0.id] != nil }
    }
    var activityPreview: String {
        guard let bot = activityBot else { return "" }
        if sendingBotID == bot.id { return "Envoi du message…" }
        if let latestNotice, latestNotice.bot.id == bot.id { return latestNotice.preview }
        if bot.awaitingApproval { return "Une validation est demandée" }
        return "Prépare une réponse…"
    }
    func conversationVisibility(_ visible: Bool) {
        chatIsVisible = visible
        if visible { acknowledgeActivity(botID: selectedBotID) }
    }
    func acknowledgeActivity(botID: String) {
        if latestNotice?.bot.id == botID { latestNotice = nil }
        onPresentationChange?()
    }
    func clearMessageActivity() { latestNotice = nil; onPresentationChange?() }
    func chooseBot(id: String) {
        guard let chosen = bots.first(where: { $0.id == id }) else { return }
        select(chosen)
        showsTeamDirectory = false
        acknowledgeActivity(botID: id)
    }

    private let transport: any GrokBridgeTransport
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var drafts: [DraftKey: String] = [:]
    private var active = false
    private var lifecycle = 0
    private var selectionGeneration = 0
    private var nextRead = 0
    private var lastAppliedRead = 0

    init(transport: (any GrokBridgeTransport)? = nil, pollInterval: Duration = .seconds(2)) {
        self.transport = transport ?? LoopbackBridgeClient()
        self.pollInterval = pollInterval
    }

    var bot: Bot? { bots.first { $0.id == selectedBotID } }
    var isWorking: Bool { isConnected && bot?.isRunning == true }
    var awaitingApproval: Bool { isConnected && bot?.awaitingApproval == true }
    var runningBotCount: Int { isConnected ? bots.filter(\.isRunning).count : 0 }
    var history: [Conversation] { conversations.filter { $0.botID == selectedBotID } }
    var selectionIdentity: String { "\(selectedBotID)\u{0}\(selectedSessionID)" }
    var canSend: Bool {
        isConnected && !selectedBotID.isEmpty && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= 8000
    }
    var draft: String {
        get { _ = draftRevision; return drafts[currentKey] ?? "" }
        set { guard !selectedBotID.isEmpty else { return }; drafts[currentKey] = newValue; draftRevision += 1 }
    }
    private var currentKey: DraftKey { DraftKey(botID: selectedBotID, sessionID: selectedSessionID) }

    #if DEBUG
    func stageMessagePreviewForHarness() {
        guard let bot = bots.first(where: { $0.avatarNeedsContrast == true && !$0.previewText.isEmpty }) ?? bots.first(where: { !$0.previewText.isEmpty }) else { return }
        let event = BotNotice(id: "harness-preview-" + bot.id, bot: bot, preview: bot.previewText, receivedAt: Date())
        latestNotice = event
        onIncomingMessage?(event)
        onPresentationChange?()
    }
    #endif

    func start() {
        guard !active else { return }
        active = true
        lifecycle += 1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.refresh()
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
            }
        }
    }

    func select(_ bot: Bot) {
        guard selectedBotID != bot.id else { return }
        selectedBotID = bot.id
        selectedSessionID = ""
        changeSelection()
    }

    func selectSession(_ conversation: Conversation) {
        guard conversation.botID == selectedBotID else { return }
        selectedSessionID = conversation.id
        changeSelection()
    }

    private func changeSelection() {
        selectionGeneration += 1
        messages = []
        conversations = []
        hasOlder = false
        olderTask?.cancel(); olderTask = nil
        isLoadingOlder = false
        showsHistory = false
        acknowledgeActivity(botID: selectedBotID)
        draftRevision += 1
        refreshNow()
    }

    func refreshNow() {
        guard active else { return }
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in await self?.refresh() }
    }

    func reconnect() {
        guard active, !isConnecting else { return }
        let life = lifecycle
        isConnecting = true
        connectionError = nil
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.connect()
                guard !Task.isCancelled, self.active, life == self.lifecycle else { return }
                self.isConnecting = false
                await self.refresh()
            } catch {
                guard !Task.isCancelled, self.active, life == self.lifecycle else { return }
                self.isConnecting = false
                self.disconnect(error)
            }
            self.connectTask = nil
        }
    }

    func refresh() async {
        guard active, !Task.isCancelled else { return }
        let life = lifecycle
        let generation = selectionGeneration
        nextRead += 1
        let read = nextRead
        if bots.isEmpty || messages.isEmpty { isLoading = true }
        do {
            let snapshot = try await transport.state(botID: selectedBotID.isEmpty ? nil : selectedBotID,
                sessionID: selectedBotID.isEmpty ? nil : selectedSessionID)
            guard !Task.isCancelled, active, life == lifecycle, generation == selectionGeneration,
                  read >= lastAppliedRead else { return }
            guard snapshot.connected else { throw BridgeFailure.disconnected }
            lastAppliedRead = read
            if let last = snapshot.messages.last, !last.isUser, last.id != messages.last?.id {
                waitingForReply[snapshot.selectedBotId] = nil
            }
            if let current = latestNotice,
               let updatedBot = snapshot.bots.first(where: { $0.id == current.bot.id }),
               current.id == updatedBot.id + ":" + (updatedBot.lastMessageID ?? ""),
               !updatedBot.previewText.isEmpty {
                latestNotice = BotNotice(id: current.id, bot: updatedBot, preview: updatedBot.previewText, receivedAt: current.receivedAt)
            }
            let incoming = updates.ingest(snapshot.bots, visibleBotID: chatIsVisible && !showsTeamDirectory ? selectedBotID : nil)
            for event in incoming where messageNotificationsEnabled {
                latestNotice = event
                waitingForReply[event.bot.id] = nil
                onIncomingMessage?(event)
            }
            if let latestNotice, Date().timeIntervalSince(latestNotice.receivedAt) > 90 { self.latestNotice = nil }
            waitingForReply = waitingForReply.filter { $0.value > Date() }
            bots = snapshot.bots
            selectedBotID = snapshot.selectedBotId
            selectedSessionID = snapshot.selectedSessionId
            messages = snapshot.messages
            conversations = snapshot.sessions
            hasOlder = snapshot.hasOlder
            isConnected = true
            isLoading = false
            connectionError = nil
            onActivity?(runningBotCount > 0)
            onPresentationChange?()
        } catch {
            guard !Task.isCancelled, active, life == lifecycle, generation == selectionGeneration,
                  read >= lastAppliedRead else { return }
            lastAppliedRead = read
            disconnect(error)
        }
    }

    func loadOlder() {
        guard active, isConnected, hasOlder, !isLoadingOlder, !selectedBotID.isEmpty else { return }
        let key = currentKey
        let life = lifecycle
        let generation = selectionGeneration
        nextRead += 1
        let read = nextRead
        isLoadingOlder = true
        olderTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.transport.older(botID: key.botID, sessionID: key.sessionID)
                guard !Task.isCancelled, self.active, life == self.lifecycle,
                      generation == self.selectionGeneration else { return }
                guard snapshot.connected else { throw BridgeFailure.disconnected }
                self.isLoadingOlder = false
                if read >= self.lastAppliedRead {
                    self.lastAppliedRead = read
                    self.messages = snapshot.messages
                    self.conversations = snapshot.sessions
                    self.hasOlder = snapshot.hasOlder
                }
            } catch {
                guard !Task.isCancelled, self.active, life == self.lifecycle,
                      generation == self.selectionGeneration else { return }
                self.isLoadingOlder = false
                self.notice = "Impossible de charger les messages précédents. \(error.localizedDescription)"
            }
            self.olderTask = nil
        }
    }

    func send() {
        guard canSend else { return }
        let key = currentKey
        let originalDraft = draft
        let input = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let life = lifecycle
        let requestID = UUID()
        isSending = true
        sendingBotID = key.botID
        updates.noteOutgoing(botID: key.botID, text: input)
        waitingForReply[key.botID] = Date().addingTimeInterval(45)
        latestNotice = nil
        onPresentationChange?()
        notice = nil
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accepted = try await self.transport.send(botID: key.botID, sessionID: key.sessionID,
                    text: input, requestID: requestID)
                guard !Task.isCancelled, self.active, life == self.lifecycle else { return }
                guard accepted.accepted else { throw BridgeFailure.rejected("Grok Bot n’a pas accepté le message.") }
                if self.drafts[key] == originalDraft {
                    self.drafts[key] = ""
                    self.draftRevision += 1
                }
                self.isSending = false
                self.sendingBotID = nil
                self.onPresentationChange?()
                await self.refresh()
            } catch {
                guard !Task.isCancelled, self.active, life == self.lifecycle else { return }
                self.isSending = false
                self.sendingBotID = nil
                self.waitingForReply[key.botID] = nil
                self.onPresentationChange?()
                self.notice = "Envoi non confirmé. Vérifiez Grok Bot avant de réessayer. \(error.localizedDescription)"
            }
            self.sendTask = nil
        }
    }

    func shutdown() {
        active = false
        lifecycle += 1
        selectionGeneration += 1
        pollTask?.cancel(); pollTask = nil
        selectionTask?.cancel(); selectionTask = nil
        sendTask?.cancel(); sendTask = nil
        connectTask?.cancel(); connectTask = nil
        olderTask?.cancel(); olderTask = nil
        isLoadingOlder = false
        isConnected = false
        isSending = false
        isConnecting = false
        isLoading = false
        onActivity?(false)
        onActivity = nil
        onIncomingMessage = nil
        onPresentationChange = nil
        latestNotice = nil
        sendingBotID = nil
        waitingForReply = [:]
        updates = BotUpdateTracker()
    }

    private func disconnect(_ error: Error) {
        isConnected = false
        isLoading = false
        connectionError = error.localizedDescription
        onActivity?(false)
        onPresentationChange?()
    }
}
