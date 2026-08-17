// THROWAWAY PROTOTYPE — Apple Photos → local face candidates → Mimo DIY.
//
// Question: can explicit PhotoKit access plus local Vision analysis make
// choosing a familiar subject easier without treating Apple's Photos library
// as an identity database? This file deliberately calls every group
// “possibly the same person” and requires a click before any DIY handoff.

import Cocoa
import CoreImage
import CoreML
import Photos
import PhotosUI
import UniformTypeIdentifiers
import Vision

private final class PhotosFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private struct PhotosPersonCandidate {
    let id: UUID
    let assetID: String
    let createdAt: Date?
    let portrait: CGImage
    let face: CGImage
    let quality: Float
    let isFavorite: Bool
    let featurePrint: VNFeaturePrintObservation
    let ir101Face: CGImage
    let kprpeFace: CGImage
    let kprpeKeypoints: [Float]
    var ir101Embedding: PhotosFaceIdentityEmbedding?
    var kprpeEmbedding: PhotosFaceIdentityEmbedding?
}

private struct PhotosPersonGroup {
    let id: UUID
    var candidates: [PhotosPersonCandidate]

    var best: PhotosPersonCandidate { candidates.max { $0.quality < $1.quality }! }
}

private enum PhotosScanSource: Int {
    case recent
    case favorites
    case selfies
    case portraits

    var fetchLimit: Int {
        switch self {
        case .recent: return 600
        case .favorites, .selfies, .portraits: return 900
        }
    }
}

private enum PhotosGroupingMode: Int {
    case precise
    case balanced
    case broad

    var threshold: Float {
        switch self {
        case .precise: return 0.48
        case .balanced: return 0.64
        case .broad: return 0.78
        }
    }

    func threshold(for model: PhotosFaceIdentityModel) -> Float {
        guard model != .vision else { return threshold }
        switch self {
        case .precise: return 0.50
        case .balanced: return 0.62
        case .broad: return 0.72
        }
    }
}

private enum PhotosAppearancePreset: Int {
    case recommended
    case recent
    case custom
}

private struct PhotosCandidatePartition {
    private(set) var parent: [Int]
    private(set) var members: [[Int]]
    private(set) var assetIDs: [Set<String>]

    init(candidates: [PhotosPersonCandidate]) {
        parent = Array(candidates.indices)
        members = candidates.indices.map { [$0] }
        assetIDs = candidates.map { [$0.assetID] }
    }

    mutating func root(of index: Int) -> Int {
        var cursor = index
        while parent[cursor] != cursor { cursor = parent[cursor] }
        var path = index
        while parent[path] != path {
            let next = parent[path]
            parent[path] = cursor
            path = next
        }
        return cursor
    }

    mutating func canMerge(_ first: Int, _ second: Int) -> Bool {
        let a = root(of: first), b = root(of: second)
        return a != b && assetIDs[a].isDisjoint(with: assetIDs[b])
    }

    mutating func merge(_ first: Int, _ second: Int) {
        var a = root(of: first), b = root(of: second)
        guard a != b else { return }
        if members[a].count < members[b].count { swap(&a, &b) }
        parent[b] = a
        members[a].append(contentsOf: members[b])
        members[b].removeAll(keepingCapacity: false)
        assetIDs[a].formUnion(assetIDs[b])
        assetIDs[b].removeAll(keepingCapacity: false)
    }

    mutating func groups() -> [[Int]] {
        parent.indices.compactMap { index in root(of: index) == index ? members[index] : nil }
    }
}

final class PhotosPeoplePrototypeController: NSObject, NSWindowDelegate {
    static let shared = PhotosPeoplePrototypeController()

    private let imageManager = PHCachingImageManager()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var window: NSWindow?
    private var scanButton: NSButton!
    private var manualButton: NSButton!
    private var sourceControl: NSSegmentedControl!
    private var modelControl: NSSegmentedControl!
    private var groupingControl: NSSegmentedControl!
    private var cloudCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var resultSummaryLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var cardsStack: NSStackView!
    private var rawCandidates: [PhotosPersonCandidate] = []
    private var groups: [PhotosPersonGroup] = []
    private var inferenceMilliseconds: [PhotosFaceIdentityModel: Double] = [:]
    private var benchmarkCopy = ""
    private var showingSingletons = false
    private var selectionSheet: NSWindow?
    private var selectionGroupIndex: Int?
    private var selectionCandidates: [PhotosPersonCandidate] = []
    private var selectedCandidateIDs: Set<UUID> = []
    private var selectionButtons: [NSButton] = []
    private var appearanceControl: NSSegmentedControl?
    private var selectionCountLabel: NSTextField?
    private var selectionConfirmButton: NSButton?
    private var temporaryPortraitDirectories: Set<URL> = []
    private var scanGeneration = UUID()
    private var scanning = false
    private var onSelect: (([URL]) -> Void)?
    private lazy var faceEmbeddingRuntime = PhotosFaceEmbeddingRuntime()
    private let modelLabEnabled = ProcessInfo.processInfo.arguments.contains(
        "--photos-people-model-lab")

    func show(onSelect: @escaping ([URL]) -> Void) {
        self.onSelect = onSelect
        if window == nil { buildWindow() }
        guard let window else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func keepVisible(alongside studioWindow: NSWindow?) {
        guard let window else { return }
        guard let studioWindow,
              let screen = studioWindow.screen ?? window.screen ?? NSScreen.main else {
            window.orderFront(nil)
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let combinedWidth = window.frame.width + gap + studioWindow.frame.width
        if combinedWidth <= visible.width {
            let left = visible.midX - combinedWidth / 2
            window.setFrameOrigin(NSPoint(
                x: left,
                y: visible.midY - window.frame.height / 2))
            studioWindow.setFrameOrigin(NSPoint(
                x: left + window.frame.width + gap,
                y: visible.midY - studioWindow.frame.height / 2))
        }
        window.orderFront(nil)
        studioWindow.makeKeyAndOrderFront(nil)
    }

    /// Release the previous person's in-memory photo scan after the installed
    /// familiar is safely persisted. The window deliberately stays open so it
    /// is immediately ready for the next project.
    func resetAfterCompletedStudioProject() {
        scanGeneration = UUID()
        scanning = false
        closePhotoSelection()
        rawCandidates.removeAll()
        groups.removeAll()
        inferenceMilliseconds.removeAll()
        benchmarkCopy = ""
        showingSingletons = false
        purgeTemporaryPortraitDirectories()

        guard window != nil else { return }
        sourceControl.isEnabled = true
        modelControl.isEnabled = true
        groupingControl.isEnabled = true
        manualButton.isEnabled = true
        scanButton.isEnabled = true
        scanButton.title = voice("开始寻找", "Start finding")
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        resultSummaryLabel.stringValue = voice(
            "上一位主角的照片已清空", "Previous subject photos cleared")
        statusLabel.stringValue = voice(
            "可以直接开始下一个项目。", "Ready for the next project.")
        renderEmpty(voice(
            "上一轮照片与人物分组已清空。选择照片范围，开始寻找下一位主角。",
            "The previous photos and face groups were cleared. Choose a source to find the next subject."))
    }

    func windowWillClose(_ notification: Notification) {
        closePhotoSelection()
        scanGeneration = UUID()
        scanning = false
        sourceControl?.isEnabled = true
        modelControl?.isEnabled = true
        groupingControl?.isEnabled = true
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = voice("从照片找主角", "Find a subject in Photos")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 540, height: 620)
        window.maxSize = NSSize(width: 660, height: 1200)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.952,
                                               blue: 0.985, alpha: 0.82).cgColor
        let rootController = NSViewController()
        rootController.view = root
        window.contentViewController = rootController

        let emblem = NSImageView()
        emblem.image = NSImage(
            systemSymbolName: "person.2.fill",
            accessibilityDescription: voice("熟悉的人", "Familiar people"))
        emblem.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 25, weight: .medium)
        emblem.contentTintColor = NSColor(calibratedRed: 0.42, green: 0.32,
                                           blue: 0.76, alpha: 1)
        emblem.wantsLayer = true
        emblem.layer?.backgroundColor = NSColor(calibratedRed: 0.77, green: 0.71,
                                                 blue: 0.95, alpha: 0.28).cgColor
        emblem.layer?.cornerRadius = 16

        let title = label(
            voice("从照片里找到 TA", "Find someone familiar"),
            size: 26, weight: .bold)
        let subtitle = label(
            voice("本机整理面孔线索，你确认之前不会上传或生成。",
                  "Faces are organized on this Mac. Nothing uploads or generates until you choose."),
            size: 12, color: .secondaryLabelColor)
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping

