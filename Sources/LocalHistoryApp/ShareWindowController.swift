#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore
    import UniformTypeIdentifiers

    final class ShareWindowWorkCoordinator {
        typealias Scheduler = (@escaping () -> Void) -> Void

        private final class Token {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock()
                cancelled = true
                lock.unlock()
            }
        }

        private static let defaultQueue = DispatchQueue(
            label: "ai.goalong.localhistory.share-window-work",
            qos: .userInitiated
        )

        private let lock = NSLock()
        private let schedule: Scheduler
        private let deliver: Scheduler
        private var activeToken: Token?

        init(
            schedule: @escaping Scheduler = { work in defaultQueue.async(execute: work) },
            deliver: @escaping Scheduler = { work in DispatchQueue.main.async(execute: work) }
        ) {
            self.schedule = schedule
            self.deliver = deliver
        }

        @discardableResult
        func start<Output>(
            onStart: () -> Void = {},
            work: @escaping (_ cancellation: @escaping () -> Bool) throws -> Output,
            completion: @escaping (Result<Output, Error>) -> Void
        ) -> Bool {
            let token = replaceActiveToken()
            onStart()
            schedule { [weak self] in
                let result: Result<Output, Error>
                if token.isCancelled {
                    result = .failure(ShareBuildError.cancelled)
                } else {
                    result = Result { try work { token.isCancelled } }
                }
                self?.deliverResult(result, token: token, completion: completion)
            }
            return true
        }

        @discardableResult
        func startAfterChoosingDestination<Output>(
            chooseDestination: () -> URL?,
            onStart: () -> Void = {},
            work: @escaping (URL, _ cancellation: @escaping () -> Bool) throws -> Output,
            completion: @escaping (Result<Output, Error>) -> Void
        ) -> Bool {
            guard let destination = chooseDestination() else { return false }
            return start(
                onStart: onStart,
                work: { cancellation in
                    try work(destination, cancellation)
                },
                completion: completion
            )
        }

        func cancel() {
            lock.lock()
            let token = activeToken
            activeToken = nil
            lock.unlock()
            token?.cancel()
        }

        var hasActiveWork: Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeToken != nil
        }

        private func replaceActiveToken() -> Token {
            let token = Token()
            lock.lock()
            let previous = activeToken
            activeToken = token
            lock.unlock()
            previous?.cancel()
            return token
        }

        private func deliverResult<Output>(
            _ result: Result<Output, Error>,
            token: Token,
            completion: @escaping (Result<Output, Error>) -> Void
        ) {
            deliver { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.activeToken === token else {
                    self.lock.unlock()
                    return
                }
                self.activeToken = nil
                self.lock.unlock()
                completion(result)
            }
        }
    }

    final class ShareWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
        NSWindowDelegate
    {
        private let selectableLevels: [ShareLevel] = [.everything, .applicationOnly, .categoryOnly, .privateOnly]
        private let builder: SharePackageBuilder
        private let day: Date
        private var rows: [ShareMinuteRow] = []
        private let tableView = NSTableView()
        private let statusLabel = NSTextField(labelWithString: "")
        private let exportButton = NSButton(
            title: "Export verified share package…",
            target: nil,
            action: nil
        )
        private let reloadWork = ShareWindowWorkCoordinator()
        private let exportWork = ShareWindowWorkCoordinator()

        init(builder: SharePackageBuilder, day: Date = Date()) {
            self.builder = builder
            self.day = day

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Share verified Goalong History"
            window.center()
            super.init(window: window)
            window.delegate = self
            buildUI()
            reload()
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            reloadWork.cancel()
            exportWork.cancel()
        }

        private func buildUI() {
            guard let content = window?.contentView else { return }

            let explanation = NSTextField(
                wrappingLabelWithString:
                    "Nothing is uploaded by this window until you export/share the package. Choose what each sealed minute may reveal. Completely private reveals only the existence/time/coverage proof; it cannot be counted as verified work."
            )
            explanation.translatesAutoresizingMaskIntoConstraints = false

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true

            let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
            timeColumn.title = "Time"
            timeColumn.width = 120
            tableView.addTableColumn(timeColumn)

            let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
            appColumn.title = "Local app summary"
            appColumn.width = 260
            tableView.addTableColumn(appColumn)

            let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
            categoryColumn.title = "Local category"
            categoryColumn.width = 180
            tableView.addTableColumn(categoryColumn)

            let privacyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("privacy"))
            privacyColumn.title = "Share"
            privacyColumn.width = 220
            tableView.addTableColumn(privacyColumn)

            tableView.delegate = self
            tableView.dataSource = self
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.rowHeight = 28
            scroll.documentView = tableView

            let setAll = NSPopUpButton()
            setAll.translatesAutoresizingMaskIntoConstraints = false
            setAll.addItems(withTitles: ["Set all…"] + selectableLevels.map(\.title))
            setAll.target = self
            setAll.action = #selector(setAllChanged(_:))

            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.textColor = .secondaryLabelColor

            exportButton.target = self
            exportButton.action = #selector(exportPackage)
            exportButton.translatesAutoresizingMaskIntoConstraints = false
            exportButton.bezelStyle = .rounded
            exportButton.isEnabled = false

            content.addSubview(explanation)
            content.addSubview(scroll)
            content.addSubview(setAll)
            content.addSubview(statusLabel)
            content.addSubview(exportButton)

            NSLayoutConstraint.activate([
                explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

                scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                scroll.bottomAnchor.constraint(equalTo: setAll.topAnchor, constant: -12),

                setAll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                setAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

                statusLabel.leadingAnchor.constraint(equalTo: setAll.trailingAnchor, constant: 16),
                statusLabel.centerYAnchor.constraint(equalTo: setAll.centerYAnchor),

                exportButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                exportButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ])
        }

        private func reload() {
            let builder = builder
            let day = day
            reloadWork.start(
                onStart: { [weak self] in
                    self?.statusLabel.stringValue = "Loading sealed minutes…"
                    self?.exportButton.isEnabled = false
                },
                work: { cancellation in
                    try builder.minuteRows(for: day, cancellation: cancellation)
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let rows):
                        self.rows = rows
                        self.statusLabel.stringValue = "\(rows.count) sealed minute(s)"
                        self.exportButton.isEnabled = !rows.isEmpty
                    case .failure(let error):
                        self.rows = []
                        self.statusLabel.stringValue = String(describing: error)
                        self.exportButton.isEnabled = false
                    }
                    self.tableView.reloadData()
                }
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
            let item = rows[row]

            if identifier == "privacy" {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: selectableLevels.map(\.title))
                popup.selectItem(withTitle: item.level.title)
                popup.tag = row
                popup.target = self
                popup.action = #selector(rowPrivacyChanged(_:))
                popup.isEnabled = item.canRevealDetails
                if !item.canRevealDetails {
                    popup.selectItem(withTitle: ShareLevel.privateOnly.title)
                }
                return popup
            }

            let value: String
            switch identifier {
            case "time": value = Self.timeFormatter.string(from: item.start)
            case "app": value = item.appSummary
            case "category": value = item.categorySummary
            default: value = ""
            }
            let field = NSTextField(labelWithString: value)
            field.lineBreakMode = .byTruncatingTail
            return field
        }

        @objc private func rowPrivacyChanged(_ sender: NSPopUpButton) {
            guard sender.tag >= 0, sender.tag < rows.count,
                let title = sender.selectedItem?.title,
                let level = selectableLevels.first(where: { $0.title == title })
            else { return }
            rows[sender.tag].level = rows[sender.tag].canRevealDetails ? level : .privateOnly
        }

        @objc private func setAllChanged(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem > 0 else { return }
            let level = selectableLevels[sender.indexOfSelectedItem - 1]
            for index in rows.indices {
                rows[index].level = rows[index].canRevealDetails ? level : .privateOnly
            }
            sender.selectItem(at: 0)
            tableView.reloadData()
        }

        @objc private func exportPackage() {
            var levels: [UInt64: ShareLevel] = [:]
            levels.reserveCapacity(rows.count)
            for row in rows { levels[row.anchorSequence] = row.level }
            let builder = builder
            let day = day
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(AppPaths.localDayString(for: day)).verified-share.json"
            panel.allowedContentTypes = [.json]

            exportWork.startAfterChoosingDestination(
                chooseDestination: {
                    panel.runModal() == .OK ? panel.url : nil
                },
                onStart: { [weak self] in
                    self?.exportButton.isEnabled = false
                    self?.statusLabel.stringValue = "Building verified package…"
                },
                work: { destination, cancellation in
                    let package = try builder.build(
                        for: day,
                        levels: levels,
                        cancellation: cancellation
                    )
                    try builder.write(
                        package,
                        to: destination,
                        cancellation: cancellation
                    )
                    return destination
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    self.exportButton.isEnabled = !self.rows.isEmpty
                    switch result {
                    case .success(let destination):
                        self.statusLabel.stringValue = "Verified package exported"
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    case .failure(let error):
                        if let buildError = error as? ShareBuildError,
                            case .cancelled = buildError
                        {
                            return
                        }
                        self.statusLabel.stringValue = String(describing: error)
                        let alert = NSAlert(error: error)
                        alert.messageText = "Could not export verified share package"
                        alert.runModal()
                    }
                }
            )
        }

        func windowWillClose(_ notification: Notification) {
            reloadWork.cancel()
            exportWork.cancel()
            if reloadWork.hasActiveWork || exportWork.hasActiveWork {
                statusLabel.stringValue = "Cancelling…"
            }
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()
    }
#endif
