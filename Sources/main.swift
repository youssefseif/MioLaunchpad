import Cocoa
import QuartzCore

struct AppItem {
    var name: String
    var path: String
    var icon: NSImage
    var date: Date
}

final class AppScanner {
    static func scan() -> (pages: [[AppItem]], systemStartIndex: Int) {
        var mainApps: [AppItem] = []
        var systemApps: [AppItem] = []
        var processed = Set<String>()

        let paths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]

        for path in paths {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for file in files {
                if file.hasSuffix(".app") {
                    let fullPath = (path as NSString).appendingPathComponent(file)
                    if processed.contains(fullPath) { continue }
                    processed.insert(fullPath)

                    let name = (file as NSString).deletingPathExtension
                    let icon = NSWorkspace.shared.icon(forFile: fullPath)

                    // Data di aggiunta alla cartella Applicazioni: equivale alla data di download/installazione,
                    // molto più affidabile della data di creazione del bundle .app
                    let fileURL = URL(fileURLWithPath: fullPath)
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.addedToDirectoryDateKey])
                    let date = resourceValues?.addedToDirectoryDate ?? Date.distantPast

                    let item = AppItem(name: name, path: fullPath, icon: icon, date: date)

                    // Separiamo le app di sistema dalle altre
                    if path.hasPrefix("/System") && name != "Safari" {
                        systemApps.append(item)
                    } else {
                        mainApps.append(item)
                    }
                }
            }
        }

        mainApps.sort { $0.date < $1.date }
        systemApps.sort { $0.date < $1.date }

        if mainApps.isEmpty && systemApps.isEmpty {
            let finderPath = "/System/Library/CoreServices/Finder.app"
            mainApps.append(AppItem(name: "Finder", path: finderPath, icon: NSWorkspace.shared.icon(forFile: finderPath), date: Date()))
        }

        let pageSize = 56 // 7x8 esatto

        func chunkIntoPages(_ apps: [AppItem]) -> [[AppItem]] {
            var pages: [[AppItem]] = []
            var chunk = [AppItem]()
            for app in apps {
                chunk.append(app)
                if chunk.count == pageSize {
                    pages.append(chunk)
                    chunk = []
                }
            }
            if !chunk.isEmpty { pages.append(chunk) }
            return pages
        }

        // Le pagine delle app "normali" vengono prima, quelle di sistema dopo
        let mainPages = chunkIntoPages(mainApps)
        let systemPages = chunkIntoPages(systemApps)
        var pages = mainPages + systemPages
        if pages.isEmpty { pages = [[]] }

        return (pages, mainPages.count)
    }
}

final class LaunchpadWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

final class LaunchpadBackgroundView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("CloseLaunchpad"), object: nil)
    }
}

