import AppKit
import CmuxControlCenter
import SwiftUI
import UniformTypeIdentifiers

struct ControlCenterChatView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    let isVisible: Bool
    let onOpenSection: (ControlCenterSection) -> Void
    @State private var composerHeight: CGFloat = 48
    @State private var focusRequest = 0
    @State private var confirmsFullAccess = false

    private var isActive: Bool { coordinator.isRunning || coordinator.activeChatTurnID != nil }
    private var canSend: Bool {
        isVisible && !isActive && !coordinator.chatImagesLoading
            && (!coordinator.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coordinator.chatAttachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                ControlCenterChatMarkdown(
                    turns: coordinator.chatTurns,
                    activeTurnID: coordinator.activeChatTurnID,
                    liveResponse: coordinator.displayedOutput,
                    liveEntries: coordinator.chatEntries,
                    liveOperation: coordinator.operation,
                    liveError: coordinator.error,
                    isRunning: isActive,
                    standaloneError: coordinator.chatTurns.isEmpty ? coordinator.error : nil,
                    isAwaitingApproval: coordinator.pendingApproval != nil,
                    isVisible: isVisible,
                    onRetry: { coordinator.regenerateChatTurn($0) },
                    onEdit: { coordinator.editChatTurn($0); focusRequest += 1 }
                )
                .accessibilityIdentifier("controlCenter.chatTranscript")
                if coordinator.chatTurns.isEmpty && coordinator.error == nil {
                    emptyState
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(-1)
            .clipped()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let approval = coordinator.pendingApproval {
                    approvalView(approval)
                } else if confirmsFullAccess {
                    fullAccessConfirmation
                }
                composer
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: isVisible) { _, visible in
            if visible { focusRequest += 1 }
        }
        .onChange(of: coordinator.chatPresentationID) { _, _ in
            if isVisible { focusRequest += 1 }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ControlCenterStrings.text("chatTitle")).font(.headline)
                Button {
                    onOpenSection(.connection)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: coordinator.connection.model.isEmpty ? "network.slash" : "network")
                        Text(connectionStatus).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isActive)
                .help(ControlCenterStrings.text("chatConnectionHelp"))
                .accessibilityIdentifier("controlCenter.chatConnection")
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(ControlCenterSection.allCases.filter { $0 != .chat }) { section in
                    Button { onOpenSection(section) } label: {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            } label: {
                Label(ControlCenterStrings.text("chatBrowse"), systemImage: "sidebar.left")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isActive)
            .accessibilityIdentifier("controlCenter.chatBrowse")
            Button {
                coordinator.clearChat()
                focusRequest += 1
            } label: {
                Label(ControlCenterStrings.text("chatNew"), systemImage: "square.and.pencil")
            }
            .disabled(isActive)
            .help(ControlCenterStrings.text("chatNewHelp"))
            .accessibilityIdentifier("controlCenter.chatNew")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private var connectionStatus: String {
        guard !coordinator.connection.model.isEmpty else { return ControlCenterStrings.text("chatNotConfigured") }
        let host = URL(string: coordinator.connection.baseURL)?.host ?? ControlCenterStrings.text("connection")
        return "\(ControlCenterStrings.text("chatConfigured")) · \(host) · \(coordinator.connection.model)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(ControlCenterStrings.text("chatWelcome")).font(.title2.weight(.semibold))
            Text(ControlCenterStrings.text(coordinator.connection.model.isEmpty ? "chatWelcomeOffline" : "chatWelcomeDetail"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                suggestion("chatExampleSessions", symbol: "clock")
                suggestion("chatExampleWorkspace", symbol: "rectangle.split.3x1")
                suggestion("chatExampleSettings", symbol: "slider.horizontal.3")
            }
            HStack(spacing: 16) {
                Button(ControlCenterStrings.text("sessions")) { onOpenSection(.sessions) }
                Button(ControlCenterStrings.text("favorites")) { onOpenSection(.favorites) }
                Button(ControlCenterStrings.text("chatSetup")) { onOpenSection(.connection) }
            }
            .buttonStyle(.link)
            .font(.callout)
            .disabled(isActive)
            Text(ControlCenterStrings.text("chatSessionOnly"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(32)
    }

    private func suggestion(_ key: String, symbol: String) -> some View {
        Button {
            coordinator.chatDraft = ControlCenterStrings.text(key)
            focusRequest += 1
        } label: {
            Label(ControlCenterStrings.text(key), systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(isActive)
    }

    private func approvalView(_ approval: ControlCenterApproval) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(ControlCenterStrings.text("chatApprovalNeeded"), systemImage: "hand.raised")
                .font(.callout.weight(.semibold))
            Text(approval.title).fontWeight(.medium).textSelection(.enabled)
            ScrollView {
                Text(approval.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 145)
            HStack {
                Text(ControlCenterStrings.text("chatApprovalHint"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ControlCenterStrings.text("chatReject")) { resolveApproval(false) }
                    .accessibilityIdentifier("controlCenter.chatReject")
                Button(ControlCenterStrings.text("chatApprove")) { resolveApproval(true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("controlCenter.chatApprove")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controlCenter.chatApproval")
    }

    private var fullAccessConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ControlCenterStrings.text("chatFullAccessTitle"), systemImage: "lock.open")
                .font(.callout.weight(.semibold))
            Text(ControlCenterStrings.text("chatFullAccessDetail"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(ControlCenterStrings.text("cancel")) { confirmsFullAccess = false }
                Button(ControlCenterStrings.text("chatEnableFullAccess")) {
                    coordinator.accessMode = .fullAccess
                    confirmsFullAccess = false
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(isActive)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("controlCenter.chatFullAccessConfirmation")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.chatEditingTurnID != nil {
                HStack(alignment: .top) {
                    Label(ControlCenterStrings.text("chatEditingMessage"), systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(ControlCenterStrings.text("cancel")) {
                        coordinator.cancelChatEdit()
                        focusRequest += 1
                    }
                    .buttonStyle(.link)
                }
            }
            modelControls
            if !coordinator.chatAttachments.isEmpty { attachmentStrip }
            if coordinator.chatImagesLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(ControlCenterStrings.text("chatImagesLoading")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack(alignment: .topLeading) {
                if coordinator.chatDraft.isEmpty {
                    Text(ControlCenterStrings.text("chatPlaceholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ControlCenterChatInput(
                    text: $coordinator.chatDraft,
                    measuredHeight: $composerHeight,
                    focusRequest: focusRequest,
                    isVisible: isVisible,
                    canSend: canSend,
                    historyActive: coordinator.chatHistoryIndex != nil,
                    onSend: send,
                    onRecall: { coordinator.recallChatInput($0) },
                    onImageURLs: { coordinator.addChatImages($0) },
                    onImageData: { coordinator.addChatImageData($0, name: $1) }
                )
                .frame(height: composerHeight)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .separatorColor)))
            if let error = coordinator.chatComposerError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = coordinator.chatLogError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if coordinator.chatDraft.isEmpty && !isActive {
                Text(ControlCenterStrings.text("chatCommandsHint"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: chooseImages) {
                    Image(systemName: "paperclip")
                        .accessibilityLabel(ControlCenterStrings.text("chatAttachImages"))
                }
                .help(ControlCenterStrings.text("chatAttachImages"))
                .accessibilityIdentifier("controlCenter.chatAttachImages")
                Picker(ControlCenterStrings.text("chatAccessMode"), selection: Binding(
                    get: { coordinator.accessMode },
                    set: { mode in
                        if mode == .fullAccess && coordinator.accessMode != .fullAccess {
                            confirmsFullAccess = true
                        } else {
                            coordinator.accessMode = mode
                        }
                    }
                )) {
                    ForEach(ControlCenterAccessMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(isActive)
                .help(ControlCenterStrings.text("chatAccessHelp"))
                .accessibilityIdentifier("controlCenter.chatAccessMode")
                Text(ControlCenterStrings.text(coordinator.pendingApproval != nil ? "chatApprovalNeeded" : (isActive ? "chatDraftWhileRunning" : "chatKeyboardHint")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if isActive {
                    ProgressView().controlSize(.small)
                    Button { coordinator.cancel(); focusRequest += 1 } label: {
                        Label(ControlCenterStrings.text("chatStop"), systemImage: "stop.fill")
                    }
                    .accessibilityIdentifier("controlCenter.chatStop")
                } else {
                    Button(action: send) {
                        Label(ControlCenterStrings.text("chatSend"), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .accessibilityIdentifier("controlCenter.chatSend")
                }
            }
        }
    }

    private var modelControls: some View {
        HStack(spacing: 12) {
            Menu {
                if !coordinator.connection.model.isEmpty {
                    Button(coordinator.connection.model) { coordinator.selectChatModel(coordinator.connection.model) }
                    Divider()
                }
                ForEach(coordinator.models.filter { $0 != coordinator.connection.model }, id: \.self) { model in
                    Button(model) { coordinator.selectChatModel(model) }
                }
                Divider()
                Button(ControlCenterStrings.text("chatRefreshModels")) {
                    Task { await coordinator.loadModels() }
                }
            } label: {
                Label(coordinator.connection.model.isEmpty ? ControlCenterStrings.text("chatModel") : coordinator.connection.model, systemImage: "cpu")
                    .lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .help(ControlCenterStrings.text("chatModel"))
            .accessibilityIdentifier("controlCenter.chatModel")
            Picker(ControlCenterStrings.text("chatReasoning"), selection: Binding(
                get: { coordinator.connection.reasoningEffort ?? "auto" },
                set: { coordinator.selectChatReasoningEffort($0) }
            )) {
                Text(ControlCenterStrings.text("chatReasoningAuto")).tag("auto")
                Text(ControlCenterStrings.text("chatReasoningNone")).tag("none")
                Text(ControlCenterStrings.text("chatReasoningMinimal")).tag("minimal")
                Text(ControlCenterStrings.text("chatReasoningLow")).tag("low")
                Text(ControlCenterStrings.text("chatReasoningMedium")).tag("medium")
                Text(ControlCenterStrings.text("chatReasoningHigh")).tag("high")
                Text(ControlCenterStrings.text("chatReasoningXHigh")).tag("xhigh")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(ControlCenterStrings.text("chatReasoning"))
            .accessibilityIdentifier("controlCenter.chatReasoning")
        }
        .font(.caption)
        .disabled(isActive)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(coordinator.chatAttachments) { attachment in
                    VStack(alignment: .leading, spacing: 4) {
                        Image(nsImage: attachment.preview)
                            .resizable().scaledToFill()
                            .frame(width: 76, height: 60).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                Button { coordinator.removeChatImage(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .help(ControlCenterStrings.text("chatRemoveImage"))
                                .accessibilityLabel("\(ControlCenterStrings.text("chatRemoveImage")): \(attachment.name)")
                            }
                        Text(attachment.name).font(.caption2).lineLimit(1).frame(width: 76, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = ControlCenterStrings.text("chatAttachImages")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            coordinator.addChatImages(panel.urls)
            focusRequest += 1
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func send() {
        guard canSend else { return }
        coordinator.sendChat()
        focusRequest += 1
    }

    private func resolveApproval(_ allowed: Bool) {
        coordinator.resolveApproval(allowed)
        focusRequest += 1
    }
}
