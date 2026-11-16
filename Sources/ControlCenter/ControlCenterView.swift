import AppKit
import CmuxAppKitSupportUI
import CmuxControlCenter
import CmuxFoundation
import SwiftUI

struct ControlCenterTheme: Equatable {
    let backgroundNSColor: NSColor
    let foregroundNSColor: NSColor
    let secondaryForegroundNSColor: NSColor
    let accentNSColor: NSColor
    let borderNSColor: NSColor
    let colorScheme: ColorScheme
    let usesClearBackdrop: Bool

    init(
        backgroundNSColor: NSColor = .windowBackgroundColor,
        foregroundNSColor: NSColor = .labelColor,
        secondaryForegroundNSColor: NSColor = .secondaryLabelColor,
        accentNSColor: NSColor = .controlAccentColor,
        borderNSColor: NSColor = .separatorColor,
        colorScheme: ColorScheme = .dark,
        usesClearBackdrop: Bool = false
    ) {
        self.backgroundNSColor = backgroundNSColor
        self.foregroundNSColor = foregroundNSColor
        self.secondaryForegroundNSColor = secondaryForegroundNSColor
        self.accentNSColor = accentNSColor
        self.borderNSColor = borderNSColor
        self.colorScheme = colorScheme
        self.usesClearBackdrop = usesClearBackdrop
    }

    var surfaceBackgroundColor: Color {
        usesClearBackdrop ? .clear : Color(nsColor: backgroundNSColor)
    }

    var opaqueBackgroundColor: Color { Color(nsColor: backgroundNSColor) }
    var foregroundColor: Color { Color(nsColor: foregroundNSColor) }
    var secondaryForegroundColor: Color { Color(nsColor: secondaryForegroundNSColor) }
    var accentColor: Color { Color(nsColor: accentNSColor) }
    var borderColor: Color { Color(nsColor: borderNSColor) }

    var backgroundHex: String {
        backgroundNSColor.hexString()
    }

    var foregroundHex: String {
        foregroundNSColor.hexString()
    }

    var accentHex: String {
        accentNSColor.hexString()
    }

    var borderHex: String {
        WindowChromeColorResolver().compositedColor(borderNSColor, over: backgroundNSColor).hexString()
    }

    var elevatedSurfaceColor: Color {
        if usesClearBackdrop {
            return Color(nsColor: foregroundNSColor).opacity(colorScheme == .dark ? 0.065 : 0.045)
        }
        let overlay = foregroundNSColor.withAlphaComponent(colorScheme == .dark ? 0.055 : 0.040)
        return Color(nsColor: WindowChromeColorResolver().compositedColor(overlay, over: backgroundNSColor))
    }

    var inputSurfaceColor: Color {
        if usesClearBackdrop {
            return Color(nsColor: foregroundNSColor).opacity(colorScheme == .dark ? 0.045 : 0.032)
        }
        let overlay = foregroundNSColor.withAlphaComponent(colorScheme == .dark ? 0.035 : 0.025)
        return Color(nsColor: WindowChromeColorResolver().compositedColor(overlay, over: backgroundNSColor))
    }
}

private struct ControlCenterThemeKey: EnvironmentKey {
    static let defaultValue = ControlCenterTheme()
}

extension EnvironmentValues {
    var controlCenterTheme: ControlCenterTheme {
        get { self[ControlCenterThemeKey.self] }
        set { self[ControlCenterThemeKey.self] = newValue }
    }
}

extension View {
    func controlCenterSheetTheme(_ theme: ControlCenterTheme) -> some View {
        self
            .environment(\.controlCenterTheme, theme)
            .environment(\.colorScheme, theme.colorScheme)
            .tint(theme.accentColor)
            .foregroundStyle(theme.foregroundColor)
            .background(theme.opaqueBackgroundColor)
    }
}

enum ControlCenterSection: String, CaseIterable, Identifiable {
    case chat, sessions, favorites, collections, workspace, preferences, settings, history, connection
    var id: String { rawValue }
    var title: String { ControlCenterStrings.text(rawValue) }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "clock"
        case .favorites: return "bookmark"
        case .collections: return "square.stack"
        case .workspace: return "plus.rectangle"
        case .preferences: return "brain"
        case .settings: return "slider.horizontal.3"
        case .history: return "list.bullet.rectangle"
        case .connection: return "network"
        }
    }

    static let workspaceSections: [Self] = [.sessions, .favorites, .collections, .workspace]
    static let configurationSections: [Self] = [.preferences, .settings, .history, .connection]
}

