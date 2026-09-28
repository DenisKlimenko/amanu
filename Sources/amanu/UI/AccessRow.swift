import AppKit

/// A row in the Access list: where it stands, what it's for, and the one
/// button that changes it.
@MainActor
final class AccessRow: NSView, LayerTinted {
    var onAct: (() -> Void)?

    /// Whether this is the row being asked for right now; see `setAttention`.
    private var wantsAttention = false

    private let mark = NSImageView()
    private let title: NSTextField
    private let note = NSTextField(labelWithString: "")
    private let detail: NSTextField
    private let button: NSButton
    private let stack: NSStackView
    private let defaultDetail: String
    private let defaultAction: String
    private let grantedNote: String
    private let isOptional: Bool

    init(title: String, detail: String, action: String,
         grantedNote: String = localised("granted", "разрешено"), optional: Bool = false) {
        self.title = NSTextField(labelWithString: title)
        self.detail = NSTextField(labelWithString: detail)
        self.defaultDetail = detail
        self.defaultAction = action
        self.grantedNote = grantedNote
        self.isOptional = optional
        button = NSButton(title: action, target: nil, action: nil)
        stack = NSStackView()
        super.init(frame: .zero)

        self.title.font = SetupLayout.titleFont
        note.font = SetupLayout.detailFont
        note.textColor = .tertiaryLabelColor
        wantsLayer = true

        self.detail.font = SetupLayout.detailFont
        self.detail.textColor = .secondaryLabelColor
        self.detail.lineBreakMode = .byWordWrapping
        self.detail.maximumNumberOfLines = 3
        self.detail.preferredMaxLayoutWidth = 460

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(act)

        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let heading = NSStackView(views: [self.title, note])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 6

        let text = NSStackView(views: [heading, self.detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        for view in [mark, text, SetupLayout.spacer(), button] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = SetupLayout.rowInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Every granted row carries one line and they have to look it; a row
        // still explaining itself has to keep the inset under its last line.
        // Both are the same arithmetic every other row gets.
        SetupLayout.fitRowHeight(stack)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The row's button is found by the row's name with `.action` after it.
    override var identifier: NSUserInterfaceItemIdentifier? {
        didSet { button.identifier = identifier.map { .init($0.rawValue + ".action") } }
    }

    func tintLayer() {
        layer?.backgroundColor = wantsAttention
            ? NSColor.systemOrange.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retint()
    }

    @objc private func act() { onAct?() }

    /// Say that something is happening, so a button that takes a second
    /// doesn't look like a button that did nothing.
    func working(_ message: String) {
        button.isEnabled = false
        detail.stringValue = message
        detail.isHidden = false
    }

    /// The one row the person is being asked to act on right now is tinted.
    /// macOS shows one TCC dialog at a time, so more than one highlighted row
    /// would be pointing at work that cannot be done yet.
    func setAttention(_ on: Bool) {
        wantsAttention = on
        retint()
        title.textColor = on ? .systemOrange : .labelColor
        detail.textColor = on ? .systemOrange : .secondaryLabelColor
        if on {
            mark.image = NSImage(
                systemSymbolName: "exclamationmark.circle",
                accessibilityDescription: localised(
                    "needs your attention", "требует внимания"))
            mark.contentTintColor = .systemOrange
        }
    }

    /// The button's name for a screen reader: what it does and to what.
    /// "Allow" four times down a list says nothing about which of the four
    /// grants each one asks for.
    private func nameButton() {
        button.setAccessibilityLabel("\(button.title) — \(title.stringValue)")
    }

    /// `action` keeps a button on a granted row — for the one permission
    /// macOS will not report, where "granted" is a measurement someone may
    /// reasonably want to take again.
    func update(
        _ state: SetupPermissions.State,
        detail override: String? = nil,
        note noteOverride: String? = nil,
        action actionTitle: String? = nil
    ) {
        button.isEnabled = true
        button.title = actionTitle ?? defaultAction
        detail.stringValue = override ?? defaultDetail

        // A granted permission is one line: the title and how it stands. The
        // reasoning underneath is there to talk someone into granting it, and
        // it has nothing left to say once they have.
        let settled = state == .granted && override == nil
        detail.isHidden = settled || detail.stringValue.isEmpty
        // A row that is down to its title is one line, and sits in the middle
        // of the row like one; a row still explaining itself starts at the
        // top, beside its first line.
        stack.alignment = detail.isHidden ? .centerY : .top
        note.stringValue = noteOverride ?? {
            switch state {
            case .granted: return grantedNote
            case .notAsked, .unknown:
                return isOptional ? localised("optional", "не обязательно") : ""
            case .denied: return ""
            }
        }()
        note.isHidden = note.stringValue.isEmpty

        switch state {
        case .granted:
            mark.image = NSImage(
                systemSymbolName: "checkmark.circle",
                accessibilityDescription: localised("granted", "разрешено"))
            mark.contentTintColor = .systemGreen
            button.isHidden = actionTitle == nil
        case .denied:
            mark.image = NSImage(
                systemSymbolName: "exclamationmark.circle",
                accessibilityDescription: localised("denied", "запрещено"))
            mark.contentTintColor = .systemOrange
            button.isHidden = false
            button.title = localised("Open Settings", "Открыть настройки")
        case .notAsked, .unknown:
            mark.image = NSImage(
                systemSymbolName: "circle.dashed",
                accessibilityDescription: localised("not asked", "не спрашивали"))
            mark.contentTintColor = .tertiaryLabelColor
            button.isHidden = false
        }
        nameButton()
    }
}
