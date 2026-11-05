#if os(macOS)
import AppKit
import Combine

/// The « Écran rouge » items of Goalong's right-click menu. Standard items stay reachable with the
/// keyboard and VoiceOver; the slider row adds a live, continuous control for the pointer.
@MainActor final class RedScreenMenu: NSObject, NSMenuItemValidation {
    static let intensitySteps = [0.25, 0.5, 0.75, 1.0]
    private let control: any RedScreenControlling
    private let onOpenSettings: () -> Void
    let toggleItem = NSMenuItem(title: "Écran rouge", action: nil, keyEquivalent: "")
    let sliderItem = NSMenuItem()
    /// « Plage protégée jusqu’à 07:00 : 80 % au moins », under the slider while a protected range holds it.
    let noticeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let intensityItem = NSMenuItem(title: "Intensité", action: nil, keyEquivalent: "")
    let scheduleItem = NSMenuItem(title: "Suivre mes horaires", action: nil, keyEquivalent: "")
    let restoreItem = NSMenuItem(title: "Rétablir les couleurs", action: nil, keyEquivalent: "r")
    let settingsItem = NSMenuItem(title: "Plages et réglages de l’écran rouge…", action: nil, keyEquivalent: "")
    let separator = NSMenuItem.separator()
    let slider: RedScreenMenuSliderView
    private let intensityMenu = NSMenu(title: "Intensité")
    private var watch: AnyCancellable?

    var items: [NSMenuItem] { [toggleItem, sliderItem, noticeItem, intensityItem, scheduleItem, restoreItem, settingsItem] }

    init(control: any RedScreenControlling, onOpenSettings: @escaping () -> Void) {
        self.control = control; self.onOpenSettings = onOpenSettings
        slider = RedScreenMenuSliderView(onChange: { _ in })
        super.init()
        slider.onChange = { [weak self] in self?.slide($0) }
        for (item, action) in [(toggleItem, #selector(toggle)), (scheduleItem, #selector(followSchedule)),
                               (restoreItem, #selector(restore)), (settingsItem, #selector(openSettings))] {
            item.target = self; item.action = action
        }
        // Same chord as the global shortcut, shown so it can be learned here.
        restoreItem.keyEquivalentModifierMask = [.control, .option, .command]
        sliderItem.view = slider
        noticeItem.isEnabled = false
        for step in Self.intensitySteps {
            let item = NSMenuItem(title: GoalongUIFormat.percent(step * 100), action: #selector(chooseIntensity(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = step; intensityMenu.addItem(item)
        }
        intensityItem.submenu = intensityMenu
        refresh(control.redScreen)
        watch = control.redScreenChanges.sink { [weak self] in self?.refresh($0) }
    }

    func refresh(_ state: RedScreenState) {
        toggleItem.state = state.on ? .on : .off
        toggleItem.setAccessibilityValueDescription(state.on ? "activé" : "désactivé")
        scheduleItem.state = state.followsSchedule ? .on : .off
        restoreItem.isEnabled = state.on
        restoreItem.toolTip = state.isProtected ? "Plage protégée : l’arrêt passe par Garde-fous › Écran rouge." : nil
        slider.value = state.intensity
        noticeItem.title = state.notice ?? ""; noticeItem.isHidden = state.notice == nil
        let percent = Int((state.intensity * 100).rounded())
        for item in intensityMenu.items { item.state = Int(((item.representedObject as? Double ?? 0) * 100).rounded()) == percent ? .on : .off }
    }
    @objc private func toggle() { control.setRedScreen(!control.redScreen.on) }
    @objc private func followSchedule() { control.setRedScreenFollowsSchedule(!control.redScreen.followsSchedule) }
    /// The menu auto-enables items with a target: « Rétablir les couleurs » is greyed here while red is off.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item === noticeItem ? false : item === restoreItem ? control.redScreen.on : true
    }
    /// A protected range may hold the value where it is (same state, nothing published): the thumb goes back to it.
    private func slide(_ value: Double) { control.setRedScreenIntensity(value); refresh(control.redScreen) }
    @objc private func restore() { control.restoreColors() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func chooseIntensity(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { control.setRedScreenIntensity(value) }
    }
}

/// One menu row: a continuous slider (live effect while dragging) and its percentage.
final class RedScreenMenuSliderView: NSView {
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: GoalongUIFormat.percent(100))
    var onChange: (Double) -> Void
    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = newValue; label.stringValue = Self.percent(newValue)
              slider.setAccessibilityValueDescription(Self.percent(newValue)) }
    }
    init(onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityLabel("Intensité de l’écran rouge")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setAccessibilityElement(false)
        for view in [slider, label] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 40),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func changed() {
        // VoiceOver reads the new value at each step, not the one set at opening.
        let text = Self.percent(slider.doubleValue)
        label.stringValue = text; slider.setAccessibilityValueDescription(text); onChange(slider.doubleValue)
    }
    var accessibilityValueText: String? { slider.accessibilityValueDescription() }
    /// Test hook: the same path as a drag.
    func simulateDrag(to value: Double) { slider.doubleValue = value; changed() }
    static func percent(_ value: Double) -> String { GoalongUIFormat.percent(value * 100) }
}
#endif
