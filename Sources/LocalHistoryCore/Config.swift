import Foundation

public enum CaptureListMode: String, Codable, CaseIterable {
    /// Capture every source except entries explicitly listed in the exclusion list.
    case excludeListed
    /// Capture only sources explicitly listed in the inclusion list.
    case includeOnly
}

public struct RecorderConfig: Codable, Equatable {
    public var retentionDays: Int
    public var pollIntervalMilliseconds: Int
    public var heartbeatSeconds: Int

    public var captureClicks: Bool
    public var captureScroll: Bool
    public var captureKeyboardActivity: Bool
    public var captureShortcuts: Bool
    public var captureWindowTitles: Bool
    public var captureElementLabels: Bool
    public var captureURLs: Bool

    public var redactAllURLQueryValues: Bool
    public var maxStringLength: Int

    /// Optional verification endpoint. When nil, Goalong History stays fully local and only builds local seals.
    public var verificationServerURL: String?
    public var verificationEnabled: Bool?
    public var enableAppAttest: Bool?

    public var excludedBundleIdentifiers: [String]
    public var excludedDomains: [String]

    /// Optional for backwards-compatible decoding of config files written before
    /// include-only capture was implemented. `validated()` materializes explicit defaults.
    public var applicationCaptureMode: CaptureListMode?
    public var websiteCaptureMode: CaptureListMode?
    public var includedBundleIdentifiers: [String]?
    public var includedDomains: [String]?

    public var browserBundleIdentifiers: [String]
    public var privateWindowMarkers: [String]
    public var addressFieldMarkers: [String]

    public init(
        retentionDays: Int,
        pollIntervalMilliseconds: Int,
        heartbeatSeconds: Int,
        captureClicks: Bool,
        captureScroll: Bool,
        captureKeyboardActivity: Bool,
        captureShortcuts: Bool,
        captureWindowTitles: Bool,
        captureElementLabels: Bool,
        captureURLs: Bool,
        redactAllURLQueryValues: Bool,
        maxStringLength: Int,
        verificationServerURL: String? = nil,
        verificationEnabled: Bool? = false,
        enableAppAttest: Bool? = true,
        excludedBundleIdentifiers: [String],
        excludedDomains: [String],
        applicationCaptureMode: CaptureListMode? = .excludeListed,
        websiteCaptureMode: CaptureListMode? = .excludeListed,
        includedBundleIdentifiers: [String]? = [],
        includedDomains: [String]? = [],
        browserBundleIdentifiers: [String],
        privateWindowMarkers: [String],
        addressFieldMarkers: [String]
    ) {
        self.retentionDays = retentionDays
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.heartbeatSeconds = heartbeatSeconds
        self.captureClicks = captureClicks
        self.captureScroll = captureScroll
        self.captureKeyboardActivity = captureKeyboardActivity
        self.captureShortcuts = captureShortcuts
        self.captureWindowTitles = captureWindowTitles
        self.captureElementLabels = captureElementLabels
        self.captureURLs = captureURLs
        self.redactAllURLQueryValues = redactAllURLQueryValues
        self.maxStringLength = maxStringLength
        self.verificationServerURL = verificationServerURL
        self.verificationEnabled = verificationEnabled
        self.enableAppAttest = enableAppAttest
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludedDomains = excludedDomains
        self.applicationCaptureMode = applicationCaptureMode
        self.websiteCaptureMode = websiteCaptureMode
        self.includedBundleIdentifiers = includedBundleIdentifiers
        self.includedDomains = includedDomains
        self.browserBundleIdentifiers = browserBundleIdentifiers
        self.privateWindowMarkers = privateWindowMarkers
        self.addressFieldMarkers = addressFieldMarkers
    }

    public var effectiveApplicationCaptureMode: CaptureListMode {
        applicationCaptureMode ?? .excludeListed
    }

    public var effectiveWebsiteCaptureMode: CaptureListMode {
        websiteCaptureMode ?? .excludeListed
    }

