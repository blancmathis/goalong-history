#if os(macOS)
import SwiftUI

/// T-060: « Luminosité max du clavier », on the Réglages home. Off by default; no protection, no rule: the member turns
/// it off at any time and macOS has the backlight again.
struct KeyboardBacklightSettings: View {
    typealias Limit = KeyboardBacklightLimit
    @AppStorage(Limit.enabledKey) private var enabled = false
    @AppStorage(Limit.maximumKey) private var maximum = Limit.defaultMaximum
    @AppStorage(Limit.scheduledKey) private var scheduled = false
    @AppStorage(Limit.startMinuteKey) private var startMinute = Limit.defaultStartMinute
    @AppStorage(Limit.endMinuteKey) private var endMinute = Limit.defaultEndMinute
    /// Nil = not known (gallery, tests): no warning shown.
    var available: Bool? = KeyboardBacklightLimiter.running?.isAvailable

    static func matches(_ raw: String) -> Bool {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        let haystack = "clavier luminosité rétroéclairage lumière touches nuit"
        return haystack.localizedStandardContains(query)
            || query.split(whereSeparator: \.isWhitespace).contains { $0.count >= 4 && haystack.localizedStandardContains(String($0)) }
    }

    /// « 0,5 % », « 1 % », « 6,5 % ».
    static func percent(_ value: Double) -> String {
        let tenths = (value * 1000).rounded() / 10
        let text = tenths.rounded() == tenths ? String(Int(tenths)) : String(format: "%.1f", tenths).replacingOccurrences(of: ".", with: ",")
        return "\(text)\u{00A0}%"
    }

    var body: some View {
        GoalongSettingsGroup(title: "Clavier") {
            Toggle("Luminosité max du clavier", isOn: $enabled)
                .toggleStyle(.goalongSwitch)
                .accessibilityIdentifier("settings-keyboard-backlight")
            Text(enabled
                 ? "Si le clavier s’éclaire plus fort, Goalong le ramène à ce maximum. Désactivé, macOS reprend la main."
                 : "Fixe un maximum au rétroéclairage du clavier, plus bas que le premier cran de macOS si besoin.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if available == false {
                Text("Aucun clavier rétroéclairé réglable n’a été trouvé sur ce Mac.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
            if enabled { details }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Maximum").font(.system(size: 13))
                Spacer()
                Text(maximum <= 0 ? "Éteint" : Self.percent(maximum)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
            }
            Slider(value: Binding(get: { Limit.clampedMaximum(maximum) }, set: { maximum = Limit.clampedMaximum($0) }),
                   in: Limit.range, step: Limit.step)
                .accessibilityLabel("Luminosité maximale du clavier")
                .accessibilityValue(maximum <= 0 ? "Éteint" : Self.percent(maximum))
                .accessibilityIdentifier("settings-keyboard-backlight-maximum")
            Text("Le premier cran de la touche de macOS vaut 6,25\u{00A0}%. En dessous, le clavier éclaire moins que macOS ne le permet.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Seulement à certaines heures", isOn: $scheduled)
            .toggleStyle(.goalongSwitch)
            .accessibilityIdentifier("settings-keyboard-backlight-scheduled")
        if scheduled {
            HStack(spacing: 12) {
                Text("De").font(.system(size: 13))
                DatePicker("De", selection: time($startMinute), displayedComponents: .hourAndMinute).goalongDateField()
                    .fixedSize().padding(.trailing, 6)
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                Text("à").font(.system(size: 13))
                DatePicker("à", selection: time($endMinute), displayedComponents: .hourAndMinute).goalongDateField()
                    .fixedSize().padding(.trailing, 6)
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                if endMinute < startMinute { Text("le lendemain").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText) }
                if endMinute == startMinute { Text("toute la journée").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText) }
            }
        }
    }

    private func time(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: GoalongToday.now).addingTimeInterval(TimeInterval(Limit.clampedMinute(minute.wrappedValue) * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = Limit.clampedMinute((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
    }
}
#endif