struct ControlCenterView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    let isVisible: Bool
    var windowAppearance: WindowAppearanceSnapshot? = nil
    @State private var section: ControlCenterSection = .chat
    @State private var dialogThemeObserver = GhosttyDialogThemeObserver.shared
    @Environment(\.colorScheme) private var ambientColorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.cmuxAccentColor) private var cmuxAccentColor

    private var theme: ControlCenterTheme {
        let scheme = windowAppearance?.resolvedColorScheme ?? ambientColorScheme
        let bg = (windowAppearance?.resolvedChromeBackgroundColor
            ?? WindowAppearanceSnapshot.resolvedColor(.windowBackgroundColor, for: scheme))
            .usingColorSpace(.sRGB) ?? WindowAppearanceSnapshot.resolvedColor(.windowBackgroundColor, for: scheme)
        let preferredForeground = dialogThemeObserver.theme.foreground
        let fg = cmuxReadableForegroundNSColor(preferred: preferredForeground, on: bg)
        let secondary = SidebarAppearanceColorResolver().readableSecondaryColor(
            .secondaryLabelColor,
            for: scheme,
            over: bg
        )
        let accent = cmuxAccentColor.nsColor(for: scheme)
        let increaseContrast = colorSchemeContrast == .increased || DisplayAccessibilityOptions.current.increaseContrast
        let border = WindowChromeColorResolver().separatorColor(
            forChromeBackground: bg,
            increaseContrast: increaseContrast
        )
        let usesClearBackdrop = windowAppearance?.showsWindowBackdrop(
            glassEffectAvailable: AppWindowChromeComposition().glassEffect.isAvailable,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ) ?? false
        return ControlCenterTheme(
            backgroundNSColor: bg,
            foregroundNSColor: fg,
            secondaryForegroundNSColor: secondary,
            accentNSColor: accent,
            borderNSColor: border,
            colorScheme: scheme,
            usesClearBackdrop: usesClearBackdrop
        )
    }

    var body: some View {
        let resolvedTheme = theme
        VStack(spacing: 0) {
            navigationHeader(theme: resolvedTheme)
            WindowChromeBorder(
                orientation: .horizontal,
                ignoresSafeArea: false,
                backgroundColor: resolvedTheme.backgroundNSColor
            )
            ZStack {
                ControlCenterChatView(
                    coordinator: coordinator,
                    isVisible: isVisible && section == .chat,
                    onOpenSection: { section = $0 }
                )
                .opacity(section == .chat ? 1 : 0)
                .allowsHitTesting(section == .chat)
                .accessibilityHidden(section != .chat)

                if section != .chat {
                    VStack(spacing: 0) {
                        if coordinator.error != nil || coordinator.isRunning {
                            statusBanner(theme: resolvedTheme)
                            WindowChromeBorder(
                                orientation: .horizontal,
                                ignoresSafeArea: false,
                                backgroundColor: resolvedTheme.backgroundNSColor
                            )
                        }
                        auxiliaryContent
                            .frame(maxWidth: 960, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .background(resolvedTheme.surfaceBackgroundColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(resolvedTheme.surfaceBackgroundColor)
        .foregroundStyle(resolvedTheme.foregroundColor)
        .tint(resolvedTheme.accentColor)
        .environment(\.colorScheme, resolvedTheme.colorScheme)
        .environment(\.controlCenterTheme, resolvedTheme)
        .accessibilityIdentifier("ControlCenterMainContent")
        .task { await coordinator.load() }
        .onChange(of: coordinator.pendingApproval?.id) { _, id in
            if id != nil { section = .chat }
        }
        .onChange(of: coordinator.chatPresentationID) { _, _ in section = .chat }
    }

    private var isConfigured: Bool {
        !coordinator.connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var connectionStatusText: String {
        guard isConfigured else { return ControlCenterStrings.text("chatNotConfigured") }
        let host = URL(string: coordinator.connection.baseURL)?.host ?? ControlCenterStrings.text("connection")
        return "\(host) · \(coordinator.connection.model)"
    }

    private func navigationHeader(theme: ControlCenterTheme) -> some View {
        HStack(spacing: 10) {
            if section != .chat {
                Button {
                    section = .chat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(ControlCenterSection.chat.title)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.elevatedSurfaceColor, in: Capsule())
                    .overlay(Capsule().stroke(theme.borderColor))
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            } else {
                Button {
                    section = .connection
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConfigured ? Color.green : theme.secondaryForegroundColor.opacity(0.6))
                            .frame(width: 6.5, height: 6.5)
                        Text(connectionStatusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.75))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.elevatedSurfaceColor, in: Capsule())
                    .overlay(Capsule().stroke(theme.borderColor))
                }
                .buttonStyle(.plain)
                .help(ControlCenterStrings.text("chatConnectionHelp"))
                .accessibilityIdentifier("controlCenter.chatConnection")
            }

            Spacer(minLength: 8)

            Menu {
                sectionMenuItem(.chat)
                Divider()
                ForEach(ControlCenterSection.workspaceSections) { item in
                    sectionMenuItem(item)
                }
                Divider()
                ForEach(ControlCenterSection.configurationSections) { item in
                    sectionMenuItem(item)
                }
            } label: {
                Label(ControlCenterStrings.text("chatBrowse"), systemImage: "square.grid.2x2")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("controlCenter.chatBrowse")

            if section == .chat {
                Button {
                    coordinator.clearChat()
                    coordinator.chatPresentationID = UUID()
                } label: {
                    Label(ControlCenterStrings.text("chatNew"), systemImage: "square.and.pencil")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .disabled(coordinator.isRunning || coordinator.activeChatTurnID != nil)
                .help(ControlCenterStrings.text("chatNewHelp"))
                .accessibilityIdentifier("controlCenter.chatNew")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionMenuItem(_ item: ControlCenterSection) -> some View {
        Button {
            section = item
        } label: {
            if section == item {
                Label(item.title, systemImage: "checkmark")
            } else {
                Label(item.title, systemImage: item.symbol)
            }
        }
    }

    private func statusBanner(theme: ControlCenterTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = coordinator.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("controlCenter.error")
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.red.opacity(0.22)))
            }
            if coordinator.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(coordinator.operation?.title ?? ControlCenterStrings.text("operation"))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Button(ControlCenterStrings.text("cancel")) { coordinator.cancel() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: 960)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var auxiliaryContent: some View {
        switch section {
        case .chat: EmptyView()
        case .sessions: ControlCenterSessionsView(coordinator: coordinator)
        case .favorites: ControlCenterFavoritesView(coordinator: coordinator)
        case .collections: ControlCenterCollectionsView(coordinator: coordinator)
        case .workspace: ControlCenterWorkspaceView(coordinator: coordinator)
        case .preferences: ControlCenterPreferencesView(coordinator: coordinator)
        case .settings: ControlCenterSettingsView(coordinator: coordinator)
        case .history: ControlCenterHistoryView(coordinator: coordinator)
        case .connection: ControlCenterConnectionView(coordinator: coordinator)
        }
    }
}

struct ControlCenterOperationCardView: View {
    let operation: ControlCenterOperation
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(operation.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !operation.steps.isEmpty {
                    Text("\(operation.steps.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.foregroundColor.opacity(0.06), in: Capsule())
                }
                Text(operation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForegroundColor)
            }
            if !operation.steps.isEmpty {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(operation.steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: statusIcon(step.status))
                                .foregroundStyle(statusColor(step.status))
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(step.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(ControlCenterStrings.text(step.status.rawValue))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(statusColor(step.status))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(statusColor(step.status).opacity(0.12), in: Capsule())
                                }
                                if !step.detail.isEmpty {
                                    stepDetailView(step.detail)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderColor)
        )
    }

    @ViewBuilder
    private func stepDetailView(_ detail: String) -> some View {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(trimmed)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.inputSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Text(detail)
                .font(.callout)
                .foregroundStyle(theme.secondaryForegroundColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusIcon(_ status: ControlCenterStep.Status) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked: return "hand.raised.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func statusColor(_ status: ControlCenterStep.Status) -> Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .blocked: return .orange
        case .cancelled: return theme.secondaryForegroundColor
        }
    }
}

struct ControlCenterHistoryView: View {
    @ObservedObject var coordinator: ControlCenterCoordinator
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if coordinator.snapshot.operations.isEmpty {
                    ControlCenterEmptyCardView(
                        symbol: "list.bullet.rectangle",
                        title: ControlCenterStrings.text("history"),
                        subtitle: ControlCenterStrings.text("empty")
                    )
                }
                ForEach(coordinator.snapshot.operations) { operation in
                    ControlCenterOperationCardView(operation: operation)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ControlCenterEmptyCardView: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Environment(\.controlCenterTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.secondaryForegroundColor)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(theme.secondaryForegroundColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.borderColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