    public var effectiveIncludedBundleIdentifiers: [String] {
        includedBundleIdentifiers ?? []
    }

    public var effectiveIncludedDomains: [String] {
        includedDomains ?? []
    }

    /// Application and website policies are deliberately independent. In include-only
    /// mode an unknown identity fails closed instead of being treated as implicitly allowed.
    public func allowsApplication(bundleIdentifier: String?) -> Bool {
        let normalized = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch effectiveApplicationCaptureMode {
        case .excludeListed:
            guard let normalized, !normalized.isEmpty else { return true }
            return !excludedBundleIdentifiers.contains {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }
        case .includeOnly:
            guard let normalized, !normalized.isEmpty else { return false }
            return effectiveIncludedBundleIdentifiers.contains {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }
        }
    }

    public func allowsWebsite(host: String?) -> Bool {
        switch effectiveWebsiteCaptureMode {
        case .excludeListed:
            return !URLRedactor.domain(host, matches: excludedDomains)
        case .includeOnly:
            guard let host, !host.isEmpty else { return false }
            return URLRedactor.domain(host, matches: effectiveIncludedDomains)
        }
    }

    public static let `default` = RecorderConfig(
        // Computer History's publicly documented temporary event window is 48 hours.
        // Existing user configs retain their explicit value during migration.
        retentionDays: 2,
        pollIntervalMilliseconds: 650,
        heartbeatSeconds: 60,
        captureClicks: true,
        captureScroll: true,
        captureKeyboardActivity: true,
        captureShortcuts: true,
        captureWindowTitles: true,
        captureElementLabels: true,
        captureURLs: true,
        redactAllURLQueryValues: true,
        maxStringLength: 512,
        verificationServerURL: nil,
        verificationEnabled: false,
        enableAppAttest: true,
        excludedBundleIdentifiers: [
            "ai.goalong.localhistory",
            "com.apple.Passwords",
            "com.apple.keychainaccess",
            "com.agilebits.onepassword7",
            "com.1password.1password",
            "com.bitwarden.desktop",
            "com.lastpass.LastPass",
            "com.dashlane.Dashlane",
            "org.keepassxc.keepassxc",
            "in.sinew.Enpass-Desktop",
            "com.callpod.keepermac",
            "org.torproject.torbrowser",
            "net.mullvad.mullvadbrowser",
            "com.apple.SafariTechnologyPreview.Passwords",
        ],
        excludedDomains: [],
        applicationCaptureMode: .excludeListed,
        websiteCaptureMode: .excludeListed,
        includedBundleIdentifiers: [],
        includedDomains: [],
        browserBundleIdentifiers: [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.dev",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.Beta",
            "com.microsoft.edgemac.Dev",
            "com.microsoft.edgemac.Canary",
            "com.brave.Browser",
            "com.brave.Browser.beta",
            "com.brave.Browser.nightly",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
            "io.gitlab.librewolf-community",
            "one.ablaze.floorp",
            "com.duckduckgo.macos.browser",
            "com.kagi.kagimacOS",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "com.operasoftware.OperaGX",
        ],
        privateWindowMarkers: [
            "incognito",
            "inprivate",
            "private browsing",
            "private window",
            "private mode",
            "private with tor",
            "navigation privée",
            "fenêtre privée",
            "mode privé",
            "navegación privada",
            "ventana privada",
            "navegação privada",
            "janela privada",
            "navigazione anonima",
            "finestra anonima",
            "navigazione privata",
            "privates surfen",
            "privates fenster",
            "inkognito",
            "privénavigatie",
            "privévenster",
            "prywatne przeglądanie",
            "okno prywatne",
            "частный просмотр",
            "приватное окно",
            "匿名浏览",
            "无痕浏览",
            "シークレット モード",
            "プライベートブラウズ",
            "시크릿 모드",
            "개인정보 보호 브라우징",
            "incógnito",
            "ventana de incógnito",
            "janela anônima",
            "navegação anônima",
            "in incognito",
            "modalità in incognito",
            "инкогнито",
            "التصفح المتخفي",
            "نافذة خاصة",
            "גלישה בסתר",
            "gizli mod",
            "gizli pencere",
            "privat surfing",
            "privat fönster",
            "privat vindue",
        ],
        addressFieldMarkers: [
            "address and search bar",
            "address bar",
            "search or enter website name",
            "smart search field",
            "location",
            "adresse et recherche",
            "barre d’adresse",
            "rechercher ou saisir une adresse",
            "dirección y búsqueda",
            "barra de direcciones",
            "adress- und suchleiste",
            "adressleiste",
            "barra degli indirizzi",
            "barra de endereço",
            "주소 및 검색창",
            "アドレス検索バー",
        ]
    )

