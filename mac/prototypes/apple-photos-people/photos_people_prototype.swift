// THROWAWAY PROTOTYPE — Apple Photos → local face candidates → Mimo DIY.
//
// Question: can explicit PhotoKit access plus local Vision analysis make
// choosing a familiar subject easier without treating Apple's Photos library
// as an identity database? This file deliberately calls every group
// “possibly the same person” and requires a click before any DIY handoff.

import Cocoa
import Photos
import Vision

private struct PhotosPersonCandidate {
    let id: UUID
    let assetID: String
    let createdAt: Date?
    let portrait: CGImage
    let face: CGImage
    let quality: Float
    let featurePrint: VNFeaturePrintObservation
}

private struct PhotosPersonGroup {
    let id: UUID
    var candidates: [PhotosPersonCandidate]

    var best: PhotosPersonCandidate { candidates.max { $0.quality < $1.quality }! }
    var meanQuality: Float {
        candidates.reduce(0) { $0 + $1.quality } / Float(max(1, candidates.count))
    }
}

final class PhotosPeoplePrototypeController: NSObject, NSWindowDelegate {
    static let shared = PhotosPeoplePrototypeController()

    private let imageManager = PHCachingImageManager()
    private var window: NSWindow?
    private var scanButton: NSButton!
    private var cloudCheckbox: NSButton!
    private var thresholdSlider: NSSlider!
    private var thresholdLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var cardsStack: NSStackView!
    private var rawCandidates: [PhotosPersonCandidate] = []
    private var groups: [PhotosPersonGroup] = []
    private var scanGeneration = UUID()
    private var scanning = false
    private var onSelect: (([URL]) -> Void)?

