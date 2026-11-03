import AppKit
import Combine
import DroppyKit
import SwiftUI

@objc(GrokNotchPrincipal)
public final class GrokNotchPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { GrokNotchDroplet() }
}

@MainActor
public final class GrokNotchDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "grok-notch"
    let store = ChatStore()
    #if DEBUG
    private var previewTask: Task<Void, Never>?
    #endif
    private var host: DropletHost?
    private var noticeTask: Task<Void, Never>?
    private var pendingNotices: [BotNotice] = []
    private var presentedNotice: BotNotice?
    private var activitySignature: String?
    private let activity = CurrentValueSubject<LiveActivityState?, Never>(nil)

    public func activate(host: DropletHost) throws {
        self.host = host
        store.onPresentationChange = { [weak self] in self?.publishActivity() }
        store.onIncomingMessage = { [weak self] event in self?.presentNotice(event) }
        store.messageNotificationsEnabled = notificationsEnabled
        store.start()
        host.shortcuts.register(id: "open-chat", title: "Ouvrir Grok Bot dans la notch", defaultShortcut: nil) { [weak self] in
            self?.openTeam()
        }
        host.log.info("Grok Notch activated with the authenticated local Grok Bot bridge")
    }
    public func deactivate() {
        #if DEBUG
        previewTask?.cancel(); previewTask = nil
        #endif
        clearNotices()
        store.shutdown()
        host?.shortcuts.unregister(id: "open-chat")
        host?.notchSurface.dismissExpandedSurface("chat")
        host?.shelf.setHoldsOpen(false)
        activitySignature = nil
        activity.send(nil)
        host = nil
    }
    #if DEBUG
    public func prepareMessagePreviewForHarness() {
        previewTask = Task { [weak self] in
            for _ in 0..<50 {
                guard let self, !Task.isCancelled else { return }
                if self.store.isConnected {
                    self.store.stageMessagePreviewForHarness()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
    #endif
    var notificationsEnabled: Bool { host?.preferences.value(forKey: "notch-notifications", default: true) ?? true }
    var notificationsBinding: Binding<Bool> {
        Binding(get: { self.notificationsEnabled }, set: {
            self.host?.preferences.setValue($0, forKey: "notch-notifications")
            self.store.messageNotificationsEnabled = $0
            if !$0 { self.clearNotices(); self.store.clearMessageActivity() }
            self.publishActivity()
        })
    }
    func openChat(botID: String? = nil) {
        if let botID {
            guard store.bots.contains(where: { $0.id == botID }) else { return }
            store.chooseBot(id: botID)
        }
        store.showsTeamDirectory = false
        let openedBot = botID ?? store.selectedBotID
        pendingNotices.removeAll { $0.bot.id == openedBot }
        if presentedNotice?.bot.id == openedBot {
            presentedNotice = nil
            host?.hud.dismiss(id: "grok-notch.message")
        }
        if host?.notchSurface.presentExpandedSurface(.init(surfaceID: "chat")) == nil {
            store.notice = "Cette surface n’est pas disponible dans cet hôte."
        } else {
            store.conversationVisibility(true)
            host?.log.info("Grok Notch direct chat presentation accepted")
        }
    }
    func openTeam() {
        store.showsTeamDirectory = true
        store.conversationVisibility(false)
        _ = host?.notchSurface.presentExpandedSurface(.init(surfaceID: "chat"))
    }
    func closeChat() {
        store.conversationVisibility(false)
        host?.notchSurface.dismissExpandedSurface("chat")
    }
    func openActivity() {
        if let bot = store.activityBot { openChat(botID: bot.id) }
        else { openTeam() }
    }
    private func publishActivity() {
        guard store.isConnected, let bot = store.activityBot else {
            if activitySignature != nil { activitySignature = nil; activity.send(nil) }
            return
        }
        let preview = store.activityPreview
        let signature = bot.id + ":" + preview
        guard activitySignature != signature else { return }
        activitySignature = signature
        activity.send(LiveActivityState(priority: 150, accessibilityTitle: "\(bot.name) : \(preview)",
            isInteractive: true, joinsPersistentActivitySet: true,
            compactPresentation: CompactLiveActivityPresentationMetadata(id: "grok-notch.\(bot.id)",
                accessibilityLabel: bot.name, accessibilityValue: preview), expandedWidgetID: "grok-notch"))
    }
    private func clearNotices() {
        noticeTask?.cancel(); noticeTask = nil
        pendingNotices.removeAll(); presentedNotice = nil
        host?.hud.dismiss(id: "grok-notch.message")
    }
    private func presentNotice(_ event: BotNotice) {
        guard notificationsEnabled else { return }
        // One pending preview per bot, preserving other bots in a short burst.
        pendingNotices.removeAll { $0.bot.id == event.bot.id }
        pendingNotices.append(event)
        if pendingNotices.count > 8 { pendingNotices.removeFirst() }
        guard noticeTask == nil else { return }
        noticeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingNotices.isEmpty {
                let event = self.pendingNotices.removeFirst()
                guard Date().timeIntervalSince(event.receivedAt) < 30 else { continue }
                var accepted = false
                for attempt in 0..<5 {
                    guard !Task.isCancelled, self.notificationsEnabled else { return }
                    if self.store.chatIsVisible && !self.store.showsTeamDirectory && self.store.selectedBotID == event.bot.id { break }
                    if self.showNotice(event) { accepted = true; break }
                    if attempt < 4 {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    }
                }
                if accepted {
                    for _ in 0..<7 {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        if self.presentedNotice?.id != event.id { break }
                    }
                    if self.presentedNotice?.id == event.id { self.presentedNotice = nil }
                }
            }
            self.noticeTask = nil
        }
    }
    private func showNotice(_ event: BotNotice) -> Bool {
        guard let host else { return false }
        let bot = event.bot
        let request = DropletHUDRequest(id: "grok-notch.message", duration: 7,
            priority: .normal, accessibilityLabel: "\(bot.name) : \(event.preview)",
            isExpanded: true, expandedContentHeight: 64) {
                HStack(spacing: 0) {
                    BotAvatar(bot: bot, size: 20)
                    Spacer(minLength: 0)
                    Text("Message").font(.system(size: 10, weight: .medium))
                }.foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            } expanded: { [weak self] in
                if let self {
                    GrokMessageNotice(event: event, store: self.store,
                        open: { [weak self] in self?.openChat(botID: bot.id) },
                        dismiss: { [weak self] in self?.dismissNotice(botID: bot.id) })
                }
            }
        let accepted = host.hud.present(request)
        if accepted { presentedNotice = event }
        host.log.info("Grok Notch new-message preview accepted=\(accepted)")
        return accepted
    }
    private func dismissNotice(botID: String) {
        host?.hud.dismiss(id: "grok-notch.message")
        presentedNotice = nil
        pendingNotices.removeAll { $0.bot.id == botID }
        store.acknowledgeActivity(botID: botID)
    }
    func openGrokBot() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand"), host?.workspace.open(url) == true else {
            store.notice = "Impossible d’ouvrir Grok Bot depuis cet hôte."
            return
        }
    }
    func openShortcuts() { _ = host?.workspace.openShortcuts() }
}

