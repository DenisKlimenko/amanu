import AppKit

/// The `calendars` setting as the Advanced tab shows it: a checkbox for every
/// calendar on the Mac, under the account it belongs to.
///
/// One control for the whole list, so that the settings window can go on
/// treating each setting as a single control it reads and writes. The cell is
/// there only to carry the target, action and tag that every other row's
/// control carries; nothing of it is drawn.
final class CalendarChecklist: NSControl {
    private let listing: () -> [MeetingCalendars.Account]?
    private let stack = NSStackView()
    private var boxes: [(key: String, box: NSButton)] = []
    /// What the rows were built from. A redraw rebuilds them only when the
    /// Mac's calendars have changed. Rebuilding on every redraw would also
    /// happen under the checkbox being clicked, since that click is what
    /// causes the redraw.
    private var accounts: [MeetingCalendars.Account]?
    private var isBuilt = false

    init(listing: @escaping () -> [MeetingCalendars.Account]?) {
        self.listing = listing
        super.init(frame: .zero)
        cell = NSActionCell()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// As tall as its rows, which the stack decides; the cell has no say.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// A click between the boxes is not a change of setting.
    override func mouseDown(with event: NSEvent) {}

    /// The calendars ticked, written the way the setting writes them.
    var ticked: [String] { boxes.filter { $0.box.state == .on }.map(\.key) }

    /// Show the setting as read. Nil — the key absent — ticks every box,
    /// because every calendar counts.
    func show(_ chosen: [String]?) {
        let current = listing()
        if !isBuilt || current != accounts { rebuild(current) }
        for (key, box) in boxes {
            box.state = MeetingCalendars.counts(key, chosen: chosen) ? .on : .off
        }
    }

    private func rebuild(_ accounts: [MeetingCalendars.Account]?) {
        self.accounts = accounts
        isBuilt = true
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        boxes = []

        guard let accounts else {
            let note = NSTextField(wrappingLabelWithString: localised(
                "No calendars to show: amanu has no access to them. Access is given on the Setup tab.",
                "Календарей не видно: у amanu нет к ним доступа. Доступ даётся на вкладке «Настройка»."))
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 260
            stack.addArrangedSubview(note)
            return
        }
        for account in accounts {
            let header = NSTextField(labelWithString: account.name)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for calendar in account.calendars {
                let box = NSButton(
                    checkboxWithTitle: calendar, target: self, action: #selector(boxClicked(_:)))
                // Calendars are often named after an email address, which
                // reads better cut in the middle than at its end.
                box.lineBreakMode = .byTruncatingMiddle
                box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(box)
                boxes.append((MeetingCalendars.key(account: account.name, calendar: calendar), box))
            }
        }
    }

    @objc private func boxClicked(_ sender: NSButton) {
        sendAction(action, to: target)
    }
}
