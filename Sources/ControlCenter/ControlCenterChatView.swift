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
    @State private var isInputFocused = false
    @Environment(\.controlCenterTheme) private var theme

    private var isActive: Bool { coordinator.isRunning || coordinator.activeChatTurnID != nil }
    private var canSend: Bool {
        isVisible && !isActive && !coordinator.chatImagesLoading
            && (!coordinator.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coordinator.chatAttachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    themeBackgroundHex: theme.backgroundHex,
                    themeForegroundHex: theme.foregroundHex,
                    themeBorderHex: theme.borderHex,
                    accentHex: theme.accentHex,
                    themeColorScheme: theme.colorScheme,
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
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
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
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .background(theme.surfaceBackgroundColor)
        .onChange(of: isVisible) { _, visible in
            if visible { focusRequest += 1 }
        }
        .onChange(of: coordinator.chatPresentationID) { _, _ in
            if isVisible { focusRequest += 1 }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ControlCenterStrings.text("chatWelcome"))
                        .font(.title2.weight(.semibold))
                    Text(ControlCenterStrings.text(coordinator.connection.model.isEmpty ? "chatWelcomeOffline" : "chatWelcomeDetail"))
                        .font(.callout)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ControlCenterSuggestionButton(
                    title: ControlCenterStrings.text("chatExampleSessions"),
                    symbol: "clock",
                    disabled: isActive
                ) {
                    coordinator.chatDraft = ControlCenterStrings.text("chatExampleSessions")
                    focusRequest += 1
                }
                ControlCenterSuggestionButton(
                    title: ControlCenterStrings.text("chatExampleWorkspace"),
                    symbol: "rectangle.split.3x1",
                    disabled: isActive
                ) {
                    coordinator.chatDraft = ControlCenterStrings.text("chatExampleWorkspace")
                    focusRequest += 1
                }
                ControlCenterSuggestionButton(
                    title: ControlCenterStrings.text("chatExampleSettings"),
                    symbol: "slider.horizontal.3",
                    disabled: isActive
                ) {
                    coordinator.chatDraft = ControlCenterStrings.text("chatExampleSettings")
                    focusRequest += 1
                }
            }

            HStack(spacing: 8) {
                quickSectionButton(.sessions, title: ControlCenterStrings.text("sessions"))
                quickSectionButton(.favorites, title: ControlCenterStrings.text("favorites"))
                quickSectionButton(.collections, title: ControlCenterStrings.text("collections"))
                quickSectionButton(.connection, title: ControlCenterStrings.text("chatSetup"))
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption2)
                Text(ControlCenterStrings.text("chatSessionOnly"))
                    .font(.caption)
            }
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.75))
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.borderColor)
        )
        .padding(24)
    }

    private func quickSectionButton(_ section: ControlCenterSection, title: String) -> some View {
        Button {
            onOpenSection(section)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(theme.foregroundColor)
            .background(
                Capsule()
                    .fill(theme.inputSurfaceColor)
            )
            .overlay(
                Capsule()
                    .stroke(theme.borderColor)
            )
        }
        .buttonStyle(.plain)
    }

    private func approvalView(_ approval: ControlCenterApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(ControlCenterStrings.text("chatApprovalNeeded"))
                    .font(.callout.weight(.semibold))
                Text("·")
                    .foregroundStyle(theme.secondaryForegroundColor)
                Text(approval.title)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(approval.detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 150)
            .background(theme.inputSurfaceColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.borderColor))
            HStack(spacing: 10) {
                Text(ControlCenterStrings.text("chatApprovalHint"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
                Spacer()
                Button(ControlCenterStrings.text("chatReject")) { resolveApproval(false) }
                    .accessibilityIdentifier("controlCenter.chatReject")
                Button(ControlCenterStrings.text("chatApprove")) { resolveApproval(true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("controlCenter.chatApprove")
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.orange.opacity(0.32)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controlCenter.chatApproval")
    }

    private var fullAccessConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ControlCenterStrings.text("chatFullAccessTitle"), systemImage: "lock.open.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(ControlCenterStrings.text("chatFullAccessDetail"))
                .font(.callout)
                .foregroundStyle(theme.secondaryForegroundColor)
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
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.orange.opacity(0.32)))
        .accessibilityIdentifier("controlCenter.chatFullAccessConfirmation")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if coordinator.chatEditingTurnID != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accentColor)
                        Text(ControlCenterStrings.text("chatEditingMessage"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.secondaryForegroundColor)
                        Spacer(minLength: 4)
                        Button(ControlCenterStrings.text("cancel")) {
                            coordinator.cancelChatEdit()
                            focusRequest += 1
                        }
                        .buttonStyle(.link)
                        .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.accentColor.opacity(0.10))
                    Rectangle()
                        .fill(theme.borderColor)
                        .frame(height: 1)
                }

                if !coordinator.chatAttachments.isEmpty || coordinator.chatImagesLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        if !coordinator.chatAttachments.isEmpty {
                            attachmentStrip
                        }
                        if coordinator.chatImagesLoading {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(ControlCenterStrings.text("chatImagesLoading"))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryForegroundColor)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }

                ZStack(alignment: .topLeading) {
                    if coordinator.chatDraft.isEmpty {
                        Text(ControlCenterStrings.text("chatPlaceholder"))
                            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.70))
                            .padding(.horizontal, 13)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    ControlCenterChatInput(
                        text: $coordinator.chatDraft,
                        measuredHeight: $composerHeight,
                        isFocused: $isInputFocused,
                        focusRequest: focusRequest,
                        isVisible: isVisible,
                        canSend: canSend,
                        historyActive: coordinator.chatHistoryIndex != nil,
                        colorScheme: theme.colorScheme,
                        textColor: theme.foregroundNSColor,
                        insertionPointColor: theme.accentNSColor,
                        onSend: send,
                        onRecall: { coordinator.recallChatInput($0) },
                        onImageURLs: { coordinator.addChatImages($0) },
                        onImageData: { coordinator.addChatImageData($0, name: $1) }
                    )
                    .frame(height: composerHeight)
                }
                .padding(.horizontal, 2)

                Rectangle()
                    .fill(theme.borderColor.opacity(0.75))
                    .frame(height: 1)

                composerToolbar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(theme.foregroundColor.opacity(0.02))
            }
            .background(theme.elevatedSurfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isInputFocused ? theme.accentColor.opacity(0.75) : theme.borderColor,
                        lineWidth: isInputFocused ? 1.5 : 1
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)

            if let error = coordinator.chatComposerError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = coordinator.chatLogError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(ControlCenterStrings.text(coordinator.pendingApproval != nil ? "chatApprovalNeeded" : (isActive ? "chatDraftWhileRunning" : "chatKeyboardHint")))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if coordinator.chatDraft.isEmpty && !isActive {
                    Text(ControlCenterStrings.text("chatCommandsHint"))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var composerToolbar: some View {
        HStack(spacing: 8) {
            Button(action: chooseImages) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(theme.foregroundColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel(ControlCenterStrings.text("chatAttachImages"))
            }
            .buttonStyle(.plain)
            .help(ControlCenterStrings.text("chatAttachImages"))
            .accessibilityIdentifier("controlCenter.chatAttachImages")

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
                Label(
                    coordinator.connection.model.isEmpty ? ControlCenterStrings.text("chatModel") : coordinator.connection.model,
                    systemImage: "cpu"
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isActive)
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
            .labelsHidden()
            .fixedSize()
            .disabled(isActive)
            .help(ControlCenterStrings.text("chatReasoning"))
            .accessibilityIdentifier("controlCenter.chatReasoning")

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

            Spacer(minLength: 4)

            if isActive {
                ProgressView().controlSize(.small)
                Button {
                    coordinator.cancel()
                    focusRequest += 1
                } label: {
                    Label(ControlCenterStrings.text("chatStop"), systemImage: "stop.fill")
                }
                .controlSize(.small)
                .accessibilityIdentifier("controlCenter.chatStop")
            } else {
                Button(action: send) {
                    Label(ControlCenterStrings.text("chatSend"), systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSend)
                .accessibilityIdentifier("controlCenter.chatSend")
            }
        }
        .font(.caption)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(coordinator.chatAttachments) { attachment in
                    VStack(alignment: .leading, spacing: 3) {
                        Image(nsImage: attachment.preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 78, height: 58)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(theme.borderColor)
                            )
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    coordinator.removeChatImage(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.72))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .help(ControlCenterStrings.text("chatRemoveImage"))
                                .accessibilityLabel("\(ControlCenterStrings.text("chatRemoveImage")): \(attachment.name)")
                            }
                        Text(attachment.name)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .lineLimit(1)
                            .frame(width: 78, alignment: .leading)
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

private struct ControlCenterSuggestionButton: View {
    let title: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 22)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .opacity(isHovered ? 1 : 0.45)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? theme.accentColor.opacity(0.10) : theme.inputSurfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isHovered ? theme.accentColor.opacity(0.40) : theme.borderColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
    }
}