extension GrokNotchDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: "grok-notch", title: "Grok Bot", systemImage: "bubble.left.and.bubble.right",
            layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 210, contentHeight: .fixed(280)),
            focusPolicy: .keyboardFocusable,
            searchKeywords: ["grok", "bot", "chat"])]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        guard id == "grok-notch" else { return AnyView(EmptyView()) }
        return AnyView(GrokWidget(droplet: self, store: store, context: context).environment(\.colorScheme, .dark))
    }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension GrokNotchDroplet: ExpandedSurfaceHosting, ExpandedSurfaceProviding {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [.init(id: "chat", title: "Grok Bot", systemImage: "bubble.left.and.bubble.right",
               suppresses: [.shelfWidgets, .favoritesBar, .floatingNavLane, .autoCollapse])]
    }
    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == "chat" else { return AnyView(EmptyView()) }
        return AnyView(GrokSurface(droplet: self, store: store).environment(\.colorScheme, .dark))
    }
    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        CGSize(width: min(480, proposal.maximumSize.width), height: min(440, proposal.maximumSize.height))
    }
    public func expandedSurfaceDidDismiss(_ id: ExpandedSurfaceID, presentation: ExpandedSurfacePresentation,
                                         reason: ExpandedSurfaceDismissalReason) {
        if host?.notchSurface.expandedState.current == nil { store.conversationVisibility(false) }
    }

}

