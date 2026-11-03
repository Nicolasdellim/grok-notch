import AppKit
import DroppyKit
import SwiftUI

private enum Ink {
    static let primary = AdaptiveColors.notchSurfacePrimaryText
    static let secondary = AdaptiveColors.notchSurfaceSecondaryText
    static let tertiary = AdaptiveColors.notchSurfaceTertiaryText
    static let fill = AdaptiveColors.notchSurfaceCardFill
}

@MainActor private enum GrokBrand {
    static let image: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()
}

struct BotGlyph: View {
    var body: some View {
        Group {
            if let image = GrokBrand.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "bubble.left.and.bubble.right").resizable().scaledToFit()
            }
        }.accessibilityHidden(true)
    }
}

@MainActor private enum AvatarCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 120; return cache
    }()
    static func image(_ source: String?) -> NSImage? {
        guard let source, source.count < 300_000,
              source.hasPrefix("data:image/png;base64,"), let comma = source.firstIndex(of: ",") else { return nil }
        let key = source as NSString
        if let image = images.object(forKey: key) { return image }
        guard let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

struct BotAvatar: View {
    let bot: Bot?
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let image = AvatarCache.image(bot?.avatarDataURL) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { BotGlyph() }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BotRow: View {
    let bot: Bot
    var compact = false
    var selected = false
    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            BotAvatar(bot: bot, size: compact ? 28 : 34)
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(bot.name).font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(Ink.primary).lineLimit(1)
                Text(bot.awaitingApproval ? "À valider dans Grok Bot" : bot.previewText.isEmpty
                     ? (bot.isRunning ? "Prépare une réponse…" : "Ouvrir la conversation")
                     : bot.previewText.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: compact ? 10 : 11)).foregroundStyle(Ink.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if bot.isRunning { ProgressView().controlSize(.mini) }
            else if bot.hasUnread == true { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            else if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.tertiary) }
        }.frame(maxWidth: .infinity, minHeight: compact ? 36 : 40, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBadge: View {
    @ObservedObject var store: ChatStore
    var body: some View {
        Text(store.isConnected ? "Connecté" : store.isConnecting ? "Connexion…" : "Hors ligne")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, DroppySpacing.sm).padding(.vertical, DroppySpacing.xs)
            .background(Ink.fill, in: Capsule())
    }
}

/// A searchable picker instead of squeezing a whole team into horizontal tabs.
private struct BotPicker: View {
    @ObservedObject var store: ChatStore
    @State private var isPresented = false
    @State private var search = ""
    private var results: [Bot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.bots : store.bots.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: DroppySpacing.sm) {
                Image(systemName: store.bot.flatMap { $0.symbol.isEmpty ? nil : $0.symbol } ?? "person.crop.circle")
                Text(store.bot?.name ?? "Votre équipe").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(store.bots.count) bots").foregroundStyle(Ink.tertiary).monospacedDigit()
            }.font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
        }
        .buttonStyle(DroppyGlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))))
        .disabled(store.bots.isEmpty)
        .accessibilityLabel("Choisir un bot dans votre équipe")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                TextField("Rechercher un bot…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(DroppySpacing.smd)
                    .background(Ink.fill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DroppySpacing.sm) {
                        ForEach(results) { bot in
                            Button { store.chooseBot(id: bot.id); isPresented = false } label: {
                                BotRow(bot: bot, selected: bot.id == store.selectedBotID)
                            }
                            .buttonStyle(DroppyGlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))))
                            .accessibilityAddTraits(bot.id == store.selectedBotID ? .isSelected : [])
                        }
                        if results.isEmpty {
                            Text("Aucun bot ne correspond.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                    }
                }.scrollIndicators(.hidden).frame(maxHeight: 280)
            }
            .padding(DroppySpacing.md).frame(width: 300)
            .foregroundStyle(Ink.primary).preferredColorScheme(.dark)
        }
    }
}