final class PageCollectionView: NSCollectionView {
    var pageIndex: Int = 0
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if self.indexPathForItem(at: point) == nil {
            NotificationCenter.default.post(name: NSNotification.Name("CloseLaunchpad"), object: nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class LaunchpadWindowController: NSWindowController, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private var visualEffectView: LaunchpadBackgroundView!
    private var pageContainerView: NSView!
    private var dotsStackView: NSStackView!
    private var sectionLabel: NSTextField!
    var searchField: NSSearchField!

    var currentPage = 0
    var allPages: [[AppItem]] = []
    var originalPages: [[AppItem]] = []
    var systemStartIndex = 0
    var isSearching = false
    var lastSwipeTime: TimeInterval = 0

    convenience init() {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = LaunchpadWindow(contentRect: screenRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear

        self.init(window: window)
        
        let scanResult = AppScanner.scan()
        self.originalPages = scanResult.pages
        self.systemStartIndex = scanResult.systemStartIndex
        self.allPages = self.originalPages
        
        setupUI(screenRect: screenRect)

        NotificationCenter.default.addObserver(self, selector: #selector(closeLaunchpad), name: NSNotification.Name("CloseLaunchpad"), object: nil)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 123 { self.turnPage(direction: -1); return nil }
            if event.keyCode == 124 { self.turnPage(direction: 1); return nil }
            if event.keyCode == 53 {
                if self.isSearching && !self.searchField.stringValue.isEmpty {
                    self.searchField.stringValue = ""
                    self.isSearching = false
                    self.allPages = self.originalPages
                    self.currentPage = 0
                    self.reloadCurrentPage()
                    self.window?.makeFirstResponder(self.pageContainerView)
                    return nil
                } else {
                    self.closeLaunchpad()
                    return nil
                }
            }
            return event
        }

        // Stesso meccanismo del monitor della tastiera qui sopra, ma per lo swipe del
        // trackpad: intercetta l'evento a prescindere da quale view ci sia sotto il cursore.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleTrackpadSwipe(event)
            return event
        }

        // Alcuni trackpad/versioni di macOS segnalano lo swipe come gesto "discreto"
        // (lo stesso tipo di evento che usa Safari per andare avanti/indietro tra le pagine)
        // invece che come scrollWheel continuo: copriamo anche questo caso.
        NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self = self, !self.isSearching else { return event }
            if event.deltaX > 0 {
                self.turnPage(direction: -1)
            } else if event.deltaX < 0 {
                self.turnPage(direction: 1)
            }
            return event
        }
    }

    private func setupUI(screenRect: NSRect) {
        guard let window = self.window else { return }

        visualEffectView = LaunchpadBackgroundView(frame: screenRect)
        visualEffectView.material = .fullScreenUI
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        window.contentView = visualEffectView

        searchField = NSSearchField(frame: NSRect(x: (screenRect.width - 420) / 2, y: screenRect.height - 75, width: 420, height: 40))
        searchField.placeholderString = "Cerca applicazione..."
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 18)
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 10
        visualEffectView.addSubview(searchField)

        sectionLabel = NSTextField(labelWithString: "")
        sectionLabel.frame = NSRect(x: 0, y: screenRect.height - 105, width: screenRect.width, height: 18)
        sectionLabel.alignment = .center
        sectionLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        sectionLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        visualEffectView.addSubview(sectionLabel)

        dotsStackView = NSStackView(frame: NSRect(x: 0, y: 25, width: screenRect.width, height: 20))
        dotsStackView.orientation = .horizontal
        dotsStackView.alignment = .centerY
        dotsStackView.spacing = 10
        visualEffectView.addSubview(dotsStackView)

        pageContainerView = NSView(frame: NSRect(x: 0, y: 50, width: screenRect.width, height: screenRect.height - 130))
        pageContainerView.wantsLayer = true
        visualEffectView.addSubview(pageContainerView)

        reloadCurrentPage()
    }