extension GrokNotchDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> { activity.eraseToAnyPublisher() }
    public func makeCompactLeading() -> AnyView { AnyView(GrokActivityWing(droplet: self, store: store, leading: true)) }
    public func makeCompactTrailing() -> AnyView { AnyView(GrokActivityWing(droplet: self, store: store, leading: false)) }
    public func makeExpanded(context: LiveActivityContext) -> AnyView { AnyView(EmptyView()) }
    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView { makeCompactLeading() }
    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { makeCompactTrailing() }
}

extension GrokNotchDroplet: HUDPresenting {}

extension GrokNotchDroplet: DropletURLHandling {
    public func handle(_ request: DropletURLRequest) {
        if request.path == "close" { closeChat(); return }
        guard request.path == "chat", let id = request.query["botId"], id.count <= 100,
              store.bots.contains(where: { $0.id == id }) else { return }
        openChat(botID: id)
    }
}

private struct GrokActivityWing: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    let leading: Bool
    var body: some View {
        Button { droplet.openActivity() } label: {
            HStack(spacing: DroppySpacing.xsm) {
                if leading {
                    BotAvatar(bot: store.activityBot, size: 22)
                    Text(store.activityBot?.name ?? "Grok Bot").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                } else {
                    Text(store.activityPreview).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Image(systemName: store.latestNotice == nil ? "ellipsis" : "bubble.left.fill")
                        .font(.system(size: 10))
                }
            }.foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: leading ? .leading : .trailing)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Ouvrir \(store.activityBot?.name ?? "Grok Bot") dans la notch")
    }
}

extension GrokNotchDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView { AnyView(GrokSettings(droplet: self, store: store).environment(\.colorScheme, .dark)) }
    public var settingsSearchEntries: [SettingsSearchEntry] {
        [.init(title: "Grok Bot", keywords: ["grok", "bots", "connexion", "chat"])]
    }
}

private struct GrokSettings: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletControlRow(title: "Connexion", infoTip: store.connectionError ?? "Vos bots et vos conversations sont synchronisés avec l’application Grok Bot.") {
                    DropletValuePill(text: store.isConnected ? "Connecté" : "Hors ligne")
                }
                DropletControlRow(title: "Votre équipe", infoTip: "La liste provient de votre compte Grok Bot.") {
                    DropletValuePill(text: "\(store.bots.count) bots")
                }
                DropletControlRow(title: "Reconnecter", infoTip: "L’application Grok Bot doit rester ouverte pour la synchronisation.") {
                    Button(store.isConnecting ? "Connexion…" : "Reconnecter") { store.reconnect() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(store.isConnecting)
                }
                DropletControlRow(title: "Application Grok Bot", infoTip: "Ouvrir l’application pour examiner les tâches et valider les demandes de vos bots.") {
                    Button("Ouvrir") { droplet.openGrokBot() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            DropletSettingsCard {
                DropletToggleRow(title: "Notifications dans la notch",
                    subtitle: "Un aperçu cliquable à chaque nouveau message. Aucun rappel des anciens messages au démarrage.",
                    isOn: droplet.notificationsBinding)
                DropletControlRow(title: "Raccourci global", infoTip: "Choisissez votre raccourci dans Droppy.") {
                    Button("Configurer") { droplet.openShortcuts() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                DropletControlRow(title: "Conversations", infoTip: "L’historique appartient à votre compte Grok Bot. Aucune copie des conversations n’est enregistrée dans les préférences Droppy.") {
                    DropletValuePill(text: "Grok Bot")
                }
            }
        }
    }
}
