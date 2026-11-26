import AppKit
import SwiftUI

struct PresentedRow: Equatable, Identifiable, Sendable {
    let id: Item.ID
    let title: String
    let subtitle: String
    let icon: RowIcon
    let badge: String
    let selected: Bool
    var titleMarks: [Mark] = []
    var subtitleMarks: [Mark] = []
    var badgeMarks: [Mark] = []
}

struct LauncherView: View {
    let launcher: Launcher
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let palette = launcher.theme.palette(for: colorScheme)
        let rows = launcher.rows
        VStack(spacing: 0) {
            TextField(
                "",
                text: Binding(
                    get: { launcher.query },
                    set: { launcher.send(.query($0)) }
                ),
                prompt: Text(launcher.prompt).foregroundColor(palette.placeholder)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .focused($fieldFocused)
            .background(FieldFocus(active: fieldFocused))
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            RowView(row: row, palette: palette)
                                .id(row.id)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .focusable(false)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 8)
                        Rectangle()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    let footer = launcher.footer
                    if !footer.isEmpty {
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            ForEach(footer) { item in
                                ActionPill(item: item, palette: palette)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
                .onChange(of: rows.first(where: \.selected)?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    fieldFocused = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanelBackground(palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.text.opacity(0.7), lineWidth: 1)
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: launcher.generation) { _, _ in
            fieldFocused = true
        }
    }
}

private struct PanelBackground: View {
    let palette: Palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            palette.background
        } else if #available(macOS 26.0, *) {
            palette.background.opacity(0.15)
        } else {
            Rectangle()
                .fill(.thinMaterial)
                .overlay(palette.background.opacity(0.8))
        }
    }
}

@MainActor
private enum Icons {
    private static var cache: [RowIcon: NSImage] = [:]
    private static var photos: [String: NSImage] = [:]

    static func image(_ icon: RowIcon) -> NSImage? {
        switch icon {
        case .picture(let data, _):
            return decoded(icon, data)
        case .remote:
            return nil
        case .symbol(let name):
            if let cached = cache[icon] { return cached }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if let image { cache[icon] = image }
            return image
        case .file, .application, .bundled:
            if let cached = cache[icon] { return cached }
            let image = file(icon)
            if let image { cache[icon] = image }
            return image
        }
    }

    static func cachedPhoto(_ url: String) -> NSImage? { photos[url] }

    static func fetch(_ urlString: String) async -> NSImage? {
        if let cached = photos[urlString] { return cached }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 2_000_000,
              let image = NSImage(data: data), image.isValid
        else { return nil }
        photos[urlString] = image
        return image
    }

    private static func decoded(_ icon: RowIcon, _ data: Data) -> NSImage? {
        if let cached = cache[icon] { return cached }
        guard let image = NSImage(data: data), image.isValid else { return nil }
        cache[icon] = image
        return image
    }

    private static func file(_ icon: RowIcon) -> NSImage? {
        switch icon {
        case .file(let path):
            return NSWorkspace.shared.icon(forFile: path)
        case .application(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .bundled(let name):
            let image = Bundle.main.url(forResource: name, withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            image?.isTemplate = true
            return image ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        case .picture, .remote, .symbol:
            return nil
        }
    }
}

private struct IconSlot: View {
    let icon: RowIcon
    let palette: Palette
    @State private var fetched: NSImage?

    var body: some View {
        let photo = portrait
        Group {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
            } else if case .picture = icon, let image = Icons.image(icon) {
                // App icons carry macOS's baked-in padding (~22pt of artwork in the 28pt
                // slot); favicons are full-bleed, so inset them to the same visual size.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    // Hairline keeps white-on-transparent favicons visible on light themes.
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(palette.rule, lineWidth: 0.5)
                    )
                    .frame(width: 28, height: 28)
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
            } else if let image = fallback {
                Image(nsImage: image)
                    .renderingMode(icon.template ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(palette.text)
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
            }
        }
        .task(id: remoteURL) {
            guard let remoteURL else { return }
            fetched = await Icons.fetch(remoteURL)
        }
    }

    private var portrait: NSImage? {
        guard let remoteURL else { return nil }
        return fetched ?? Icons.cachedPhoto(remoteURL)
    }

    private var remoteURL: String? {
        if case .remote(let url, _) = icon { return url }
        return nil
    }

    private var fallback: NSImage? {
        switch icon {
        case .remote(_, let bundleID), .picture(_, let bundleID):
            return Icons.image(.application(bundleID))
        default:
            return Icons.image(icon)
        }
    }
}

private struct RowView: View {
    let row: PresentedRow
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            IconSlot(icon: row.icon, palette: palette)
            VStack(alignment: .leading, spacing: 2) {
                styled(row.title, marks: row.titleMarks, base: palette.text, hit: palette.accent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    styled(row.subtitle, marks: row.subtitleMarks, base: palette.muted, hit: palette.accent)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 13)
            Spacer(minLength: 8)
            if !row.badge.isEmpty {
                styled(row.badge, marks: row.badgeMarks, base: palette.muted, hit: palette.accent)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
        .background(
            row.selected ? palette.row : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .focusable(false)
    }
}

private struct ActionPill: View {
    let item: LauncherState.FooterItem
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            Text(item.title)
                .foregroundStyle(palette.text)
            Text(item.keyLabel)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    palette.text.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            palette.text.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [palette.text.opacity(0.22), palette.text.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
    }
}

private func styled(_ text: String, marks: [Mark], base: Color, hit: Color) -> Text {
    let chars = Array(text)
    guard !marks.isEmpty, !chars.isEmpty else {
        return Text(text).foregroundStyle(base)
    }
    var covered = Array(repeating: false, count: chars.count)
    for mark in marks {
        let end = min(chars.count, mark.start + mark.length)
        guard mark.start >= 0, mark.start < end else { continue }
        for index in mark.start..<end { covered[index] = true }
    }
    var result = Text("")
    var index = 0
    while index < chars.count {
        let flag = covered[index]
        var next = index + 1
        while next < chars.count, covered[next] == flag { next += 1 }
        let piece = String(chars[index..<next])
        if flag {
            result = result + Text(piece).foregroundStyle(hit).fontWeight(.semibold)
        } else {
            result = result + Text(piece).foregroundStyle(base)
        }
        index = next
    }
    return result
}

private struct FieldFocus: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard active else { return }
        DispatchQueue.main.async {
            guard let window = view.window, let field = textField(in: window.contentView) else { return }
            if let editor = field.currentEditor(), window.firstResponder === editor { return }
            if window.firstResponder !== field {
                window.makeFirstResponder(field)
            }
        }
    }

    private func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }
}
