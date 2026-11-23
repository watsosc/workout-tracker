import SwiftUI

// Themed replacements for system popups (.alert / .confirmationDialog / Menu) and sheet chrome.
// App target only (not the Live Activity extension).

struct NeonDialogButton: Identifiable {
    let id = UUID()
    let title: String
    var kind: NeonButtonStyle.Kind = .ghost
    var isCancel = false
    var action: () -> Void = {}

    static func cancel(_ title: String = "Cancel", action: @escaping () -> Void = {}) -> NeonDialogButton {
        NeonDialogButton(title: title, isCancel: true, action: action)
    }
}

extension View {
    /// Themed alert / confirmation dialog. Button actions run after the dialog has closed, so an
    /// action may present another sheet or dialog.
    func neonDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        kicker: String = "Confirm",
        message: String? = nil,
        text: Binding<String>? = nil,
        placeholder: String = "",
        buttons: [NeonDialogButton]
    ) -> some View {
        let item = Binding<NeonDialogToken?>(
            get: { isPresented.wrappedValue ? NeonDialogToken() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return modifier(NeonDialogModifier(
            item: item,
            kicker: kicker,
            title: { _ in title },
            message: message.map { value in { _ in value } },
            text: text,
            placeholder: placeholder,
            buttons: { _ in buttons }
        ))
    }

    /// Item-driven variant: the item is captured when the dialog opens and handed to the builders,
    /// so actions still see it after the binding is cleared.
    func neonDialog<Item>(
        item: Binding<Item?>,
        kicker: String = "Confirm",
        title: @escaping (Item) -> String,
        message: ((Item) -> String)? = nil,
        text: Binding<String>? = nil,
        placeholder: String = "",
        buttons: @escaping (Item) -> [NeonDialogButton]
    ) -> some View {
        modifier(NeonDialogModifier(item: item, kicker: kicker, title: title, message: message, text: text, placeholder: placeholder, buttons: buttons))
    }
}

private struct NeonDialogToken {}

private struct NeonDialogModifier<Item>: ViewModifier {
    @Binding var item: Item?
    let kicker: String
    let title: (Item) -> String
    let message: ((Item) -> String)?
    let text: Binding<String>?
    let placeholder: String
    let buttons: (Item) -> [NeonDialogButton]

    @State private var shown: Item?
    @State private var coverPresented = false
    @State private var pendingAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onChange(of: item != nil, initial: true) { _, isSet in
                if isSet, let item {
                    shown = item
                    setCover(true)
                } else if !isSet, coverPresented {
                    setCover(false)
                }
            }
            .fullScreenCover(isPresented: $coverPresented, onDismiss: {
                let action = pendingAction
                pendingAction = nil
                shown = nil
                if item != nil { item = nil }
                action?()
            }) {
                if let shown {
                    NeonDialogView(
                        kicker: kicker,
                        title: title(shown),
                        message: message?(shown),
                        text: text,
                        placeholder: placeholder,
                        buttons: buttons(shown)
                    ) { chosen in
                        pendingAction = chosen?.action
                        setCover(false)
                    }
                    .presentationBackground(.clear)
                }
            }
    }

    /// The cover itself appears/disappears instantly; NeonDialogView animates its own fade.
    private func setCover(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { coverPresented = value }
    }
}

private struct NeonDialogView: View {
    let kicker: String
    let title: String
    let message: String?
    let text: Binding<String>?
    let placeholder: String
    let buttons: [NeonDialogButton]
    let onFinish: (NeonDialogButton?) -> Void

    @State private var visible = false
    @State private var finishing = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let actions = buttons.filter { !$0.isCancel }
        let cancel = buttons.first(where: \.isCancel)

        ZStack {
            Color.black.opacity(visible ? 0.72 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { finish(cancel) }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: "// \(kicker)", color: Neon.pink)
                    Text(title.uppercased())
                        .font(Neon.head(24, .bold, relativeTo: .title2))
                        .tracking(1.2)
                        .foregroundStyle(Neon.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message)
                            .font(Neon.mono(13, relativeTo: .footnote))
                            .foregroundStyle(Neon.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let text {
                    TextField("", text: text, prompt: Text(placeholder.uppercased()).foregroundColor(Neon.muted.opacity(0.6)))
                        .focused($fieldFocused)
                        .font(Neon.mono(17))
                        .foregroundStyle(Neon.white)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if let first = actions.first { finish(first) } }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(Neon.ink2, in: CutCornerShape(cut: 10))
                        .overlay(CutCornerShape(cut: 10).strokeBorder(fieldFocused ? Neon.yellow : Neon.line, lineWidth: 1))
                }

                if actions.count == 2 {
                    HStack(spacing: 10) { ForEach(actions) { actionButton($0) } }
                } else if actions.count > 5 {
                    ScrollView {
                        VStack(spacing: 10) { ForEach(actions) { actionButton($0) } }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 330)
                } else {
                    VStack(spacing: 10) { ForEach(actions) { actionButton($0) } }
                }

                if let cancel {
                    Button(cancel.title) { finish(cancel) }
                        .buttonStyle(NeonLinkStyle(color: Neon.muted))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
            }
            .neonPanel(edge: Neon.heroEdge, cut: 16, padding: 18)
            .padding(.horizontal, 24)
            .scaleEffect(visible ? 1 : 0.94)
            .opacity(visible ? 1 : 0)
        }
        .preferredColorScheme(.dark)
        .tint(Neon.yellow)
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) { visible = true }
            if text != nil { fieldFocused = true }
        }
    }

    private func actionButton(_ button: NeonDialogButton) -> some View {
        Button(button.title) { finish(button) }
            .buttonStyle(NeonButtonStyle(kind: button.kind, height: 46, fontSize: 14))
    }

    private func finish(_ button: NeonDialogButton?) {
        guard !finishing else { return }
        finishing = true
        fieldFocused = false
        withAnimation(.easeIn(duration: 0.12)) {
            visible = false
        } completion: {
            onFinish(button)
        }
    }
}

// MARK: - Sheet chrome

/// Mono text button for sheet toolbars (Cancel / Save), without the system glass capsule.
struct NeonToolbarButton: View {
    let title: String
    var color: Color = Neon.yellow
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Neon.mono(15, relativeTo: .body))
                .tracking(1.2)
                .foregroundStyle(isEnabled ? color : Neon.muted.opacity(0.5))
        }
    }
}

extension ToolbarContent {
    /// Hides the iOS 26 glass capsule behind a toolbar item.
    func neonToolbarItem() -> some ToolbarContent {
        sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// Themed sheet: ink background, dark scheme and the neon accent (sheets don't inherit them).
    func neonSheet() -> some View {
        presentationBackground(Neon.ink)
            .preferredColorScheme(.dark)
            .tint(Neon.yellow)
    }

    /// Extra bottom room so the last rows can scroll clear of the floating tab bar.
    func neonTabBarClearance() -> some View {
        contentMargins(.bottom, 96, for: .scrollContent)
    }
}