    public func validated() -> RecorderConfig {
        var output = self
        output.retentionDays =
            output.retentionDays < 0
            ? RecorderConfig.default.retentionDays
            : min(output.retentionDays, 3_650)
        output.pollIntervalMilliseconds = min(max(output.pollIntervalMilliseconds, 250), 60_000)
        output.heartbeatSeconds = min(max(output.heartbeatSeconds, 10), 3_600)
        output.maxStringLength = min(max(output.maxStringLength, 64), 8_192)
        if let raw = output.verificationServerURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || (scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
        {
            output.verificationServerURL = raw
        } else {
            output.verificationServerURL = nil
        }
        output.verificationEnabled = output.verificationEnabled ?? false
        output.enableAppAttest = output.enableAppAttest ?? true
        output.applicationCaptureMode = output.effectiveApplicationCaptureMode
        output.websiteCaptureMode = output.effectiveWebsiteCaptureMode

        output.excludedBundleIdentifiers = Self.cleanedList(
            output.excludedBundleIdentifiers,
            maxItems: 512,
            maxLength: 256
        )
        output.excludedDomains = Self.cleanedList(
            output.excludedDomains,
            maxItems: 512,
            maxLength: 253
        )
        output.includedBundleIdentifiers = Self.cleanedList(
            output.effectiveIncludedBundleIdentifiers,
            maxItems: 512,
            maxLength: 256
        )
        output.includedDomains = Self.cleanedList(
            output.effectiveIncludedDomains,
            maxItems: 512,
            maxLength: 253
        )
        output.browserBundleIdentifiers = Self.cleanedList(
            output.browserBundleIdentifiers,
            maxItems: 512,
            maxLength: 256
        )
        output.privateWindowMarkers = Self.cleanedList(
            output.privateWindowMarkers,
            maxItems: 512,
            maxLength: 256
        )
        output.addressFieldMarkers = Self.cleanedList(
            output.addressFieldMarkers,
            maxItems: 512,
            maxLength: 256
        )

        if output.privateWindowMarkers.isEmpty {
            output.privateWindowMarkers = RecorderConfig.default.privateWindowMarkers
        }
        if output.addressFieldMarkers.isEmpty {
            output.addressFieldMarkers = RecorderConfig.default.addressFieldMarkers
        }
        if output.browserBundleIdentifiers.isEmpty {
            output.browserBundleIdentifiers = RecorderConfig.default.browserBundleIdentifiers
        }

        return output
    }

    public static func load(from url: URL) throws -> RecorderConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecorderConfig.self, from: data).validated()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated())
        try data.write(to: url, options: [.atomic])
    }

    private static func cleanedList(_ values: [String], maxItems: Int, maxLength: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in values.prefix(maxItems) {
            let cleaned =
                value
                .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let bounded =
                cleaned.count <= maxLength
                ? cleaned
                : String(cleaned.prefix(maxLength))
            guard seen.insert(bounded).inserted else { continue }
            output.append(bounded)
        }

        return output
    }
}
