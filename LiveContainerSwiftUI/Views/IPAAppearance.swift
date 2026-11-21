import SwiftUI
import CoreText

enum IPAMotion {
    static func press(_ pressed: Bool, reduced: Bool) -> Animation {
        .easeOut(duration: reduced ? 0.1 : pressed ? 0.08 : 0.14)
    }
    static func state(reduced: Bool) -> Animation {
        .easeOut(duration: reduced ? 0.1 : 0.18)
    }
    static func reveal(reduced: Bool) -> AnyTransition {
        .opacity
    }
}

struct IPAPillStyle: ButtonStyle {
    var prominent = false
    var compact = false
    var alwaysFilled = false
    var minimumHeight: CGFloat? = nil
    @AppStorage("IPAFilledButtons") private var filledButtons = false
    @AppStorage("IPAAccentHex") private var accentHex = "systemBlue"
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let filled = alwaysFilled || (prominent && filledButtons)
        return configuration.label.ipaFont(.subheadline, weight: .semibold)
            .lineLimit(1).fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(filled ? IPAAppearance.buttonForeground(accentHex) : IPAAppearance.accent(accentHex))
            .padding(.horizontal, compact ? 13 : 18).frame(minWidth: 66, minHeight: minimumHeight ?? (compact ? 30 : 34))
            .background(filled ? IPAAppearance.accent(accentHex) : Color(uiColor: scheme == .dark ? .tertiarySystemFill : .secondarySystemFill), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
            .animation(IPAMotion.press(configuration.isPressed, reduced: reduceMotion), value: configuration.isPressed)
    }
}

private struct IPAAccentKey: EnvironmentKey { static let defaultValue = Color(uiColor: .systemBlue) }
extension EnvironmentValues {
    var ipaAccent: Color { get { self[IPAAccentKey.self] } set { self[IPAAccentKey.self] = newValue } }
}

struct IPAFontChoice: Identifiable {
    let id: String
    let name: String
    var postScript: String? = nil

    static let choices: [Self] = [
        .init(id: "system", name: "System"), .init(id: "rounded", name: "Rounded"),
        .init(id: "serif", name: "System Serif"), .init(id: "mono", name: "Monospaced"),
        .init(id: "avenir", name: "Avenir Next", postScript: "AvenirNext-Regular"),
        .init(id: "futura", name: "Futura", postScript: "Futura-Medium"),
        .init(id: "gill", name: "Gill Sans", postScript: "GillSans"),
        .init(id: "optima", name: "Optima", postScript: "Optima-Regular"),
        .init(id: "newYork", name: "Baskerville", postScript: "Baskerville"),
        .init(id: "georgia", name: "Georgia", postScript: "Georgia"),
        .init(id: "palatino", name: "Palatino", postScript: "Palatino-Roman"),
        .init(id: "courier", name: "Courier New", postScript: "CourierNewPSMT"),
        .init(id: "pixel", name: "Monocraft", postScript: "Monocraft")
    ]
    static func face(for id: String) -> String? { choices.first { $0.id == id }?.postScript }

    var previewFont: Font {
        if let postScript { return .custom(postScript, size: 17, relativeTo: .body) }
        switch id {
        case "rounded": return .system(.body, design: .rounded)
        case "serif": return .system(.body, design: .serif)
        case "mono": return .system(.body, design: .monospaced)
        default: return .system(.body, design: .default)
        }
    }
}

enum IPAAppSubtitle: String, CaseIterable, Identifiable {
    case none, version, description
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "None"
        case .version: "Version"
        case .description: "Description"
        }
    }
}

