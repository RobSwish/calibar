import AppKit
import SwiftUI

struct EditorDropdownOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    var groupID: String? = nil
    var groupTitle: String? = nil
    var color: Color? = nil
    var separatorBefore = false
}

/// The same arrowless child-window presentation used by Nimble and Thimble.
struct EditorDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [EditorDropdownOption<Value>]
    var inline = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false
    @State private var window = DropdownWindow()
    @State private var anchor = EditorDropdownAnchor()

    init(_ title: String, selection: Binding<Value>, options: [EditorDropdownOption<Value>], inline: Bool = false) {
        self.title = title
        _selection = selection
        self.options = options
        self.inline = inline
    }

    init(_ title: String, selection: Binding<Value>, values: [Value], label: (Value) -> String) {
        self.init(title, selection: selection, options: values.map { .init(id: $0, title: label($0)) })
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.id == selection }?.title ?? "Choose calendar")
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(.system(size: inline ? 12 : 13))
            .foregroundStyle(inline ? .secondary : .primary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(options.isEmpty)
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.id == selection }?.title ?? "None")
        .background(EditorDropdownAnchorReader(anchor: anchor))
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.15), value: isOpen)
        .onChange(of: isOpen) { _, open in
            if open { present() } else { window.close() }
        }
        .onDisappear { window.close() }
    }

    private func present() {
        guard let view = anchor.view, let parent = view.window else { isOpen = false; return }
        let frame = parent.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let preferredWidth: CGFloat = options.count > 30 || inline ? 280 : 210
        let width: CGFloat = min(preferredWidth, screen.width - 16)
        let availableBelow = frame.minY - screen.minY - 12
        let availableAbove = screen.maxY - frame.maxY - 12
        let maximumHeight = max(80, min(280, max(availableBelow, availableAbove)))
        let content = EditorDropdownOptions(options: options, selected: selection, maximumHeight: maximumHeight) { value in
            isOpen = false
            window.close()
            selection = value
        }
        .frame(width: width)
        .modifier(EditorDropdownSurface())
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 2, y: 1)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.13), radius: 12, y: 6)
        .padding(24)
        .modifier(EditorDropdownEntrance(reduceMotion: reduceMotion))
        .environment(\.colorScheme, colorScheme)
        .environment(\.controlActiveState, .active)
        window.open(content: AnyView(content), anchor: frame, width: width, parent: parent, trailing: !inline) {
            isOpen = false
        }
    }
}

private struct EditorDropdownOptions<Value: Hashable>: View {
    let options: [EditorDropdownOption<Value>]
    let selected: Value
    let maximumHeight: CGFloat
    let select: (Value) -> Void
    @State private var query = ""
    @State private var highlighted: Value?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var searchable: Bool { options.count > 30 }
    private var filtered: [EditorDropdownOption<Value>] {
        query.isEmpty ? options : options.filter { $0.title.localizedStandardContains(query) }
    }
    private var listHeight: CGFloat {
        let groups = Set(options.compactMap(\.groupID)).count
        let separators = options.filter(\.separatorBefore).count
        return min(maximumHeight - (searchable ? 48 : 8), CGFloat(options.count * 24 + groups * 32 + max(0, groups - 1) * 11 + separators * 11))
    }

    var body: some View {
        VStack(spacing: 4) {
            if searchable {
                TextField("Search \(options.first?.groupID == nil ? "options" : "calendars")", text: $query)
                    .textFieldStyle(.plain).padding(8).focused($searchFocused)
                    .accessibilityLabel("Search options")
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                            if option.separatorBefore { Divider().padding(.horizontal, 8).padding(.vertical, 5) }
                            if let group = option.groupTitle,
                               index == 0 || filtered[index - 1].groupID != option.groupID {
                                if index > 0 { Divider().padding(.horizontal, 8).padding(.vertical, 5) }
                                Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                            }
                            Button { select(option.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                        .frame(width: 12).opacity(option.id == selected ? 1 : 0)
                                        .accessibilityHidden(true)
                                    if let color = option.color {
                                        Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                                    }
                                    Text(option.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(highlighted == option.id ? Color.white : .primary)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(highlighted == option.id ? Color.red : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(option.id)
                            .onHover { if $0 { highlighted = option.id } }
                            .accessibilityAddTraits(option.id == selected ? .isSelected : [])
                        }
                        if filtered.isEmpty {
                            Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                        }
                    }
                }
                .frame(height: listHeight)
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
                .onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
            }
        }
        .padding(4)
        .focusable(!searchable).focused($listFocused)
        .focusEffectDisabled()
        .onAppear { highlighted = selected }
        .task {
            // The hosting view is measured before its child window becomes key.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if searchable { searchFocused = true } else { listFocused = true }
        }
        .onChange(of: query) { _, _ in highlighted = filtered.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let highlighted, filtered.contains(where: { $0.id == highlighted }) { select(highlighted) }
            return .handled
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : filtered.count)
        highlighted = filtered[min(max(index + delta, 0), filtered.count - 1)].id
    }
}

private struct EditorDropdownSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        }
    }
}

private struct EditorDropdownEntrance: ViewModifier {
    let reduceMotion: Bool
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : -4)
            .onAppear { withAnimation(.easeOut(duration: 0.1)) { shown = true } }
    }
}

@MainActor private final class EditorDropdownAnchor { weak var view: NSView? }
private struct EditorDropdownAnchorReader: NSViewRepresentable {
    let anchor: EditorDropdownAnchor
    func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