struct GrokWidget: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    let context: ShelfWidgetContext
    @State private var search = ""
    private var filtered: [Bot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.sortedBots : store.sortedBots.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Text("Vos bots").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(store.bots.count)").font(.system(size: 11)).monospacedDigit()
                Button { droplet.openGrokBot() } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20)).help("Ouvrir Grok Bot")
                    .accessibilityLabel("Ouvrir Grok Bot, l’application")
            }.foregroundStyle(Ink.secondary)
            if !context.isCompact {
                TextField("Rechercher un bot…", text: $search).textFieldStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Ink.primary)
                    .padding(DroppySpacing.sm)
                    .background(Ink.fill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
            }
            if store.isConnected {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DroppySpacing.xs) {
                        ForEach(filtered) { bot in
                            Button { droplet.openChat(botID: bot.id) } label: {
                                BotRow(bot: bot, compact: context.isCompact)
                            }.buttonStyle(DroppyGlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))))
                        }
                        if filtered.isEmpty { Text("Aucun bot trouvé").font(.system(size: 12)).foregroundStyle(Ink.secondary) }
                    }.droppyFlatGlassControls()
                }.scrollIndicators(.hidden)
            } else {
                Text(store.connectionError ?? "Connexion à vos bots…").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                Button("Reconnecter Grok Bot") { store.reconnect() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            if context.isCompact {
                Button("Tous mes bots") { droplet.openTeam() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GrokSurface: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    var body: some View {
        Group {
            if store.showsTeamDirectory { GrokTeamDirectory(droplet: droplet, store: store) }
            else { GrokChat(droplet: droplet, store: store) }
        }
    }
}

private struct GrokTeamDirectory: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    @State private var search = ""
    private var filtered: [Bot] {
        search.isEmpty ? store.sortedBots : store.sortedBots.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack {
                Text("Votre équipe").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                ConnectionBadge(store: store)
                Button { droplet.closeChat() } label: { Image(systemName: "xmark") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24)).accessibilityLabel("Fermer")
            }
            TextField("Rechercher parmi vos \(store.bots.count) bots…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 13)).padding(DroppySpacing.md)
                .background(Ink.fill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    ForEach(filtered) { bot in
                        Button { droplet.openChat(botID: bot.id) } label: { BotRow(bot: bot) }
                            .buttonStyle(DroppyGlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))))
                    }
                }.droppyFlatGlassControls()
            }.scrollIndicators(.hidden)
            Button("Ouvrir Grok Bot") { droplet.openGrokBot() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
        }.padding(DroppySpacing.md).foregroundStyle(Ink.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GrokChat: View {
    let droplet: GrokNotchDroplet
    @ObservedObject var store: ChatStore
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            header
            if store.awaitingApproval { approval }
            if store.showsHistory { history } else { transcript }
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Fermer le message")
                }
            }
            composer
        }
        .padding(DroppySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Ink.primary)
        .environment(\.colorScheme, .dark)
        .onAppear { store.conversationVisibility(true) }
        .onDisappear { store.conversationVisibility(false) }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.sm) {
            BotAvatar(bot: store.bot, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.bot?.name ?? "Grok Bot").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(store.isWorking ? "Prépare une réponse…" : "Conversation Grok Bot").font(.system(size: 10)).foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
            Button { droplet.openTeam() } label: { Image(systemName: "person.2") }
                .buttonStyle(DroppyCircleButtonStyle(size: 24)).help("Changer de bot").accessibilityLabel("Choisir un autre bot")
            Button { store.showsHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(DroppyCircleButtonStyle(size: 24)).disabled(!store.isConnected)
                .help("Conversations du bot").accessibilityLabel("Conversations du bot")
            Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Actualiser").accessibilityLabel("Actualiser")
            Button { droplet.closeChat() } label: { Image(systemName: "xmark") }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Fermer le chat").accessibilityLabel("Fermer le chat")
        }
    }

    private var approval: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "hand.raised")
            Text("À valider dans Grok Bot").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Button("Ouvrir") { droplet.openGrokBot() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
        }.foregroundStyle(Ink.secondary)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DroppySpacing.lg) {
                    if !store.isConnected {
                        connectionPanel
                    } else if store.messages.isEmpty {
                        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                            if store.isLoading { ProgressView().controlSize(.small) }
                            Text(store.isLoading ? "Chargement de la conversation…" : "Votre conversation avec \(store.bot?.name ?? "Grok Bot")")
                                .font(.system(size: 16, weight: .medium))
                            if !store.isLoading {
                                Text("Écrivez un message pour commencer.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                            }
                        }.padding(.vertical, DroppySpacing.xl)
                    }
                    if store.hasOlder {
                        Button(store.isLoadingOlder ? "Chargement…" : "Charger les messages précédents") { store.loadOlder() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(store.isLoadingOlder)
                    }
                    ForEach(store.messages) { message in
                        MessageRow(message: message, bot: store.bot)
                    }
                    if store.isWorking && !store.awaitingApproval {
                        HStack(spacing: DroppySpacing.sm) {
                            ProgressView().controlSize(.mini)
                            Text("\(store.bot?.name ?? "Grok Bot") travaille…")
                                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id("end")
                }.padding(.vertical, DroppySpacing.sm)
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.messages.last?.id) {
                withAnimation(reduceMotion ? nil : DroppyAnimation.state) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.text) {
                if store.isWorking || composerFocused { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: store.selectionIdentity) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            Text("Retrouvez vos bots").font(.system(size: 20, weight: .medium))
            Text(store.connectionError ?? "Connexion à Grok Bot en cours…")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            HStack(spacing: DroppySpacing.sm) {
                Button(store.isConnecting ? "Connexion…" : "Reconnecter") { store.reconnect() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(store.isConnecting)
                Button("Ouvrir Grok Bot") { droplet.openGrokBot() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }.padding(.vertical, DroppySpacing.xl)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Conversations · \(store.bot?.name ?? "Grok Bot")")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
            ScrollView {
                VStack(spacing: DroppySpacing.sm) {
                    ForEach(store.history) { conversation in
                        Button { store.selectSession(conversation) } label: {
                            HStack(spacing: DroppySpacing.sm) {
                                Image(systemName: "bubble.left")
                                Text(conversation.title).lineLimit(2)
                                Spacer(minLength: 0)
                                if conversation.id == store.selectedSessionID { Image(systemName: "checkmark") }
                                Image(systemName: "chevron.right").font(.system(size: 10))
                            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(DroppyGlassButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))))
                    }
                    if store.history.isEmpty {
                        Text("Aucune autre conversation disponible.")
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                }
            }.scrollIndicators(.hidden)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var composer: some View {
        VStack(spacing: DroppySpacing.sm) {
            HStack(alignment: .bottom, spacing: DroppySpacing.sm) {
                TextField("Écrire à \(store.bot?.name ?? "Grok Bot")…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .focused($composerFocused).onSubmit { store.send() }
                    .disabled(!store.isConnected || store.selectedBotID.isEmpty)
                    .accessibilityLabel("Message pour \(store.bot?.name ?? "Grok Bot")")
                if store.isSending {
                    ProgressView().controlSize(.mini).frame(width: 28, height: 28)
                        .accessibilityLabel("Envoi à Grok Bot")
                } else {
                    Button { store.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 28)).disabled(!store.canSend)
                        .help("Envoyer à Grok Bot").accessibilityLabel("Envoyer à Grok Bot")
                }
            }
            .padding(DroppySpacing.md)
            .background(Ink.fill, in: RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous))
            HStack {
                Text(store.draft.count > 8000 ? "8 000 caractères maximum" : store.isConnected
                     ? "Conversation synchronisée avec Grok Bot" : "Reconnexion nécessaire")
                    .font(.system(size: 9)).foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
                Button { droplet.openGrokBot() } label: {
                    HStack(spacing: DroppySpacing.xs) { Text("Ouvrir Grok Bot"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 10))
                }.buttonStyle(DroppyQuietButtonStyle(size: .small)).help("Ouvrir l’application Grok Bot")
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let bot: Bot?
    private var renderedText: AttributedString {
        if message.isUser { return AttributedString(message.text) }
        return (try? AttributedString(markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)
    }
    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            if message.isUser { Spacer(minLength: DroppySpacing.huge) }
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                if !message.isUser {
                    HStack(spacing: DroppySpacing.xsm) {
                        BotAvatar(bot: bot, size: 16)
                        Text(bot?.name ?? "Grok Bot").font(.system(size: 11, weight: .semibold))
                        if message.isStreaming { Text("En cours").font(.system(size: 9)).foregroundStyle(Ink.tertiary) }
                    }
                }
                Text(renderedText).font(.system(size: 13)).lineSpacing(3)
                    .foregroundStyle(message.isUser ? Ink.primary : Ink.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(message.isUser ? DroppySpacing.md : 0)
            .background {
                if message.isUser { RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous).fill(Ink.fill) }
            }
            if !message.isUser { Spacer(minLength: DroppySpacing.lg) }
        }.accessibilityElement(children: .combine)
    }
}

/// The notch is already the notification's surface. Keep its entire message
/// tappable without nesting a second glass capsule inside Droppy's chrome.
struct GrokMessageNotice: View {
    let event: BotNotice
    @ObservedObject var store: ChatStore
    let open: () -> Void
    let dismiss: () -> Void
    private var bot: Bot { store.bots.first { $0.id == event.bot.id } ?? event.bot }
    private var preview: String {
        let text = event.id == bot.id + ":" + (bot.lastMessageID ?? "") ? bot.previewText : event.preview
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    var body: some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            Button(action: open) {
                HStack(alignment: .center, spacing: DroppySpacing.md) {
                    BotAvatar(bot: bot, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bot.name).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.primary).lineLimit(1)
                        Text(preview).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Ouvrir la conversation avec \(bot.name)")
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Ignorer cet aperçu")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
    }
}