enum IPAAppearance {
    static func accent(_ hex: String) -> Color {
        // Migrate the previous default to Apple's adaptive native blue. Custom
        // colors remain literal values; the default follows appearance/contrast.
        if hex == "systemBlue" || hex.uppercased() == "007AFF" { return Color(uiColor: .systemBlue) }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Color(uiColor: .systemBlue) }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    static func buttonForeground(_ hex: String) -> Color {
        guard let value = UInt32(hex, radix: 16) else { return .white }
        let luminance = (Double((value >> 16) & 255) * 0.2126 + Double((value >> 8) & 255) * 0.7152 + Double(value & 255) * 0.0722) / 255
        return luminance > 0.68 ? .black : .white
    }
    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    static func uiFont(size: CGFloat, style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let choice = UserDefaults.standard.string(forKey: "IPAFontChoice") ?? "system"
        let bold = UserDefaults.standard.bool(forKey: "IPABoldText") && !UIAccessibility.isBoldTextEnabled
        var base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : weight)
        if let face = IPAFontChoice.face(for: choice), let chosen = UIFont(name: face, size: size) {
            base = chosen
            if bold || weight >= .semibold, let descriptor = chosen.fontDescriptor.withSymbolicTraits(.traitBold) {
                base = UIFont(descriptor: descriptor, size: size)
            }
        } else if ["rounded", "serif", "mono"].contains(choice) {
            let design: UIFontDescriptor.SystemDesign = choice == "rounded" ? .rounded : choice == "serif" ? .serif : .monospaced
            if let descriptor = base.fontDescriptor.withDesign(design) { base = UIFont(descriptor: descriptor, size: size) }
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
    private static let registration: Void = {
        guard let url = Bundle.main.url(forResource: "Monocraft", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
    static func registerFonts() { _ = registration }
}

struct IPATheme: ViewModifier {
    @AppStorage("IPAAccentHex") private var hex = "systemBlue"
    @AppStorage("IPAFontChoice") private var font = "system"
    @AppStorage("IPABoldText") private var bold = false
    func body(content: Content) -> some View {
        content.tint(IPAAppearance.accent(hex)).accentColor(IPAAppearance.accent(hex))
            .environment(\.ipaAccent, IPAAppearance.accent(hex))
            .fontWeight(bold && !UIAccessibility.isBoldTextEnabled ? .bold : nil)
            .fontDesign(font == "rounded" ? .rounded : font == "serif" ? .serif : font == "mono" || font == "pixel" ? .monospaced : .default)
            .task { IPAAppearance.registerFonts() }
            .onAppear {
                applyWindowTint(hex)
                if UIAccessibility.isBoldTextEnabled { bold = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.boldTextStatusDidChangeNotification)) { _ in
                if UIAccessibility.isBoldTextEnabled { bold = false }
            }
            .onChange(of: hex) { _, value in
                applyWindowTint(value)
            }
    }
    private func applyWindowTint(_ value: String) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.tintColor = UIColor(IPAAppearance.accent(value)) }
        }
    }
}
private struct IPAFontModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight
    @AppStorage("IPAFontChoice") private var choice = "system"
    @AppStorage("IPABoldText") private var bold = false
    private var font: Font {
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 34, .title: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17, .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11]
        if let face = IPAFontChoice.face(for: choice) {
            return .custom(face, size: sizes[style] ?? 17, relativeTo: style).weight(bold && !UIAccessibility.isBoldTextEnabled ? .bold : weight)
        }
        let design: Font.Design = choice == "rounded" ? .rounded : choice == "serif" ? .serif : choice == "mono" ? .monospaced : .default
        return .system(style, design: design).weight(bold && !UIAccessibility.isBoldTextEnabled ? .bold : weight)
    }
    func body(content: Content) -> some View { content.font(font) }
}
extension View {
    func ipaFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View { modifier(IPAFontModifier(style: style, weight: weight)) }
}