    // Chiamato da PageCollectionView quando riceve un evento di scroll/swipe.
    // Il debounce (lastSwipeTime) vive qui sul controller, non sulla griglia,
    // perché la griglia viene ricreata ad ogni cambio pagina.
    func handleTrackpadSwipe(_ event: NSEvent) {
        if isSearching { return }
        if abs(event.scrollingDeltaX) > 3 && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSwipeTime > 0.3 {
                lastSwipeTime = now
                if event.scrollingDeltaX > 0 { turnPage(direction: -1) } else { turnPage(direction: 1) }
            }
        }
    }

    func turnPage(direction: Int) {
        let newPage = currentPage + direction
        if newPage >= 0 && newPage < allPages.count {
            currentPage = newPage
            let transition = CATransition()
            transition.duration = 0.25
            transition.type = .push
            transition.subtype = direction > 0 ? .fromRight : .fromLeft
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageContainerView.layer?.add(transition, forKey: "pageTurn")
            reloadCurrentPage()
        }
    }

    func reloadCurrentPage() {
        pageContainerView.subviews.forEach { $0.removeFromSuperview() }
        updateDots()
        updateSectionLabel()
        
        guard let screenWidth = window?.frame.width else { return }
        let containerHeight = pageContainerView.bounds.height
        
        let cols: CGFloat = 7
        let rows: CGFloat = 8
        let horizontalMargin: CGFloat = 80 
        let verticalMargin: CGFloat = 40   
        
        let availableWidth = screenWidth - (horizontalMargin * 2)
        let availableHeight = containerHeight - (verticalMargin * 2)
        
        // Sottraiamo 1 punto per evitare problemi di arrotondamento floating point
        let itemWidth: CGFloat = floor(availableWidth / cols) - 1
        let itemHeight: CGFloat = floor(availableHeight / rows) - 1

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: itemWidth, height: itemHeight)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: verticalMargin, left: horizontalMargin, bottom: verticalMargin, right: horizontalMargin)

        // Contenitore Dummy necessario per AppKit
        let scrollContainer = NSScrollView(frame: pageContainerView.bounds)
        scrollContainer.hasVerticalScroller = false
        scrollContainer.hasHorizontalScroller = false
        scrollContainer.drawsBackground = false
        scrollContainer.horizontalScrollElasticity = .none
        scrollContainer.verticalScrollElasticity = .none

        let cv = PageCollectionView(frame: scrollContainer.bounds)
        cv.collectionViewLayout = layout
        cv.pageIndex = currentPage
        cv.dataSource = self
        cv.delegate = self
        cv.backgroundColors = [.clear]
        cv.register(AppCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("AppCell"))
        cv.isSelectable = true

        scrollContainer.documentView = cv
        pageContainerView.addSubview(scrollContainer)
        
        cv.reloadData() // Comando fondamentale per forzare il disegno!
    }

    func updateDots() {
        dotsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        dotsStackView.isHidden = isSearching || allPages.count <= 1
        let totalPages = allPages.count
        let dotWidth: CGFloat = 8
        let spacing: CGFloat = 10
        let totalWidth = CGFloat(totalPages) * dotWidth + CGFloat(totalPages - 1) * spacing
        dotsStackView.frame.origin.x = ((window?.frame.width ?? 1440) - totalWidth) / 2
        for i in 0..<totalPages {
            let dot = NSBox(frame: NSRect(x: 0, y: 0, width: dotWidth, height: dotWidth))
            dot.boxType = .custom
            dot.isTransparent = true
            dot.cornerRadius = dotWidth / 2
            dot.fillColor = i == currentPage ? NSColor.white : NSColor.white.withAlphaComponent(0.3)
            dotsStackView.addArrangedSubview(dot)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: dotWidth).isActive = true
            dot.heightAnchor.constraint(equalToConstant: dotWidth).isActive = true
        }
    }

    func updateSectionLabel() {
        let totalApps = allPages.reduce(0) { $0 + $1.count }
        if isSearching || totalApps == 0 {
            sectionLabel.stringValue = ""
            return
        }
        if systemStartIndex > 0 && systemStartIndex < allPages.count {
            sectionLabel.stringValue = currentPage >= systemStartIndex ? "App di sistema" : "Le tue app"
        } else {
            sectionLabel.stringValue = ""
        }
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            isSearching = false
            allPages = originalPages
            currentPage = 0
        } else {
            isSearching = true
            let flatApps = originalPages.flatMap { $0 }.filter { $0.name.lowercased().contains(text) }
            var searchPages: [[AppItem]] = []
            var chunk = [AppItem]()
            for app in flatApps {
                chunk.append(app)
                if chunk.count == 56 { searchPages.append(chunk); chunk = [] }
            }
            if !chunk.isEmpty { searchPages.append(chunk) }
            if searchPages.isEmpty { searchPages = [[]] }
            allPages = searchPages
            currentPage = 0
        }
        reloadCurrentPage()
    }

    @objc func closeLaunchpad() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.window?.animator().alphaValue = 0.0
        }, completionHandler: { NSApp.terminate(nil) })
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard currentPage < allPages.count else { return 0 }
        return allPages[currentPage].count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("AppCell"), for: indexPath)
        if let cell = item as? AppCell { cell.configure(with: allPages[currentPage][indexPath.item]) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        let app = allPages[currentPage][indexPath.item]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { self.closeLaunchpad() }
        }
    }
}

final class AppCell: NSCollectionViewItem {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        self.view = NSView()
        self.view.addSubview(iconView)
        self.view.addSubview(nameLabel)
        
        iconView.imageScaling = .scaleProportionallyUpOrDown
        
        nameLabel.alignment = .center
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.maximumNumberOfLines = 2
        nameLabel.cell?.wraps = true
        nameLabel.cell?.truncatesLastVisibleLine = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        let height = view.bounds.height
        
        let iconSize: CGFloat = min(width * 0.65, 85)
        iconView.frame = NSRect(x: (width - iconSize) / 2, y: height - iconSize - 5, width: iconSize, height: iconSize)
        nameLabel.frame = NSRect(x: 2, y: 5, width: width - 4, height: height - iconSize - 15)
    }

    func configure(with app: AppItem) {
        nameLabel.stringValue = app.name
        iconView.image = app.icon
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: LaunchpadWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = LaunchpadWindowController()
        windowController?.window?.alphaValue = 0.0
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.windowController?.window?.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            self?.windowController?.focusSearch()
        })
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate()
app.run()