        let headerCopy = NSStackView(views: [title, subtitle])
        headerCopy.orientation = .vertical
        headerCopy.alignment = .leading
        headerCopy.spacing = 4
        headerCopy.setHuggingPriority(.defaultLow, for: .horizontal)

        let privacy = pill(
            voice("⌘ 本机隐私", "⌘ On-device"),
            color: NSColor(calibratedRed: 0.20, green: 0.58, blue: 0.48, alpha: 1))

        let header = NSStackView(views: [emblem, headerCopy, privacy])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        sourceControl = NSSegmentedControl(
            labels: [
                voice("最近", "Recent"),
                voice("收藏", "Favorites"),
                voice("自拍", "Selfies"),
                voice("人像", "Portraits"),
            ],
            trackingMode: .selectOne, target: self,
            action: #selector(sourceChanged(_:)))
        sourceControl.selectedSegment = 0
        sourceControl.controlSize = .large

        scanButton = NSButton(
            title: voice("开始寻找", "Start finding"),
            target: self, action: #selector(scanPressed(_:)))
        scanButton.bezelStyle = .rounded
        scanButton.controlSize = .large
        scanButton.bezelColor = NSColor(calibratedRed: 0.43, green: 0.34,
                                         blue: 0.78, alpha: 1)

        manualButton = NSButton(
            title: voice("手动选照片", "Choose photos"),
            target: self, action: #selector(openPhotoPicker(_:)))
        manualButton.bezelStyle = .rounded
        manualButton.controlSize = .large

        cloudCheckbox = NSButton(
            checkboxWithTitle: voice("需要时从 iCloud 取缩略图",
                                     "Fetch iCloud thumbnails when needed"),
            target: nil, action: nil)
        cloudCheckbox.state = .off
        cloudCheckbox.controlSize = .small

        groupingControl = NSSegmentedControl(
            labels: [voice("精准", "Precise"), voice("平衡", "Balanced"),
                     voice("宽松", "Broad")],
            trackingMode: .selectOne, target: self,
            action: #selector(groupingChanged(_:)))
        groupingControl.selectedSegment = PhotosGroupingMode.balanced.rawValue
        groupingControl.controlSize = .small

        modelControl = NSSegmentedControl(
            labels: ["Vision", "IR101 + KP", "KP-RPE"],
            trackingMode: .selectOne, target: self,
            action: #selector(modelChanged(_:)))
        modelControl.selectedSegment = PhotosFaceIdentityModel.ir101.rawValue
        modelControl.controlSize = .small

        let sourceLabel = label(
            voice("从哪里开始", "Start with"), size: 10, weight: .semibold,
            color: .secondaryLabelColor)
        let sourceStack = NSStackView(views: [sourceLabel, sourceControl])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 7

        let groupingLabel = label(
            voice("合并力度", "Grouping"), size: 10, weight: .semibold,
            color: .secondaryLabelColor)
        let groupingStack = NSStackView(views: [groupingLabel, groupingControl])
        groupingStack.orientation = .vertical
        groupingStack.alignment = .leading
        groupingStack.spacing = 4

        let modelLabel = label(
            voice("身份模型", "Identity model"), size: 10, weight: .semibold,
            color: .secondaryLabelColor)
        let modelStack = NSStackView(views: [modelLabel, modelControl])
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 4

        let tuningSpacer = NSView()
        let tuningViews: [NSView] = modelLabEnabled
            ? [modelStack, tuningSpacer, groupingStack]
            : [tuningSpacer]
        let tuning = NSStackView(views: tuningViews)
        tuning.orientation = .horizontal
        tuning.alignment = .bottom
        tuning.spacing = 12

        let actionSpacer = NSView()
        let actions = NSStackView(views: [actionSpacer, manualButton, scanButton])
        actions.orientation = .horizontal
        actions.alignment = .bottom
        actions.spacing = 8

        var controlViews: [NSView] = [sourceStack]
        if modelLabEnabled { controlViews.append(tuning) }
        controlViews.append(actions)
        if modelLabEnabled { controlViews.append(cloudCheckbox) }
        let controlContent = NSStackView(views: controlViews)
        controlContent.orientation = .vertical
        controlContent.alignment = .leading
        controlContent.spacing = 10
        let controls = panelBox()
        guard let controlsView = controls.contentView else { return }
        controlContent.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(controlContent)
        NSLayoutConstraint.activate([
            controlContent.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
            controlContent.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
            controlContent.topAnchor.constraint(equalTo: controlsView.topAnchor),
            controlContent.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor),
            sourceControl.widthAnchor.constraint(equalTo: controlContent.widthAnchor),
            actions.widthAnchor.constraint(equalTo: controlContent.widthAnchor),
        ])
        if modelLabEnabled {
            tuning.widthAnchor.constraint(equalTo: controlContent.widthAnchor).isActive = true
        }

        statusLabel = label(
            authorizationCopy(), size: 11, color: .secondaryLabelColor)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        resultSummaryLabel = label(
            voice("等待开始", "Ready when you are"), size: 14, weight: .semibold)
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isIndeterminate = false
        progressIndicator.isHidden = true
        let statusCopy = NSStackView(views: [resultSummaryLabel, statusLabel, progressIndicator])
        statusCopy.orientation = .vertical
        statusCopy.alignment = .leading
        statusCopy.spacing = 4
        statusCopy.translatesAutoresizingMaskIntoConstraints = false
        let statusPanel = panelBox(
            fill: NSColor(calibratedRed: 0.48, green: 0.40, blue: 0.82, alpha: 0.08),
            border: NSColor(calibratedRed: 0.48, green: 0.40, blue: 0.82, alpha: 0.13))
        guard let statusView = statusPanel.contentView else { return }
        statusView.addSubview(statusCopy)
        NSLayoutConstraint.activate([
            statusCopy.leadingAnchor.constraint(equalTo: statusView.leadingAnchor),
            statusCopy.trailingAnchor.constraint(equalTo: statusView.trailingAnchor),
            statusCopy.topAnchor.constraint(equalTo: statusView.topAnchor),
            statusCopy.bottomAnchor.constraint(equalTo: statusView.bottomAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: statusCopy.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        cardsStack = NSStackView()
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 8
        cardsStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 20, right: 0)
        scroll.documentView = cardsStack
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.widthAnchor.constraint(
            equalTo: scroll.contentView.widthAnchor).isActive = true

        [header, controls, statusPanel, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            emblem.widthAnchor.constraint(equalToConstant: 54),
            emblem.heightAnchor.constraint(equalToConstant: 54),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            controls.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            statusPanel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statusPanel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        renderEmpty(
            voice("选一个照片范围，米墨会在本机找出常出现的面孔。",
                  "Choose a source and Mimo will find faces that appear often — entirely on this Mac."))
        self.window = window
        if ProcessInfo.processInfo.arguments.contains("--photos-people-ui-preview") {
            installPreviewFixture()
        }
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        guard !scanning else { return }
        scanButton.title = voice("开始寻找", "Start finding")
        let sources = [voice("最近照片", "Recent"), voice("收藏", "Favorites"),
                       voice("自拍", "Selfies"), voice("人像模式", "Portraits")]
        let selected = sources.indices.contains(sender.selectedSegment)
            ? sources[sender.selectedSegment] : sources[0]
        resultSummaryLabel.stringValue = voice("已选择 \(selected)", "\(selected) selected")
        statusLabel.stringValue = voice(
            "点击开始后才会读取，所有整理都在本机完成。",
            "Photos are read only after you click; all organization stays on this Mac.")
    }

    @objc private func groupingChanged(_ sender: NSSegmentedControl) {
        guard !scanning else { return }
        if !rawCandidates.isEmpty { regroup() }
    }

    @objc private func modelChanged(_ sender: NSSegmentedControl) {
        guard !scanning else { return }
        if !rawCandidates.isEmpty { regroup() }
    }

    @objc private func scanPressed(_ sender: NSButton) {
        if scanning {
            scanGeneration = UUID()
            scanning = false
            sourceControl.isEnabled = true
            modelControl.isEnabled = true
            groupingControl.isEnabled = true
            manualButton.isEnabled = true
            scanButton.title = voice("重新扫描", "Scan again")
            progressIndicator.isHidden = true
            resultSummaryLabel.stringValue = voice("已停止", "Stopped")
            statusLabel.stringValue = voice("已停止。", "Stopped.")
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            startScan()
        case .notDetermined:
            statusLabel.stringValue = voice("等待 macOS Photos 授权…",
                                            "Waiting for macOS Photos permission…")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] next in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if next == .authorized || next == .limited { self.startScan() }
                    else { self.showAuthorizationFailure(next) }
                }
            }
        case .denied, .restricted:
            showAuthorizationFailure(status)
        @unknown default:
            showAuthorizationFailure(status)
        }
    }

    private func showAuthorizationFailure(_ status: PHAuthorizationStatus) {
        scanning = false
        sourceControl.isEnabled = true
        modelControl.isEnabled = true
        groupingControl.isEnabled = true
        manualButton.isEnabled = true
        scanButton.title = voice("再试一次", "Try again")
        progressIndicator.isHidden = true
        resultSummaryLabel.stringValue = voice("无法读取 Photos", "Photos access unavailable")
        statusLabel.stringValue = voice(
            "Mimo 没有 Photos 读取权限。可在系统设置 → 隐私与安全性 → 照片中更改。",
            "Mimo cannot read Photos. Change access in System Settings → Privacy & Security → Photos.")
    }

    private func startScan() {
        let selectedModel = PhotosFaceIdentityModel(
            rawValue: modelControl.selectedSegment) ?? .ir101
        guard faceEmbeddingRuntime.isAvailable(selectedModel) else {
            showIdentityModelFailure(selectedModel)
            return
        }
        let generation = UUID()
        scanGeneration = generation
        scanning = true
        sourceControl.isEnabled = false
        modelControl.isEnabled = false
        groupingControl.isEnabled = false
        manualButton.isEnabled = false
        showingSingletons = false
        rawCandidates = []
        groups = []
        inferenceMilliseconds = [:]
        benchmarkCopy = ""
        renderEmpty(voice("正在找光线好、面部清楚的人像…",
                          "Looking for clear, well-lit portraits…"))
        scanButton.title = voice("停止", "Stop")
        resultSummaryLabel.stringValue = voice("正在本机寻找面孔…", "Finding faces on this Mac…")
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        let allowNetwork = cloudCheckbox.state == .on
        let source = PhotosScanSource(rawValue: sourceControl.selectedSegment) ?? .recent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let assets = self.fetchAssets(for: source) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanning = false
                    self.sourceControl.isEnabled = true
                    self.modelControl.isEnabled = true
                    self.groupingControl.isEnabled = true
                    self.manualButton.isEnabled = true
                    self.scanButton.title = voice("换个范围", "Choose another source")
                    self.progressIndicator.isHidden = true
                    self.resultSummaryLabel.stringValue = voice("这里没有可读取的照片", "No readable photos here")
                    self.statusLabel.stringValue = voice(
                        "这个系统相册目前没有可读取的照片。",
                        "This system album has no readable photos right now.")
                }
                return
            }
            var candidates: [PhotosPersonCandidate] = []
            var unavailable = 0
            var seenBurstIDs = Set<String>()
            let total = assets.count

            for index in 0..<total {
                guard self.scanGeneration == generation else { return }
                autoreleasepool {
                    let asset = assets.object(at: index)
                    if let burstID = asset.burstIdentifier,
                       !seenBurstIDs.insert(burstID).inserted { return }
                    guard let image = self.image(for: asset, allowNetwork: allowNetwork) else {
                        unavailable += 1
                        return
                    }
                    let found = self.candidates(in: image, asset: asset)
                    candidates.append(contentsOf: found)
                    if candidates.count > 192 {
                        candidates.sort { $0.quality > $1.quality }
                        candidates.removeLast(candidates.count - 160)
                    }
                }
                if index % 12 == 0 || index == total - 1 {
                    let faceCount = candidates.count
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.progressIndicator.doubleValue = total > 0
                            ? Double(index + 1) / Double(total) : 0
                        self.resultSummaryLabel.stringValue = voice(
                            "正在看第 \(index + 1) / \(total) 张", "Reviewing \(index + 1) of \(total)")
                        self.statusLabel.stringValue = voice(
                            "已看 \(index + 1)/\(total) 张 · 找到 \(faceCount) 个可用人像",
                            "Checked \(index + 1)/\(total) · \(faceCount) usable portraits")
                    }
                }
            }

            candidates.sort { $0.quality > $1.quality }
            let shortlisted = Array(candidates.prefix(160))
            let enriched = self.addIdentityEmbeddings(
                to: shortlisted, generation: generation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.scanning = false
                self.sourceControl.isEnabled = true
                self.modelControl.isEnabled = true
                self.groupingControl.isEnabled = true
                self.manualButton.isEnabled = true
                self.scanButton.title = voice("重新扫描", "Scan again")
                self.progressIndicator.isHidden = true
                self.rawCandidates = enriched.candidates
                self.inferenceMilliseconds = enriched.milliseconds
                self.regroup()
                let recurring = self.groups.filter { $0.candidates.count >= 2 }.count
                let singles = self.groups.filter { $0.candidates.count == 1 }.count
                let skipped = unavailable > 0
                    ? voice("· \(unavailable) 张当前不在本机", "· \(unavailable) not on this Mac") : ""
                self.resultSummaryLabel.stringValue = enriched.candidates.isEmpty
                    ? voice("没有找到清楚的面孔", "No clear faces found")
                    : voice("找到 \(recurring) 位常出现的人",
                            "Found \(recurring) people who appear often")
                self.statusLabel.stringValue = enriched.candidates.isEmpty
                    ? voice("没有找到足够清楚的人像 \(skipped)",
                            "No clear portraits found \(skipped)")
                    : voice("\(enriched.candidates.count) 张面孔 · \(singles) 张待确认 \(skipped)\n\(self.benchmarkStatusCopy)",
                            "\(enriched.candidates.count) faces · \(singles) pending \(skipped)\n\(self.benchmarkStatusCopy)")
            }
        }
    }

    private func showIdentityModelFailure(_ model: PhotosFaceIdentityModel) {
        scanning = false
        sourceControl.isEnabled = true
        modelControl.isEnabled = true
        groupingControl.isEnabled = true
        manualButton.isEnabled = true
        scanButton.title = voice("再试一次", "Try again")
        progressIndicator.isHidden = true
        resultSummaryLabel.stringValue = voice(
            "本地身份模型未安装", "Local identity model is not installed")
        statusLabel.stringValue = voice(
            "本次未扫描，也不会偷偷改用旧的 Vision 分组。你仍可手动选照片。",
            "Nothing was scanned and Mimo will not silently fall back to old Vision grouping. You can still choose photos manually.")
    }

    private func addIdentityEmbeddings(
        to candidates: [PhotosPersonCandidate], generation: UUID
    ) -> (candidates: [PhotosPersonCandidate],
          milliseconds: [PhotosFaceIdentityModel: Double]) {
        guard !candidates.isEmpty else { return ([], [:]) }
        let runtime = faceEmbeddingRuntime
        var enriched = candidates
        var timings: [PhotosFaceIdentityModel: Double] = [:]
        for index in enriched.indices {
            guard scanGeneration == generation else { return (enriched, timings) }
            if runtime.isAvailable(.ir101),
               let prediction = runtime.predictIR101(enriched[index].ir101Face) {
                enriched[index].ir101Embedding = prediction.embedding
                timings[.ir101, default: 0] += prediction.milliseconds
            }
            if runtime.isAvailable(.kprpe),
               let prediction = runtime.predictKPRPE(
                enriched[index].kprpeFace,
                keypoints: enriched[index].kprpeKeypoints) {
                enriched[index].kprpeEmbedding = prediction.embedding
                timings[.kprpe, default: 0] += prediction.milliseconds
            }
            if index.isMultiple(of: 4) || index == enriched.count - 1 {
                let completed = index + 1
                let total = enriched.count
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.resultSummaryLabel.stringValue = voice(
                        "正在本机比较身份模型…",
                        "Comparing identity models locally…")
                    self.statusLabel.stringValue = voice(
                        "已处理 \(completed) / \(total) 张面孔",
                        "Processed \(completed) of \(total) faces")
                    self.progressIndicator.doubleValue = Double(completed) / Double(total)
                }
            }
        }
        return (enriched, timings)
    }

    private func fetchAssets(for source: PhotosScanSource) -> PHFetchResult<PHAsset>? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = source.fetchLimit
        options.predicate = NSPredicate(
            format: "mediaType == %d AND (mediaSubtype & %d) == 0",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaSubtype.photoScreenshot.rawValue)

        switch source {
        case .recent:
            return PHAsset.fetchAssets(with: .image, options: options)
        case .favorites, .selfies, .portraits:
            let subtype: PHAssetCollectionSubtype
            switch source {
            case .favorites: subtype = .smartAlbumFavorites
            case .selfies: subtype = .smartAlbumSelfPortraits
            case .portraits: subtype = .smartAlbumDepthEffect
            case .recent: subtype = .smartAlbumRecentlyAdded
            }
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil)
            guard let collection = collections.firstObject else { return nil }
            return PHAsset.fetchAssets(in: collection, options: options)
        }
    }

    private func image(for asset: PHAsset, allowNetwork: Bool) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = allowNetwork
        var output: CGImage?
        imageManager.requestImage(
            for: asset, targetSize: NSSize(width: 960, height: 960),
            contentMode: .aspectFit, options: options) { image, info in
                guard let image,
                      !(info?[PHImageCancelledKey] as? Bool ?? false),
                      info?[PHImageErrorKey] == nil else { return }
                output = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        return output
    }

    private func candidates(in image: CGImage, asset: PHAsset) -> [PhotosPersonCandidate] {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return [] }
        let qualityFaces = request.results ?? []
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        landmarkRequest.inputFaceObservations = qualityFaces
        try? handler.perform([landmarkRequest])
        let landmarkFaces = landmarkRequest.results ?? qualityFaces

        return qualityFaces
            .filter { observation in
                let box = observation.boundingBox
                return min(box.width, box.height) >= 0.065
                    && (observation.faceCaptureQuality ?? 0.35) >= 0.22
            }
            .sorted { ($0.faceCaptureQuality ?? 0.35) > ($1.faceCaptureQuality ?? 0.35) }
            .prefix(4)
            .compactMap { qualityObservation in
                let observation = landmarkFaces.min { first, second in
                    boundingDistance(first.boundingBox, qualityObservation.boundingBox)
                        < boundingDistance(second.boundingBox, qualityObservation.boundingBox)
                } ?? qualityObservation
                guard let faceRect = cropRect(
                        image, around: observation.boundingBox,
                        scale: 1.42, verticalBias: 0),
                      let face = image.cropping(to: faceRect.integral),
                      let portrait = crop(image, around: observation.boundingBox,
                                          scale: 3.7, verticalBias: 0.18),
                      let print = featurePrint(for: visionAlignedFace(
                        face, roll: observation.roll?.doubleValue)) else { return nil }
                let landmarks = fiveLandmarks(observation, in: image)
                let ir101Face = landmarks.flatMap {
                    affineAlignedFace(image, landmarks: $0)
                } ?? resizedFace(visionAlignedFace(
                    face, roll: observation.roll?.doubleValue))
                guard let ir101Face,
                      let kprpeFace = resizedFace(face) else { return nil }
                let kprpeKeypoints = landmarks.map {
                    normalizedLandmarks($0, cropRect: faceRect, imageHeight: image.height)
                } ?? [0.32, 0.38, 0.68, 0.38, 0.50,
                      0.56, 0.37, 0.73, 0.63, 0.73]
                return PhotosPersonCandidate(
                    id: UUID(), assetID: asset.localIdentifier,
                    createdAt: asset.creationDate, portrait: portrait, face: face,
                    quality: qualityObservation.faceCaptureQuality ?? 0.35,
                    isFavorite: asset.isFavorite,
                    featurePrint: print,
                    ir101Face: ir101Face,
                    kprpeFace: kprpeFace,
                    kprpeKeypoints: kprpeKeypoints,
                    ir101Embedding: nil,
                    kprpeEmbedding: nil)
            }
    }

    private func visionAlignedFace(_ image: CGImage, roll: Double?) -> CGImage {
        guard let roll, roll.isFinite, abs(roll) > 0.035, abs(roll) < 0.8 else {
            return image
        }
        let input = CIImage(cgImage: image)
        let center = CGPoint(x: input.extent.midX, y: input.extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(-roll))
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = input.transformed(by: transform)
        return ciContext.createCGImage(rotated, from: input.extent) ?? image
    }

    private func crop(_ image: CGImage, around normalized: CGRect,
                      scale: CGFloat, verticalBias: CGFloat) -> CGImage? {
        guard let rect = cropRect(
            image, around: normalized, scale: scale,
            verticalBias: verticalBias) else { return nil }
        return image.cropping(to: rect.integral)
    }

    private func cropRect(
        _ image: CGImage, around normalized: CGRect,
        scale: CGFloat, verticalBias: CGFloat
    ) -> CGRect? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let face = CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height)
        var side = max(face.width, face.height) * scale
        side = min(side, min(width, height))
        guard side >= 2 else { return nil }
        var rect = CGRect(
            x: face.midX - side / 2,
            y: face.midY - side / 2 + side * verticalBias,
            width: side, height: side)
        rect.origin.x = min(max(0, rect.origin.x), width - side)
        rect.origin.y = min(max(0, rect.origin.y), height - side)
        return rect
    }

    private func boundingDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.midX - second.midX) + abs(first.midY - second.midY)
            + abs(first.width - second.width) + abs(first.height - second.height)
    }

    private func fiveLandmarks(
        _ observation: VNFaceObservation, in image: CGImage
    ) -> [CGPoint]? {
        guard let landmarks = observation.landmarks,
              let left = landmarkCenter(landmarks.leftEye),
              let right = landmarkCenter(landmarks.rightEye),
              let noseRegion = landmarks.noseCrest ?? landmarks.nose,
              let nose = noseRegion.normalizedPoints.min(by: { $0.y < $1.y }),
              let lips = landmarks.outerLips?.normalizedPoints,
              let mouthLeft = lips.min(by: { $0.x < $1.x }),
              let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let box = observation.boundingBox
        func imagePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (box.minX + point.x * box.width) * width,
                y: (box.minY + point.y * box.height) * height)
        }
        let eyes = [imagePoint(left), imagePoint(right)].sorted { $0.x < $1.x }
        let mouth = [imagePoint(mouthLeft), imagePoint(mouthRight)].sorted { $0.x < $1.x }
        return [eyes[0], eyes[1], imagePoint(nose), mouth[0], mouth[1]]
    }

    private func landmarkCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count),
                       y: sum.y / CGFloat(points.count))
    }

    private func normalizedLandmarks(
        _ landmarks: [CGPoint], cropRect: CGRect, imageHeight: Int
    ) -> [Float] {
        landmarks.flatMap { point -> [Float] in
            let x = min(1, max(0, (point.x - cropRect.minX) / cropRect.width))
            let downY = CGFloat(imageHeight) - point.y
            let y = min(1, max(0, (downY - cropRect.minY) / cropRect.height))
            return [Float(x), Float(y)]
        }
    }

    private func affineAlignedFace(
        _ image: CGImage, landmarks source: [CGPoint]
    ) -> CGImage? {
        guard source.count == 5 else { return nil }
        let targetDown = [
            CGPoint(x: 38.2946, y: 51.6963),
            CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366),
            CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041),
        ]
        let target = targetDown.map { CGPoint(x: $0.x, y: 112 - $0.y) }
        let sourceCenter = source.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }.applying(CGAffineTransform(scaleX: 0.2, y: 0.2))
        let targetCenter = target.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }.applying(CGAffineTransform(scaleX: 0.2, y: 0.2))
        var denominator: CGFloat = 0, real: CGFloat = 0, imaginary: CGFloat = 0
        for index in source.indices {
            let x = source[index].x - sourceCenter.x
            let y = source[index].y - sourceCenter.y
            let u = target[index].x - targetCenter.x
            let v = target[index].y - targetCenter.y
            denominator += x * x + y * y
            real += x * u + y * v
            imaginary += x * v - y * u
        }
        guard denominator > 0 else { return nil }
        let a = real / denominator, b = imaginary / denominator
        let tx = targetCenter.x - a * sourceCenter.x + b * sourceCenter.y
        let ty = targetCenter.y - b * sourceCenter.x - a * sourceCenter.y
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
        let aligned = CIImage(cgImage: image).transformed(by: transform)
        return ciContext.createCGImage(
            aligned, from: CGRect(x: 0, y: 0, width: 112, height: 112))
    }

    private func resizedFace(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let transform = CGAffineTransform(
            scaleX: 112 / input.extent.width,
            y: 112 / input.extent.height)
        return ciContext.createCGImage(
            input.transformed(by: transform),
            from: CGRect(x: 0, y: 0, width: 112, height: 112))
    }

    private func featurePrint(for face: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: face, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    private func regroup() {
        let mode = PhotosGroupingMode(rawValue: groupingControl.selectedSegment) ?? .balanced
        let selectedModel = PhotosFaceIdentityModel(
            rawValue: modelControl.selectedSegment) ?? .ir101
        guard !rawCandidates.isEmpty else {
            groups = []
            benchmarkCopy = ""
            renderGroups()
            return
        }

        var reports: [PhotosFaceIdentityModel: [[Int]]] = [:]
        for model in PhotosFaceIdentityModel.allCases {
            if let indices = groupIndices(for: model, mode: mode) {
                reports[model] = indices
            }
        }
        guard let selectedIndices = reports[selectedModel] else {
            groups = []
            benchmarkCopy = ""
            showIdentityModelFailure(selectedModel)
            renderGroups()
            return
        }
        let effectiveModel = selectedModel
        groups = selectedIndices.map { indices in
            PhotosPersonGroup(
                id: UUID(),
                candidates: indices.map { rawCandidates[$0] }
                    .sorted { $0.quality > $1.quality })
        }
        benchmarkCopy = PhotosFaceIdentityModel.allCases.compactMap { model in
            guard let report = reports[model] else {
                return model == .vision ? nil : "\(model.shortName) 未载入"
            }
            let recurring = report.filter { $0.count >= 2 }.count
            let singles = report.filter { $0.count == 1 }.count
            return "\(model.shortName) \(recurring)人/\(singles)单张"
        }.joined(separator: " · ")

        let recurring = groups.filter { $0.candidates.count >= 2 }.count
        let singles = groups.filter { $0.candidates.count == 1 }.count
        resultSummaryLabel.stringValue = modelLabEnabled
            ? voice("\(effectiveModel.shortName) 找到 \(recurring) 位常出现的人",
                    "\(effectiveModel.shortName) found \(recurring) recurring people")
            : voice("找到 \(recurring) 位常出现的人",
                    "Found \(recurring) people who appear often")
        statusLabel.stringValue = modelLabEnabled
            ? voice(
                "\(rawCandidates.count) 张面孔 · \(singles) 张待确认\n\(benchmarkStatusCopy)",
                "\(rawCandidates.count) faces · \(singles) pending\n\(benchmarkStatusCopy)")
            : voice(
                "点一个人，再选择要参考的样子。照片不会上传。",
                "Choose a person, then choose the look to reference. Photos stay local.")
        writeBenchmark(reports: reports, selected: effectiveModel, mode: mode)
        renderGroups()
    }

    private var benchmarkStatusCopy: String {
        modelLabEnabled ? benchmarkCopy : voice(
            "身份整理已在本机完成 · 照片不会上传",
            "Identity grouping finished locally · photos were not uploaded")
    }

    private func groupIndices(
        for model: PhotosFaceIdentityModel, mode: PhotosGroupingMode
    ) -> [[Int]]? {
        if model == .vision { return visionGroupIndices(threshold: mode.threshold) }
        let samples = identitySamples(for: model)
        guard !samples.isEmpty else { return nil }
        var result = PhotosFaceClusterer.cluster(
            samples: samples, distanceThreshold: mode.threshold(for: model)).groups
        if model == .ir101 {
            let verifierSamples = identitySamples(for: .kprpe)
            if !verifierSamples.isEmpty {
                result = PhotosFaceClusterer.bridgeStableGroups(
                    result, verifierSamples: verifierSamples)
            }
        }
        let included = Set(result.flatMap { $0 })
        result.append(contentsOf: rawCandidates.indices
            .filter { !included.contains($0) }.map { [$0] })
        return result.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let lhs = $0.reduce(Float.zero) { $0 + rawCandidates[$1].quality }
            let rhs = $1.reduce(Float.zero) { $0 + rawCandidates[$1].quality }
            return lhs > rhs
        }
    }

    private func identitySamples(
        for model: PhotosFaceIdentityModel
    ) -> [PhotosFaceClusterSample] {
        rawCandidates.indices.compactMap { index -> PhotosFaceClusterSample? in
            let candidate = rawCandidates[index]
            let embedding = model == .ir101
                ? candidate.ir101Embedding : candidate.kprpeEmbedding
            guard let embedding else { return nil }
            return PhotosFaceClusterSample(
                index: index, assetID: candidate.assetID,
                captureQuality: candidate.quality, embedding: embedding)
        }
    }

    private func visionGroupIndices(threshold: Float) -> [[Int]] {
        let count = rawCandidates.count

        var distances = Array(
            repeating: Array(repeating: Float.greatestFiniteMagnitude, count: count),
            count: count)
        var edges: [(distance: Float, first: Int, second: Int)] = []
        for first in 0..<count {
            distances[first][first] = 0
            guard first + 1 < count else { continue }
            for second in (first + 1)..<count {
                guard rawCandidates[first].assetID != rawCandidates[second].assetID,
                      let distance = featureDistance(
                        rawCandidates[first].featurePrint,
                        rawCandidates[second].featurePrint) else { continue }
                distances[first][second] = distance
                distances[second][first] = distance
                if distance <= threshold {
                    edges.append((distance, first, second))
                }
            }
        }
        edges.sort { $0.distance < $1.distance }

        var partition = PhotosCandidatePartition(candidates: rawCandidates)
        for edge in edges {
            guard partition.canMerge(edge.first, edge.second) else { continue }
            let firstRoot = partition.root(of: edge.first)
            let secondRoot = partition.root(of: edge.second)
            let firstMembers = partition.members[firstRoot]
            let secondMembers = partition.members[secondRoot]
            guard mergeIsCoherent(
                firstMembers, secondMembers, threshold: threshold,
                distances: distances) else { continue }
            partition.merge(firstRoot, secondRoot)
        }

        return partition.groups().sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            let lhs = $0.reduce(Float.zero) { $0 + rawCandidates[$1].quality }
            let rhs = $1.reduce(Float.zero) { $0 + rawCandidates[$1].quality }
            return lhs > rhs
        }
    }

    private func writeBenchmark(
        reports: [PhotosFaceIdentityModel: [[Int]]],
        selected: PhotosFaceIdentityModel, mode: PhotosGroupingMode
    ) {
        var modelMetrics: [String: Any] = [:]
        for model in PhotosFaceIdentityModel.allCases {
            guard let report = reports[model] else { continue }
            let embedded = rawCandidates.filter { candidate in
                switch model {
                case .vision: return true
                case .ir101: return candidate.ir101Embedding != nil
                case .kprpe: return candidate.kprpeEmbedding != nil
                }
            }.count
            let milliseconds = inferenceMilliseconds[model] ?? 0
            modelMetrics[model.shortName] = [
                "groups": report.count,
                "recurringGroups": report.filter { $0.count >= 2 }.count,
                "singletons": report.filter { $0.count == 1 }.count,
                "largestGroup": report.map(\.count).max() ?? 0,
                "embeddedFaces": embedded,
                "totalInferenceMilliseconds": milliseconds,
                "meanInferenceMilliseconds": embedded > 0
                    ? milliseconds / Double(embedded) : 0,
            ]
        }
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "faceCount": rawCandidates.count,
            "selectedModel": selected.shortName,
            "groupingMode": mode.rawValue,
            "models": modelMetrics,
        ]
        if selected != .vision, let selectedGroups = reports[selected] {
            payload["selectedGroupPairs"] = PhotosFaceClusterer.pairDiagnostics(
                samples: identitySamples(for: selected), groups: selectedGroups
            ).map { pair in
                [
                    "firstGroup": pair.firstGroup,
                    "secondGroup": pair.secondGroup,
                    "firstSize": pair.firstSize,
                    "secondSize": pair.secondSize,
                    "centroidDistance": pair.centroidDistance,
                    "nearestDistance": pair.nearestDistance,
                    "tenthPercentileDistance": pair.tenthPercentileDistance,
                    "reciprocalNearestMedian": pair.reciprocalNearestMedian,
                    "medianDistance": pair.medianDistance,
                    "sharedAssetCount": pair.sharedAssetCount,
                ]
            }
            // Compare the exact same groups with the other dedicated face
            // model. This keeps group numbering stable while we test whether
            // a second model can safely bridge pose-related splits.
            for verifier in PhotosFaceIdentityModel.allCases
            where verifier != .vision && verifier != selected {
                let verifierSamples = identitySamples(for: verifier)
                guard !verifierSamples.isEmpty else { continue }
                payload["\(verifier.shortName)VerifierGroupPairs"] =
                    PhotosFaceClusterer.pairDiagnostics(
                        samples: verifierSamples, groups: selectedGroups
                    ).map { pair in
                        [
                            "firstGroup": pair.firstGroup,
                            "secondGroup": pair.secondGroup,
                            "firstSize": pair.firstSize,
                            "secondSize": pair.secondSize,
                            "centroidDistance": pair.centroidDistance,
                            "nearestDistance": pair.nearestDistance,
                            "tenthPercentileDistance": pair.tenthPercentileDistance,
                            "reciprocalNearestMedian": pair.reciprocalNearestMedian,
                            "medianDistance": pair.medianDistance,
                            "sharedAssetCount": pair.sharedAssetCount,
                        ]
                    }
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath:
            "/private/tmp/mimo-photos-people-benchmark-latest.json"), options: .atomic)
    }

    private func mergeIsCoherent(
        _ first: [Int], _ second: [Int], threshold: Float,
        distances: [[Float]]
    ) -> Bool {
        let smaller = first.count <= second.count ? first : second
        let larger = first.count <= second.count ? second : first
        let nearest = smaller.compactMap { member -> Float? in
            larger.map { distances[member][$0] }.min()
        }.sorted()
        guard let closest = nearest.first, closest <= threshold else { return false }

        if smaller.count == 1 {
            if larger.count < 3 { return true }
            let support = larger.map { distances[smaller[0]][$0] }
                .filter { $0 <= threshold * 1.12 }
            return support.count >= 2
        }

        let reciprocal = larger.compactMap { member in
            smaller.map { distances[member][$0] }.min()
        }
        let evidence = (nearest + reciprocal).sorted()
        let median = evidence[evidence.count / 2]
        return median <= threshold * 1.08
    }

    private func featureDistance(_ first: VNFeaturePrintObservation,
                                 _ second: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do { try first.computeDistance(&distance, to: second); return distance }
        catch { return nil }
    }

    private func installPreviewFixture() {
        let counts = [8, 5, 4, 3, 2, 1]
        let colors: [NSColor] = [
            .systemPurple, .systemTeal, .systemOrange,
            .systemPink, .systemBlue, .systemGreen,
        ]
        groups = counts.enumerated().compactMap { groupIndex, count in
            guard let avatar = previewAvatar(color: colors[groupIndex]),
                  let print = featurePrint(for: avatar) else { return nil }
            let candidates = (0..<count).map { item in
                PhotosPersonCandidate(
                    id: UUID(),
                    assetID: "preview-\(groupIndex)-\(item)",
                    createdAt: Calendar.current.date(
                        from: DateComponents(year: 2020 + item % 6, month: 6)),
                    portrait: avatar, face: avatar,
                    quality: max(0.32, 0.72 - Float(item) * 0.025),
                    isFavorite: item == 0,
                    featurePrint: print,
                    ir101Face: avatar,
                    kprpeFace: avatar,
                    kprpeKeypoints: [0.32, 0.38, 0.68, 0.38, 0.50,
                                     0.56, 0.37, 0.73, 0.63, 0.73],
                    ir101Embedding: nil,
                    kprpeEmbedding: nil)
            }
            return PhotosPersonGroup(id: UUID(), candidates: candidates)
        }
        resultSummaryLabel.stringValue = voice(
            "找到 5 位常出现的人", "Found 5 people who appear often")
        statusLabel.stringValue = voice(
            "点一个人，再选择要参考的样子。照片不会上传。",
            "Choose a person, then choose the look to reference. Photos stay local.")
        renderGroups()
    }

    private func previewAvatar(color: NSColor) -> CGImage? {
        let size = 320
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let accent = color.usingColorSpace(.deviceRGB) ?? color
        context.setFillColor(accent.withAlphaComponent(0.18).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(accent.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: CGRect(x: 74, y: 74, width: 172, height: 172))
        context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: CGRect(x: 114, y: 150, width: 20, height: 25))
        context.fillEllipse(in: CGRect(x: 186, y: 150, width: 20, height: 25))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(9)
        context.addArc(center: CGPoint(x: 160, y: 132), radius: 40,
                       startAngle: .pi * 1.12, endAngle: .pi * 1.88, clockwise: true)
        context.strokePath()
        return context.makeImage()
    }

    private func renderEmpty(_ message: String) {
        clearCards()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.stack",
                             accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        icon.contentTintColor = NSColor(calibratedRed: 0.48, green: 0.40,
                                        blue: 0.76, alpha: 0.72)
        let headline = label(
            voice("找到常出现的人", "Find the people who appear often"),
            size: 16, weight: .semibold)
        headline.alignment = .center
        let copy = label(message, size: 11, color: .secondaryLabelColor)
        copy.alignment = .center
        copy.maximumNumberOfLines = 3
        copy.lineBreakMode = .byWordWrapping
        let emptyStack = NSStackView(views: [icon, headline, copy])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        let empty = panelBox(
            fill: NSColor(calibratedRed: 0.50, green: 0.43, blue: 0.80, alpha: 0.055),
            border: NSColor(calibratedWhite: 0.45, alpha: 0.10))
        guard let content = empty.contentView else { return }
        content.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            empty.heightAnchor.constraint(equalToConstant: 210),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            emptyStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 28),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
        ])
        addFullWidthResult(empty)
    }

    private func renderGroups() {
        clearCards()
        guard !groups.isEmpty else {
            renderEmpty(voice("还没有可回看的候选。", "No groups to review yet."))
            return
        }
        let recurring = groups.enumerated().filter { $0.element.candidates.count >= 2 }
        let singles = groups.enumerated().filter { $0.element.candidates.count == 1 }

        if !recurring.isEmpty {
            addFullWidthResult(sectionHeader(
                voice("选择一个人", "Choose a person"),
                detail: voice("\(recurring.count) 位", "\(recurring.count) people")))
            for item in recurring.prefix(24) {
                addFullWidthResult(groupCard(item.element, index: item.offset))
            }
        } else {
            let note = label(
                voice("暂时没有找到重复出现的面孔。可以切换「宽松」，或手动选 2–8 张照片。",
                      "No repeated face yet. Try Broad grouping or choose 2–8 photos manually."),
                size: 11, color: .secondaryLabelColor)
            note.maximumNumberOfLines = 3
            note.lineBreakMode = .byWordWrapping
            let box = panelBox()
            box.contentView?.addSubview(note)
            note.translatesAutoresizingMaskIntoConstraints = false
            if let content = box.contentView {
                NSLayoutConstraint.activate([
                    note.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    note.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    note.topAnchor.constraint(equalTo: content.topAnchor),
                    note.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                    box.heightAnchor.constraint(equalToConstant: 68),
                ])
            }
            addFullWidthResult(box)
        }

        guard !singles.isEmpty else { return }
        let singlesToggle = NSButton(
            title: showingSingletons
                ? voice("收起 \(singles.count) 个单张线索", "Hide \(singles.count) single sightings")
                : voice("查看 \(singles.count) 个单张线索", "Show \(singles.count) single sightings"),
            target: self, action: #selector(toggleSingletons(_:)))
        singlesToggle.bezelStyle = .inline
        singlesToggle.controlSize = .small
        singlesToggle.contentTintColor = .secondaryLabelColor
        addFullWidthResult(singlesToggle)

        if showingSingletons {
            addFullWidthResult(sectionHeader(
                voice("只出现过一次", "Seen only once"),
                detail: voice("不会自动当作主角", "Never auto-selected")))
            for item in singles.prefix(24) {
                addFullWidthResult(groupCard(item.element, index: item.offset))
            }
        }
    }

    @objc private func toggleSingletons(_ sender: NSButton) {
        showingSingletons.toggle()
        renderGroups()
    }

    private func addFullWidthResult(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
    }

    private func sectionHeader(_ title: String, detail: String) -> NSView {
        let titleLabel = label(title, size: 12, weight: .semibold)
        let detailLabel = label(detail, size: 10, color: .secondaryLabelColor)
        let spacer = NSView()
        let row = NSStackView(views: [titleLabel, spacer, detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 5, left: 2, bottom: 2, right: 2)
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    private func clearCards() {
        cardsStack?.arrangedSubviews.forEach {
            cardsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func groupCard(_ group: PhotosPersonGroup, index: Int) -> NSView {
        let box = panelBox(
            fill: NSColor(calibratedWhite: 1, alpha: 0.62),
            border: NSColor(calibratedWhite: 0.32, alpha: 0.12))
        guard let content = box.contentView else { return box }

        // Always show the face that was embedded. A wider portrait can contain
        // a partner or friend and make a correct identity cluster look wrong.
        let preview = NSImageView(image: NSImage(cgImage: group.best.face,
                                                  size: NSSize(width: 64, height: 64)))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 12
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor(calibratedWhite: 0.90, alpha: 1).cgColor
        preview.toolTip = voice("这是本组实际比较的目标脸",
                                "This is the target face actually compared for this group")
        preview.setContentHuggingPriority(.required, for: .horizontal)
        preview.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = label(
            group.candidates.count >= 2
                ? voice("熟悉的人 \(String(format: "%02d", index + 1))",
                        "Familiar face \(String(format: "%02d", index + 1))")
                : voice("单张线索 \(String(format: "%02d", index + 1))",
                        "Single sighting \(String(format: "%02d", index + 1))"),
            size: 13, weight: .semibold)
        let detail = label(
            groupSummary(group), size: 10, color: .secondaryLabelColor)
        let copy = NSStackView(views: [name, detail])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 4
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let use = NSButton(
            title: group.candidates.count >= 2
                ? voice("选择样子", "Choose look") : voice("需要更多照片", "Needs more"),
            target: self, action: #selector(useGroup(_:)))
        use.tag = index
        use.bezelStyle = .rounded
        use.controlSize = .large
        use.isEnabled = group.candidates.count >= 2
        use.toolTip = group.candidates.count >= 2 ? nil
            : voice("至少需要两张相似人像。",
                    "At least two similar portraits are required.")
        if use.isEnabled {
            use.bezelColor = NSColor(calibratedRed: 0.43, green: 0.34,
                                      blue: 0.78, alpha: 1)
        }

        let spacer = NSView()
        let row = NSStackView(views: [preview, copy, spacer, use])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 88),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 64),
            preview.heightAnchor.constraint(equalToConstant: 64),
            use.widthAnchor.constraint(equalToConstant: 96),
        ])
        return box
    }

    private func groupSummary(_ group: PhotosPersonGroup) -> String {
        voice("\(group.candidates.count) 张照片", "\(group.candidates.count) photos")
    }

    @objc private func useGroup(_ sender: NSButton) {
        guard groups.indices.contains(sender.tag) else { return }
        presentPhotoSelection(for: sender.tag)
    }

    private func presentPhotoSelection(for groupIndex: Int) {
        guard groups.indices.contains(groupIndex), let parent = window else { return }
        if let existing = selectionSheet { parent.endSheet(existing) }

        let group = groups[groupIndex]
        selectionGroupIndex = groupIndex
        selectionCandidates = group.candidates.sorted { first, second in
            let firstDate = first.createdAt ?? .distantPast
            let secondDate = second.createdAt ?? .distantPast
            if firstDate != secondDate { return firstDate > secondDate }
            return first.quality > second.quality
        }
        selectedCandidateIDs = Set(referenceCandidates(
            from: group, preset: .recommended).map(\.id))

        let rowCount = (selectionCandidates.count + 3) / 4
        let sheetHeight = min(CGFloat(640), max(CGFloat(460),
            CGFloat(300 + min(rowCount, 3) * 120)))
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: sheetHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isMovableByWindowBackground = true
        sheet.isReleasedWhenClosed = false

        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(
            calibratedRed: 0.965, green: 0.952, blue: 0.985, alpha: 0.94).cgColor
        sheet.contentView = root

        let title = label(
            voice("选择 TA 的样子", "Choose how they should look"),
            size: 22, weight: .bold)
        let suggestedCount = min(6, group.candidates.count)
        let subtitle = label(
            voice("米墨先选了 \(suggestedCount) 张。你可以换成更像 TA 的照片，最多 8 张。",
                  "Mimo picked \(suggestedCount) to start. Choose the photos that look most like them, up to 8."),
            size: 11, color: .secondaryLabelColor)
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5

        let presetTitle = label(
            voice("以哪个样子为准", "Which look should Mimo use"),
            size: 10, weight: .semibold, color: .secondaryLabelColor)
        let presets = NSSegmentedControl(
            labels: [voice("米墨推荐", "Recommended"),
                     voice("最近的样子", "Recent look"),
                     voice("自己挑", "Choose myself")],
            trackingMode: .selectOne, target: self,
            action: #selector(appearancePresetChanged(_:)))
        presets.selectedSegment = PhotosAppearancePreset.recommended.rawValue
        presets.controlSize = .large
        appearanceControl = presets
        let presetStack = NSStackView(views: [presetTitle, presets])
        presetStack.orientation = .vertical
        presetStack.alignment = .leading
        presetStack.spacing = 6

        let grid = PhotosFlippedStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 12, right: 2)
        selectionButtons = []
        let columnCount = 4
        for start in stride(from: 0, to: selectionCandidates.count, by: columnCount) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 10
            row.distribution = .fillEqually
            for offset in 0..<columnCount {
                let candidateIndex = start + offset
                if selectionCandidates.indices.contains(candidateIndex) {
                    let candidate = selectionCandidates[candidateIndex]
                    let image = NSImage(
                        cgImage: candidate.portrait,
                        size: NSSize(width: 118, height: 118))
                    let button = NSButton(
                        image: image, target: self,
                        action: #selector(photoSelectionToggled(_:)))
                    button.tag = candidateIndex
                    button.setButtonType(.toggle)
                    button.isBordered = false
                    button.imageScaling = .scaleProportionallyUpOrDown
                    button.wantsLayer = true
                    button.layer?.cornerRadius = 13
                    button.layer?.masksToBounds = true
                    button.toolTip = voice(
                        "点一下选择或取消这张照片",
                        "Click to select or remove this photo")
                    button.translatesAutoresizingMaskIntoConstraints = false
                    button.heightAnchor.constraint(equalToConstant: 118).isActive = true
                    selectionButtons.append(button)

                    let year = candidate.createdAt.map {
                        String(Calendar.current.component(.year, from: $0))
                    } ?? ""
                    let yearLabel = label(year, size: 9, color: .secondaryLabelColor)
                    yearLabel.alignment = .center
                    let cell = NSStackView(views: [button, yearLabel])
                    cell.orientation = .vertical
                    cell.alignment = .centerX
                    cell.spacing = 4
                    row.addArrangedSubview(cell)
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = grid
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let count = label("", size: 11, weight: .semibold,
                          color: NSColor(calibratedRed: 0.43, green: 0.34,
                                         blue: 0.78, alpha: 1))
        selectionCountLabel = count
        let cancel = NSButton(
            title: voice("返回", "Back"), target: self,
            action: #selector(cancelPhotoSelection(_:)))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        let confirm = NSButton(
            title: voice("使用这些照片", "Use these photos"), target: self,
            action: #selector(confirmPhotoSelection(_:)))
        confirm.bezelStyle = .rounded
        confirm.controlSize = .large
        confirm.bezelColor = NSColor(calibratedRed: 0.43, green: 0.34,
                                      blue: 0.78, alpha: 1)
        selectionConfirmButton = confirm
        let footerSpacer = NSView()
        let footer = NSStackView(views: [count, footerSpacer, cancel, confirm])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        [header, presetStack, scroll, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 42),
            presetStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            presetStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            presetStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            presets.widthAnchor.constraint(equalTo: presetStack.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: presetStack.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            confirm.widthAnchor.constraint(equalToConstant: 132),
            cancel.widthAnchor.constraint(equalToConstant: 72),
        ])

        selectionSheet = sheet
        refreshPhotoSelectionUI()
        parent.beginSheet(sheet)
    }

    private func referenceCandidates(
        from group: PhotosPersonGroup,
        preset: PhotosAppearancePreset,
        limit: Int = 6
    ) -> [PhotosPersonCandidate] {
        let ranked: [PhotosPersonCandidate]
        switch preset {
        case .recent:
            ranked = group.candidates.sorted { first, second in
                let firstDate = first.createdAt ?? .distantPast
                let secondDate = second.createdAt ?? .distantPast
                if firstDate != secondDate { return firstDate > secondDate }
                return first.quality > second.quality
            }
        case .recommended:
            let quality = group.candidates.sorted { $0.quality > $1.quality }
            var priority: [PhotosPersonCandidate] = []
            if let favorite = quality.first(where: \.isFavorite) {
                priority.append(favorite)
            }
            if let recent = group.candidates
                .filter({ $0.createdAt != nil })
                .max(by: { $0.createdAt! < $1.createdAt! }),
               !priority.contains(where: { $0.id == recent.id }) {
                priority.append(recent)
            }
            priority.append(contentsOf: quality.filter { candidate in
                !priority.contains(where: { $0.id == candidate.id })
            })
            ranked = priority
        case .custom:
            ranked = group.candidates
        }
        return Array(ranked.prefix(min(limit, ranked.count)))
    }

    @objc private func appearancePresetChanged(_ sender: NSSegmentedControl) {
        guard let preset = PhotosAppearancePreset(rawValue: sender.selectedSegment),
              preset != .custom,
              let groupIndex = selectionGroupIndex,
              groups.indices.contains(groupIndex) else { return }
        selectedCandidateIDs = Set(referenceCandidates(
            from: groups[groupIndex], preset: preset).map(\.id))
        refreshPhotoSelectionUI()
    }

    @objc private func photoSelectionToggled(_ sender: NSButton) {
        guard selectionCandidates.indices.contains(sender.tag) else { return }
        let id = selectionCandidates[sender.tag].id
        if selectedCandidateIDs.contains(id) {
            selectedCandidateIDs.remove(id)
        } else if selectedCandidateIDs.count < 8 {
            selectedCandidateIDs.insert(id)
        } else {
            NSSound.beep()
        }
        appearanceControl?.selectedSegment = PhotosAppearancePreset.custom.rawValue
        refreshPhotoSelectionUI()
    }

    private func refreshPhotoSelectionUI() {
        for button in selectionButtons where selectionCandidates.indices.contains(button.tag) {
            let selected = selectedCandidateIDs.contains(selectionCandidates[button.tag].id)
            button.state = selected ? .on : .off
            button.layer?.borderWidth = selected ? 3 : 1
            button.layer?.borderColor = selected
                ? NSColor(calibratedRed: 0.43, green: 0.34,
                          blue: 0.78, alpha: 1).cgColor
                : NSColor(calibratedWhite: 0.35, alpha: 0.12).cgColor
            button.alphaValue = selected ? 1 : 0.72
        }
        let count = selectedCandidateIDs.count
        selectionCountLabel?.stringValue = voice(
            "已选 \(count) / 8 张", "\(count) of 8 selected")
        selectionConfirmButton?.isEnabled = count >= 2
    }

    @objc private func cancelPhotoSelection(_ sender: NSButton) {
        closePhotoSelection()
    }

    @objc private func confirmPhotoSelection(_ sender: NSButton) {
        let selected = selectionCandidates.filter {
            selectedCandidateIDs.contains($0.id)
        }.prefix(8)
        guard selected.count >= 2,
              let urls = writeTemporaryPortraits(Array(selected)), !urls.isEmpty else {
            NSSound.beep()
            return
        }
        statusLabel.stringValue = voice(
            "已选 \(urls.count) 张 · 正在交给 Mimo Studio…",
            "\(urls.count) selected · handing off to Mimo Studio…")
        closePhotoSelection()
        onSelect?(urls)
    }

    private func closePhotoSelection() {
        if let sheet = selectionSheet { window?.endSheet(sheet) }
        selectionSheet = nil
        selectionGroupIndex = nil
        selectionCandidates = []
        selectedCandidateIDs = []
        selectionButtons = []
        appearanceControl = nil
        selectionCountLabel = nil
        selectionConfirmButton = nil
    }

    @objc private func openPhotoPicker(_ sender: NSButton) {
        guard let presenter = window?.contentViewController else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 8
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.presentAsSheet(picker)
    }

    private func loadManualPickerResults(_ results: [PHPickerResult]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-photos-picker-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            statusLabel.stringValue = voice("无法准备所选照片。", "Could not prepare the selected photos.")
            return
        }
        rememberTemporaryPortraitDirectory(directory)

        let group = DispatchGroup()
        let lock = NSLock()
        var copied: [(Int, URL)] = []
        for (index, result) in results.prefix(8).enumerated() {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                continue
            }
            group.enter()
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let suffix = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                let destination = directory.appendingPathComponent(
                    "manual-\(index + 1).\(suffix)", isDirectory: false)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    lock.lock()
                    copied.append((index, destination))
                    lock.unlock()
                } catch { return }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let urls = copied.sorted { $0.0 < $1.0 }.map(\.1)
            guard !urls.isEmpty else {
                self.resultSummaryLabel.stringValue = voice("没有读到照片", "No photos loaded")
                self.statusLabel.stringValue = voice(
                    "可以再试一次，或检查 iCloud 下载状态。",
                    "Try again or check the iCloud download state.")
                return
            }
            self.resultSummaryLabel.stringValue = voice(
                "已选择 \(urls.count) 张照片", "\(urls.count) photos selected")
            self.statusLabel.stringValue = voice(
                "正在交给 Mimo Studio…", "Handing off to Mimo Studio…")
            self.onSelect?(urls)
        }
    }

    private func writeTemporaryPortraits(_ candidates: [PhotosPersonCandidate]) -> [URL]? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-photos-people-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        rememberTemporaryPortraitDirectory(directory)
        var urls: [URL] = []
        for (index, candidate) in candidates.enumerated() {
            let rep = NSBitmapImageRep(cgImage: candidate.portrait)
            guard let data = rep.representation(
                using: .jpeg, properties: [.compressionFactor: 0.9]) else { continue }
            let url = directory.appendingPathComponent(
                "photos-candidate-\(index + 1).jpg", isDirectory: false)
            do { try data.write(to: url, options: .atomic); urls.append(url) }
            catch { continue }
        }
        return urls
    }

    private func rememberTemporaryPortraitDirectory(_ directory: URL) {
        temporaryPortraitDirectories.insert(directory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            try? FileManager.default.removeItem(at: directory)
            self?.temporaryPortraitDirectories.remove(directory)
        }
    }

    private func purgeTemporaryPortraitDirectories() {
        let directories = temporaryPortraitDirectories
        temporaryPortraitDirectories.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func authorizationCopy() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return voice("✓ Photos 已授权 · 尚未扫描", "✓ Photos allowed · not scanned yet")
        case .limited:
            return voice("✓ 只读取你允许的照片", "✓ Limited to the photos you allowed")
        case .denied, .restricted:
            return voice("Photos 访问已关闭", "Photos access is off")
        case .notDetermined:
            return voice("只在你点击后请求权限", "Permission is requested only after your click")
        @unknown default:
            return voice("Photos 权限状态未知", "Unknown Photos permission state")
        }
    }

    private func panelBox(
        fill: NSColor = NSColor(calibratedWhite: 1, alpha: 0.46),
        border: NSColor = NSColor(calibratedWhite: 0.35, alpha: 0.10)
    ) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 16
        box.borderWidth = 1
        box.borderColor = border
        box.fillColor = fill
        box.contentViewMargins = NSSize(width: 13, height: 12)
        return box
    }

    private func pill(_ value: String, color: NSColor,
                      compact: Bool = false) -> NSView {
        let text = label(value, size: compact ? 9 : 10, weight: .semibold, color: color)
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = compact ? 8 : 10
        box.borderWidth = 0
        box.fillColor = color.withAlphaComponent(0.11)
        box.contentViewMargins = NSSize(width: compact ? 7 : 9, height: compact ? 3 : 5)
        guard let content = box.contentView else { return box }
        text.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            text.topAnchor.constraint(equalTo: content.topAnchor),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)
        return box
    }

    private func label(_ value: String, size: CGFloat,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

extension PhotosPeoplePrototypeController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController,
                didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(nil)
        guard !results.isEmpty else { return }
        resultSummaryLabel.stringValue = voice(
            "正在准备 \(results.count) 张照片…", "Preparing \(results.count) photos…")
        statusLabel.stringValue = voice(
            "系统选图器只会交给米墨你刚刚选择的照片。",
            "The system picker shares only the photos you selected.")
        loadManualPickerResults(results)
    }
}

extension AppDelegate {
    @objc func showPhotosPeoplePrototype() {
        PhotosPeoplePrototypeController.shared.show { [weak self] urls in
            guard let self else { return }
            self.showSettings()
            PhotosPeoplePrototypeController.shared.keepVisible(
                alongside: self.settingsWin)
            self.waitForStudioThenImportPhotos(urls, attempt: 0)
        }
    }

    private func waitForStudioThenImportPhotos(_ urls: [URL], attempt: Int) {
        guard attempt < 24, let web = settingsWeb else { return }
        web.evaluateJavaScript("typeof enqueuePetImageData === 'function'") {
            [weak self] result, _ in
            guard let self else { return }
            if result as? Bool == true {
                web.evaluateJavaScript("setSettingsTab('pet')", completionHandler: nil)
                self.importPetReferenceURLs(urls, skippedDueToLimit: 0)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.waitForStudioThenImportPhotos(urls, attempt: attempt + 1)
                }
            }
        }
    }
}