struct IPAAppearanceView: View {
    @AppStorage("IPASuccessSound") private var sound = IPAFeedback.Sound.selected
    @AppStorage("IPAHapticStyle") private var haptic = IPAFeedback.Haptic.selected
    @AppStorage("IPAInstalledAppSubtitle") private var subtitle = IPAAppSubtitle.none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("IPAAppearance") private var mode = "system"
    @AppStorage("IPAAccentHex") private var hex = "systemBlue"
    @AppStorage("IPAFontChoice") private var font = "system"
    @AppStorage("IPABoldText") private var bold = false
    @AppStorage("IPAFilledButtons") private var filledButtons = false
    @State private var systemBold = UIAccessibility.isBoldTextEnabled
    var body: some View {
        Form {
            Section("Preview") {
                HStack(spacing: 14) {
                    IPABrandGlyph(size: 44)
                    Text("iPAStore").ipaFont(.headline, weight: .semibold)
                    Spacer(minLength: 4)
                    Text("Open").ipaFont(.subheadline, weight: .bold).foregroundStyle(.tint).padding(.horizontal, 14).padding(.vertical, 8).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }.padding(.vertical, 8)
            }
            Section("Display") {
                Picker("Appearance", selection: $mode) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    .pickerStyle(.menu).tint(.secondary)
                ColorPicker("Accent Color", selection: Binding(get: { IPAAppearance.accent(hex) }, set: { selectAccent(IPAAppearance.hex($0)) }), supportsOpacity: false)
                HStack {
                    ForEach(["systemBlue", "AF52DE", "FFCC00", "FF2D55", "34C759", "FF9500"], id: \.self) { value in
                        Button { selectAccent(value) } label: {
                            Circle().fill(IPAAppearance.accent(value)).frame(width: 32, height: 32)
                                .overlay { if (hex == value || (value == "systemBlue" && hex.uppercased() == "007AFF")) { Image(systemName: "checkmark").foregroundStyle(value == "FFCC00" ? .black : .white).font(.caption.bold()).transition(IPAMotion.reveal(reduced: reduceMotion)) } }.frame(maxWidth: .infinity, minHeight: 44)
                                .animation(IPAMotion.state(reduced: reduceMotion), value: hex)
                        }.buttonStyle(IPAControlPressStyle()).accessibilityLabel(["systemBlue": "Blue", "AF52DE": "Purple", "FFCC00": "Yellow", "FF2D55": "Pink", "34C759": "Green", "FF9500": "Orange"][value] ?? value).accessibilityAddTraits((hex == value || (value == "systemBlue" && hex.uppercased() == "007AFF")) ? .isSelected : [])
                    }
                }
            }
            Section {
                NavigationLink {
                    IPAFontPicker(selection: $font)
                } label: {
                    LabeledContent("Font", value: IPAFontChoice.choices.first { $0.id == font }?.name ?? "System")
                }
                Toggle("Bold Text", isOn: $bold).disabled(systemBold)
            } header: { Text("Typography") }
            Section("Home Screen") {
                NavigationLink { IPAIconPicker() } label: { Label("App Icon", systemImage: "app") }
            }
            Section("Apps") {
                Picker("Under App Names", selection: $subtitle) {
                    ForEach(IPAAppSubtitle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.navigationLink)
                Picker("Button Style", selection: $filledButtons) {
                    Text("Default").tag(false)
                    Text("Colored").tag(true)
                }.pickerStyle(.menu).tint(.secondary)
            }
            Section("Sounds & Haptics") {
                NavigationLink {
                    feedbackChoices("Success Sound", options: IPAFeedback.Sound.allCases, selection: $sound) { IPAFeedback.preview($0) }
                } label: { feedbackRow("Success Sound", value: sound.title, symbol: "waveform") }
                NavigationLink {
                    feedbackChoices("Haptic Feedback", options: IPAFeedback.Haptic.allCases, selection: $haptic) { IPAFeedback.preview($0) }
                } label: { feedbackRow("Haptic Feedback", value: haptic.title, symbol: "iphone.radiowaves.left.and.right") }
            }
            Section { Button("Reset Appearance") { mode = "system"; hex = "systemBlue"; font = "system"; bold = false; subtitle = .none; filledButtons = false } }
        }.navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .modifier(IPATheme())
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.boldTextStatusDidChangeNotification)) { _ in
                systemBold = UIAccessibility.isBoldTextEnabled
            }
            .preferredColorScheme(mode == "light" ? .light : mode == "dark" ? .dark : nil)
    }

    private func selectAccent(_ value: String) {
        guard hex != value else { return }
        hex = value
        IPAFeedback.accentChanged()
    }

    private func feedbackRow(_ title: LocalizedStringKey, value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func feedbackChoices<Option: IPAFeedbackOption, Options: RandomAccessCollection>(
        _ title: String, options: Options, selection: Binding<Option>, preview: @escaping (Option) -> Void
    ) -> some View where Options.Element == Option {
        List(options) { option in
            Button {
                selection.wrappedValue = option
                preview(option)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: option.symbol).foregroundStyle(.tint).frame(width: 24)
                    Text(option.title).ipaFont(.body).foregroundStyle(.primary)
                    Spacer()
                    if selection.wrappedValue == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }.padding(.vertical, 8)
            }.accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

private struct IPAFontPicker: View {
    @Binding var selection: String

    var body: some View {
        List(IPAFontChoice.choices.filter { $0.postScript.map { UIFont(name: $0, size: 17) != nil } ?? true }) { choice in
            Button {
                selection = choice.id
            } label: {
                HStack {
                    Text(choice.name).font(choice.previewFont).foregroundStyle(.primary)
                    Spacer()
                    if selection == choice.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                    }
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == choice.id ? .isSelected : [])
        }.navigationTitle("Font").navigationBarTitleDisplayMode(.inline).ipaNativePage()
    }
}

struct IPACollectionControlIcon: View {
    let symbol: String
    @AppStorage("IPAFilledButtons") private var filled = false
    @Environment(\.ipaAccent) private var accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(filled ? accent : Color.primary)
    }
}