    func show(onSelect: @escaping ([URL]) -> Void) {
        self.onSelect = onSelect
        if window == nil { buildWindow() }
        guard let window else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        scanGeneration = UUID()
        scanning = false
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = voice("从照片找主角 · Prototype", "Find a subject in Photos · Prototype")
        window.minSize = NSSize(width: 760, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.97, green: 0.95,
                                               blue: 0.91, alpha: 1).cgColor
        window.contentView = root

        let title = label(
            voice("从你的照片里，找到一个熟悉的人",
                  "Find someone familiar in your Photos"),
            size: 25, weight: .semibold)
        let subtitle = label(
            voice("只扫最近 300 张 · Vision 本机整理 · 选中前不生成",
                  "Latest 300 only · grouped locally with Vision · nothing generates before selection"),
            size: 12, color: .secondaryLabelColor)
        subtitle.maximumNumberOfLines = 2

        scanButton = NSButton(
            title: voice("扫描最近照片", "Scan recent photos"),
            target: self, action: #selector(scanPressed(_:)))
        scanButton.bezelStyle = .rounded
        scanButton.controlSize = .large

        cloudCheckbox = NSButton(
            checkboxWithTitle: voice("需要时读取 iCloud 缩略图",
                                     "Allow iCloud thumbnails when needed"),
            target: nil, action: nil)
        cloudCheckbox.state = .off

        thresholdSlider = NSSlider(
            value: 0.46, minValue: 0.28, maxValue: 0.72,
            target: self, action: #selector(thresholdChanged(_:)))
        thresholdSlider.isContinuous = false
        thresholdLabel = label("", size: 10, color: .secondaryLabelColor)
        updateThresholdLabel()

        let thresholdRow = NSStackView(views: [
            label(voice("分组宽松度", "Grouping looseness"), size: 11),
            thresholdSlider, thresholdLabel,
        ])
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 8
        thresholdSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let controls = NSStackView(views: [scanButton, cloudCheckbox, thresholdRow])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 16

        statusLabel = label(
            authorizationCopy(), size: 11, color: .secondaryLabelColor)
        statusLabel.maximumNumberOfLines = 2

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        cardsStack = NSStackView()
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 14
        cardsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)
        scroll.documentView = cardsStack
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.widthAnchor.constraint(
            equalTo: scroll.contentView.widthAnchor).isActive = true

        [title, subtitle, controls, statusLabel, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 25),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            controls.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 19),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            statusLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 13),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        renderEmpty(
            voice("点击扫描后，macOS 才会询问 Photos 权限。",
                  "macOS asks for Photos access only after you click Scan."))
        self.window = window
    }

    @objc private func scanPressed(_ sender: NSButton) {
        if scanning {
            scanGeneration = UUID()
            scanning = false
            scanButton.title = voice("重新扫描", "Scan again")
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
        scanButton.title = voice("再试一次", "Try again")
        statusLabel.stringValue = voice(
            "Mimo 没有 Photos 读取权限。可在系统设置 → 隐私与安全性 → 照片中更改。",
            "Mimo cannot read Photos. Change access in System Settings → Privacy & Security → Photos.")
    }

    private func startScan() {
        let generation = UUID()
        scanGeneration = generation
        scanning = true
        rawCandidates = []
        groups = []
        renderEmpty(voice("正在找光线好、面部清楚的人像…",
                          "Looking for clear, well-lit portraits…"))
        scanButton.title = voice("停止", "Stop")
        let allowNetwork = cloudCheckbox.state == .on

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(
                key: "creationDate", ascending: false)]
            options.fetchLimit = 300
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            var candidates: [PhotosPersonCandidate] = []
            var unavailable = 0
            let total = assets.count

            for index in 0..<total {
                guard self.scanGeneration == generation else { return }
                autoreleasepool {
                    guard let image = self.image(
                        for: assets.object(at: index), allowNetwork: allowNetwork) else {
                        unavailable += 1
                        return
                    }
                    let found = self.candidates(
                        in: image, asset: assets.object(at: index))
                    candidates.append(contentsOf: found)
                    if candidates.count > 96 {
                        candidates.sort { $0.quality > $1.quality }
                        candidates.removeLast(candidates.count - 80)
                    }
                }
                if index % 12 == 0 || index == total - 1 {
                    let faceCount = candidates.count
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.statusLabel.stringValue = voice(
                            "已看 \(index + 1)/\(total) 张 · 找到 \(faceCount) 个可用人像",
                            "Checked \(index + 1)/\(total) · \(faceCount) usable portraits")
                    }
                }
            }

            candidates.sort { $0.quality > $1.quality }
            let final = Array(candidates.prefix(80))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.scanning = false
                self.scanButton.title = voice("重新扫描", "Scan again")
                self.rawCandidates = final
                self.regroup()
                let skipped = unavailable > 0
                    ? voice("· \(unavailable) 张当前不在本机", "· \(unavailable) not on this Mac") : ""
                self.statusLabel.stringValue = final.isEmpty
                    ? voice("没有找到足够清楚的人像 \(skipped)",
                            "No clear portraits found \(skipped)")
                    : voice("找到 \(final.count) 个人像，整理成 \(self.groups.count) 个待确认候选 \(skipped)",
                            "\(final.count) portraits in \(self.groups.count) groups to review \(skipped)")
            }
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
        return (request.results ?? [])
            .filter { observation in
                let box = observation.boundingBox
                return min(box.width, box.height) >= 0.065
                    && (observation.faceCaptureQuality ?? 0.35) >= 0.22
            }
            .sorted { ($0.faceCaptureQuality ?? 0.35) > ($1.faceCaptureQuality ?? 0.35) }
            .prefix(2)
            .compactMap { observation in
                guard let face = crop(image, around: observation.boundingBox,
                                      scale: 1.55, verticalBias: 0),
                      let portrait = crop(image, around: observation.boundingBox,
                                          scale: 3.7, verticalBias: 0.18),
                      let print = featurePrint(for: face) else { return nil }
                return PhotosPersonCandidate(
                    id: UUID(), assetID: asset.localIdentifier,
                    createdAt: asset.creationDate, portrait: portrait, face: face,
                    quality: observation.faceCaptureQuality ?? 0.35,
                    featurePrint: print)
            }
    }

    private func crop(_ image: CGImage, around normalized: CGRect,
                      scale: CGFloat, verticalBias: CGFloat) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let face = CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height)
        var side = max(face.width, face.height) * scale
        side = min(side, min(width, height))
        var rect = CGRect(
            x: face.midX - side / 2,
            y: face.midY - side / 2 + side * verticalBias,
            width: side, height: side)
        rect.origin.x = min(max(0, rect.origin.x), width - side)
        rect.origin.y = min(max(0, rect.origin.y), height - side)
        return image.cropping(to: rect.integral)
    }

    private func featurePrint(for face: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: face, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        updateThresholdLabel()
        if !rawCandidates.isEmpty { regroup() }
    }

    private func updateThresholdLabel() {
        thresholdLabel?.stringValue = String(format: "%.2f", thresholdSlider?.doubleValue ?? 0.46)
    }

    private func regroup() {
        let threshold = Float(thresholdSlider.doubleValue)
        var next: [PhotosPersonGroup] = []
        for candidate in rawCandidates {
            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for (index, group) in next.enumerated() {
                let distance = group.candidates.prefix(3).compactMap {
                    featureDistance(candidate.featurePrint, $0.featurePrint)
                }.min() ?? .greatestFiniteMagnitude
                if distance < bestDistance { bestDistance = distance; bestIndex = index }
            }
            if let index = bestIndex, bestDistance <= threshold {
                next[index].candidates.append(candidate)
            } else {
                next.append(PhotosPersonGroup(id: UUID(), candidates: [candidate]))
            }
        }
        groups = next.sorted {
            if $0.candidates.count != $1.candidates.count {
                return $0.candidates.count > $1.candidates.count
            }
            return $0.meanQuality > $1.meanQuality
        }
        renderGroups()
    }

    private func featureDistance(_ first: VNFeaturePrintObservation,
                                 _ second: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do { try first.computeDistance(&distance, to: second); return distance }
        catch { return nil }
    }

    private func renderEmpty(_ message: String) {
        clearCards()
        let empty = label(message, size: 14, color: .secondaryLabelColor)
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.heightAnchor.constraint(equalToConstant: 220).isActive = true
        cardsStack.addArrangedSubview(empty)
    }

    private func renderGroups() {
        clearCards()
        guard !groups.isEmpty else {
            renderEmpty(voice("还没有可回看的候选。", "No groups to review yet."))
            return
        }
        for start in stride(from: 0, to: min(groups.count, 15), by: 3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 278).isActive = true
            for offset in 0..<3 {
                let index = start + offset
                row.addArrangedSubview(index < groups.count
                    ? groupCard(groups[index], index: index) : NSView())
            }
            cardsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
        }
    }

    private func clearCards() {
        cardsStack?.arrangedSubviews.forEach {
            cardsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func groupCard(_ group: PhotosPersonGroup, index: Int) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 16
        box.borderWidth = 1
        box.borderColor = NSColor(calibratedWhite: 0.2, alpha: 0.13)
        box.fillColor = NSColor(calibratedRed: 0.995, green: 0.985, blue: 0.96, alpha: 1)
        box.contentViewMargins = NSSize(width: 12, height: 12)
        guard let content = box.contentView else { return box }

        let preview = NSImageView(image: NSImage(
            cgImage: group.best.portrait,
            size: NSSize(width: group.best.portrait.width,
                         height: group.best.portrait.height)))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 11
        preview.layer?.masksToBounds = true

        let faces = NSStackView()
        faces.orientation = .horizontal
        faces.spacing = 5
        for candidate in group.candidates.prefix(4) {
            let image = NSImageView(image: NSImage(
                cgImage: candidate.face,
                size: NSSize(width: candidate.face.width, height: candidate.face.height)))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 6
            image.layer?.masksToBounds = true
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 34).isActive = true
            image.heightAnchor.constraint(equalToConstant: 34).isActive = true
            faces.addArrangedSubview(image)
        }
        let name = label(
            voice("候选 \(index + 1) · 可能同一人",
                  "Candidate \(index + 1) · possibly the same person"),
            size: 12, weight: .semibold)
        let detail = label(
            voice("\(group.candidates.count) 张 · 清晰度 \(Int(group.meanQuality * 100))",
                  "\(group.candidates.count) photos · clarity \(Int(group.meanQuality * 100))"),
            size: 10, color: .secondaryLabelColor)
        let use = NSButton(
            title: voice("用这个人生成", "Use this person in DIY"),
            target: self, action: #selector(useGroup(_:)))
        use.tag = index
        use.bezelStyle = .rounded
        use.isEnabled = group.candidates.count >= 2
        use.toolTip = group.candidates.count >= 2 ? nil
            : voice("至少需要两张相似人像。",
                    "At least two similar portraits are required.")

        let stack = NSStackView(views: [preview, faces, name, detail, use])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 148),
            use.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return box
    }

    @objc private func useGroup(_ sender: NSButton) {
        guard groups.indices.contains(sender.tag) else { return }
        let selected = Array(groups[sender.tag].candidates
            .sorted { $0.quality > $1.quality }.prefix(4))
        guard selected.count >= 2,
              let urls = writeTemporaryPortraits(selected), !urls.isEmpty else {
            statusLabel.stringValue = voice("这组人像没有成功准备。",
                                            "This portrait group could not be prepared.")
            return
        }
        statusLabel.stringValue = voice(
            "已选 \(urls.count) 张 · 正在交给 Mimo Studio…",
            "\(urls.count) selected · handing off to Mimo Studio…")
        onSelect?(urls)
        window?.orderOut(nil)
    }

    private func writeTemporaryPortraits(_ candidates: [PhotosPersonCandidate]) -> [URL]? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-photos-people-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true) }
        catch { return nil }
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
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
            try? FileManager.default.removeItem(at: directory)
        }
        return urls
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

extension AppDelegate {
    @objc func showPhotosPeoplePrototype() {
        PhotosPeoplePrototypeController.shared.show { [weak self] urls in
            guard let self else { return }
            self.showSettings()
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