struct IPACollectionActionTile: ViewModifier {
    @AppStorage("IPAFilledButtons") private var filled = false
    @AppStorage("IPAAccentHex") private var hex = "systemBlue"

    func body(content: Content) -> some View {
        content
            .foregroundStyle(filled ? IPAAppearance.buttonForeground(hex) : Color.primary)
            .background(filled ? IPAAppearance.accent(hex) : IPAStyle.card, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct IPAIconPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var error: String?
    @State private var iconChanged = false
    private let choices: [(String, String?, String)] = [("Automatic", nil, "IconPreviewDefault"), ("Light", "AppIconLight", "IconPreviewLight"), ("Midnight", "AppIconMidnight", "IconPreviewMidnight"),
        ("Ocean", "AppIconOcean", "IconPreviewOcean"), ("Jade", "AppIconJade", "IconPreviewJade"),
        ("Iris", "AppIconIris", "IconPreviewIris"), ("Ember", "AppIconEmber", "IconPreviewEmber"),
        ("Sand", "AppIconSand", "IconPreviewSand"), ("Rose", "AppIconRose", "IconPreviewRose")
    ]
    var body: some View {
        List {
            ForEach(choices, id: \.0) { name, icon, asset in
                Button {
                    guard UIApplication.shared.supportsAlternateIcons else {
                        error = "Icon changes are unavailable on this installation."
                        return
                    }
                    guard current != icon else { return }
                    changing = true
                    iconChanged = false
                    Task { @MainActor in
                        defer { changing = false }
                        do {
                            try await UIApplication.shared.setAlternateIconName(icon)
                            current = UIApplication.shared.alternateIconName
                            guard current == icon else {
                                self.error = "iOS didn’t apply the selected icon. Try again while iPAStore is open."
                                return
                            }
                            IPAFeedback.confirmationHaptic()
                            iconChanged = true
                        } catch {
                            self.error = "The icon couldn’t be changed. Try again while iPAStore is open."
                        }
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(asset).resizable().scaledToFit().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if current == icon { Image(systemName: "checkmark").foregroundStyle(.tint).transition(IPAMotion.reveal(reduced: reduceMotion)) }
                    }.padding(.vertical, 6).contentShape(Rectangle())
                        .animation(IPAMotion.state(reduced: reduceMotion), value: current)
                }.buttonStyle(IPAControlPressStyle(scale: 0.985)).disabled(changing)
            }
        }.navigationTitle("App Icon").navigationBarTitleDisplayMode(.inline).ipaNativePage()
            .safeAreaInset(edge: .bottom) {
                if iconChanged {
                    Label("Icon successfully changed!", systemImage: "checkmark.circle.fill")
                        .ipaFont(.subheadline, weight: .semibold)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            .alert("App Icon", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}


struct IPAControlPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(IPAMotion.press(configuration.isPressed, reduced: reduceMotion), value: configuration.isPressed)
    }
}
