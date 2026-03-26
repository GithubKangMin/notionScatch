import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class NotionSketchCoordinator: NSObject {
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var lastEditedImage: NSImage?
    private var targetApplication: NSRunningApplication?
    private var isCaptureFlowActive = false
    private var lastCaptureTriggerDate = Date.distantPast

    // File monitoring (polling)
    private var markupTempURL: URL?
    private var markupPollingTimer: Timer?
    private var markupOriginalModDate: Date?
    private var markupMonitorStartDate: Date?

    // Mouse position for re-selecting image in Notion
    private var capturedClickPosition: CGPoint?

    func start() {
        configureStatusItem()
        configureHotKeyMonitor()
        requestAccessibilityPermissionIfNeeded()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "NS"
        item.button?.toolTip = "Notion Scatch"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "선택한 Notion 이미지 스케치", action: #selector(beginCaptureFlowFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "마지막 결과 다시 붙여넣기", action: #selector(pasteLastEditedImage), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "접근성 권한 안내", action: #selector(showPermissionGuide), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    private func configureHotKeyMonitor() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            notionScatchHotKeyHandler,
            1,
            &eventSpec,
            userData,
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: notionScatchHotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    @objc
    private func beginCaptureFlowFromMenu() {
        beginCaptureFlow()
    }

    func handleRegisteredHotKey() {
        beginCaptureFlow()
    }

    private func beginCaptureFlow() {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTriggerDate) > 0.6 else { return }
        lastCaptureTriggerDate = now

        guard !isCaptureFlowActive else { return }
        isCaptureFlowActive = true

        guard AXIsProcessTrusted() else {
            isCaptureFlowActive = false
            requestAccessibilityPermissionIfNeeded()
            showAlert(
                title: "접근성 권한 필요",
                message: "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 notionScatch를 허용해야 Notion에 복사/붙여넣기를 보낼 수 있습니다."
            )
            return
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              isLikelyNotion(frontmostApp) else {
            isCaptureFlowActive = false
            showAlert(
                title: "Notion 앱을 먼저 선택하세요",
                message: "Notion 데스크톱 앱에서 이미지 블록을 선택한 상태로 Cmd+Shift+S를 누르세요."
            )
            return
        }

        targetApplication = frontmostApp

        // Save mouse position before copying — used to re-select the image block later
        capturedClickPosition = NSEvent.mouseLocation

        Task { @MainActor in
            do {
                let image = try await captureSelectedImage()
                openInPreview(with: image)
            } catch {
                isCaptureFlowActive = false
                showAlert(title: "이미지 복사 실패", message: error.localizedDescription)
            }
        }
    }

    private func openInPreview(with image: NSImage) {
        guard let tempURL = saveTempImage(image) else {
            isCaptureFlowActive = false
            showAlert(title: "오류", message: "이미지를 임시 파일로 저장할 수 없습니다.")
            return
        }

        markupTempURL = tempURL
        markupOriginalModDate = modificationDate(of: tempURL)
        startMonitoringFile(at: tempURL)

        // AppleScript: Finder에서 파일 선택 → Quick Look 열기 → Finder 창을 화면 밖으로
        let path = tempURL.path
        let script = NSAppleScript(source: """
            tell application "Finder"
                activate
                reveal (POSIX file "\(path)" as alias)
                select (POSIX file "\(path)" as alias)
            end tell
            delay 0.5
            tell application "System Events"
                tell process "Finder"
                    keystroke space
                end tell
            end tell
            delay 0.3
            -- Finder 창을 화면 밖으로 이동 (닫으면 Quick Look도 닫힘)
            tell application "Finder"
                try
                    set position of front window to {-3000, -3000}
                end try
            end tell
        """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            showAlert(title: "Quick Look 열기 실패", message: "\(errorInfo)")
        }
    }

    private func saveTempImage(_ image: NSImage) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/notionScatch-temp", isDirectory: true)
        // Clean old files
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tempURL = dir.appendingPathComponent("편집중.png")
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try pngData.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func startMonitoringFile(at url: URL) {
        markupPollingTimer?.invalidate()
        // Quick Look이 파일을 열면서 수정일이 바뀔 수 있으므로 5초 후부터 감시 시작
        markupMonitorStartDate = Date()
        markupPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkForFileChanges()
            }
        }
    }

    private func stopMonitoringFile() {
        markupPollingTimer?.invalidate()
        markupPollingTimer = nil
    }

    private func checkForFileChanges() {
        guard let tempURL = markupTempURL else {
            stopMonitoringFile()
            return
        }

        // Quick Look이 열리는 동안은 무시 (최소 5초 대기)
        if let startDate = markupMonitorStartDate,
           Date().timeIntervalSince(startDate) < 5.0 {
            // 매번 기준 시간을 갱신하여 Quick Look이 파일 속성을 바꿔도 무시
            markupOriginalModDate = modificationDate(of: tempURL)
            return
        }

        // 파일이 삭제되었으면 정리
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            cleanupMarkup()
            return
        }

        let newModDate = modificationDate(of: tempURL)
        guard newModDate != markupOriginalModDate else { return }

        // 파일이 수정됨 — Quick Look에서 "완료" 누른 것
        stopMonitoringFile()

        // Quick Look 닫기 + Finder 정리
        let closeScript = NSAppleScript(source: """
            tell application "System Events"
                tell process "Finder"
                    keystroke space
                end tell
            end tell
            delay 0.3
            tell application "Finder"
                try
                    close every window
                end try
            end tell
        """)
        closeScript?.executeAndReturnError(nil)

        if let data = try? Data(contentsOf: tempURL),
           let image = NSImage(data: data) {
            replaceSelectedImageInNotion(with: image)
        }

        // 정리: temp 폴더 삭제
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        markupTempURL = nil
        markupOriginalModDate = nil
    }

    private func cleanupMarkup() {
        stopMonitoringFile()
        if let url = markupTempURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            markupTempURL = nil
        }
        markupOriginalModDate = nil
        markupMonitorStartDate = nil
        isCaptureFlowActive = false
    }

    private func replaceSelectedImageInNotion(with image: NSImage) {
        lastEditedImage = image
        isCaptureFlowActive = false

        guard let app = targetApplication else {
            // Notion 앱을 찾지 못하면 클립보드에만 복사
            writeImageToPasteboard(image)
            showAlert(title: "클립보드에 복사됨", message: "Notion에서 원본 이미지를 선택 후 Delete → Cmd+V로 교체하세요.")
            return
        }

        writeImageToPasteboard(image)
        app.activate(options: [.activateIgnoringOtherApps])

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 이미지 블록 클릭하여 선택
            if let screenPos = capturedClickPosition {
                clickAtPosition(screenPos)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // 이미지 선택 상태에서 위쪽 블록으로 이동
            sendKey(keyCode: 126) // Up arrow
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Enter로 이미지 바로 위에 새 빈 블록 생성
            sendKey(keyCode: 36) // Enter
            try? await Task.sleep(nanoseconds: 200_000_000)

            // 새 빈 블록에 이미지 붙여넣기
            sendKey(keyCode: 9, modifiers: .maskCommand) // Cmd+V
            try? await Task.sleep(nanoseconds: 800_000_000)

            // 아래의 원본 이미지로 이동하여 삭제
            sendKey(keyCode: 125) // Down arrow
            try? await Task.sleep(nanoseconds: 300_000_000)
            sendKey(keyCode: 51) // Backspace (원본 삭제)
        }
    }

    /// Posts a mouse click at a screen position (in Cocoa screen coordinates).
    private func clickAtPosition(_ cocoaPoint: CGPoint) {
        // Convert Cocoa screen coords (origin bottom-left) to CG coords (origin top-left)
        // Use the main screen's full height for conversion (CG coordinate space)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: cocoaPoint.x, y: mainScreenHeight - cocoaPoint.y)

        let source = CGEventSource(stateID: .hidSystemState)
        // Move mouse first to ensure correct positioning
        let mouseMove = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left)
        mouseMove?.post(tap: .cghidEventTap)

        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: cgPoint, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: cgPoint, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)
    }

    @objc
    private func pasteLastEditedImage() {
        guard let image = lastEditedImage else {
            showAlert(title: "붙여넣을 이미지가 없습니다", message: "먼저 스케치 편집을 한 번 완료해 주세요.")
            return
        }

        writeImageToPasteboard(image)
        guard let app = targetApplication else { return }
        app.activate(options: [.activateIgnoringOtherApps])

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            sendKey(keyCode: 9, modifiers: .maskCommand)
        }
    }

    @objc
    private func showPermissionGuide() {
        showAlert(
            title: "사용 방법",
            message: """
            1. notionScatch를 실행해 둡니다.
            2. Notion 데스크톱 앱에서 바꾸고 싶은 이미지를 클릭해 선택합니다.
            3. Cmd+Shift+S를 누릅니다.
            4. Preview에서 편집(iPad 주석 가능) 후 Cmd+S로 저장하면 원래 자리로 교체를 시도합니다.
            """
        )
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func requestAccessibilityPermissionIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func captureSelectedImage() async throws -> NSImage {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount

        sendKey(keyCode: 8, modifiers: .maskCommand) // C

        // Wait for clipboard to change
        for _ in 0..<18 {
            try await Task.sleep(nanoseconds: 140_000_000)
            if pasteboard.changeCount != initialChangeCount {
                break
            }
        }

        // Try direct image from clipboard first
        if let image = await readImageFromPasteboard(pasteboard) {
            return image
        }

        // Resolve Notion attachment via local DB + signed URL
        let html = pasteboard.string(forType: .html)
        let text = pasteboard.string(forType: .string)
        if let image = await NotionImageResolver.resolve(clipboardHTML: html, clipboardText: text) {
            return image
        }

        let typeSummary = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "없음"
        throw NSError(
            domain: "notionScatch",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "선택된 이미지 블록을 클립보드에서 찾지 못했습니다. Notion에서 이미지가 파란 선택 상태인지 확인해 주세요.\n\n클립보드 타입: \(typeSummary)"
            ]
        )
    }

    private func readImageFromPasteboard(_ pasteboard: NSPasteboard) async -> NSImage? {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return image
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }

        if let fileURL = extractFileURL(from: pasteboard),
           let image = NSImage(contentsOf: fileURL) {
            return image
        }

        if let remoteURL = extractRemoteImageURL(from: pasteboard) {
            return await downloadImage(from: remoteURL)
        }

        debugLogPasteboardContents(pasteboard)
        return nil
    }

    private func extractFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let fileURLString = pasteboard.string(forType: .fileURL),
           let fileURL = URL(string: fileURLString),
           fileURL.isFileURL {
            return fileURL
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.first(where: \.isFileURL)
        }

        return nil
    }

    private func extractRemoteImageURL(from pasteboard: NSPasteboard) -> URL? {
        let candidates: [String?] = [
            pasteboard.string(forType: .html),
            pasteboard.string(forType: NSPasteboard.PasteboardType("org.chromium.source-url")),
            pasteboard.string(forType: .URL),
            pasteboard.string(forType: .string)
        ]

        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if let url = firstRemoteImageURL(in: candidate) {
                return url
            }
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let stringValue = item.string(forType: type), !stringValue.isEmpty {
                    if let url = firstRemoteImageURL(in: stringValue) {
                        return url
                    }
                }

                if let dataValue = item.data(forType: type),
                   let decoded = String(data: dataValue, encoding: .utf8),
                   !decoded.isEmpty {
                    if let url = firstRemoteImageURL(in: decoded) {
                        return url
                    }
                }

                if type.rawValue == "org.chromium.source-url",
                   let sourceURLString = item.string(forType: type),
                   let sourceURL = URL(string: sourceURLString),
                   isLikelyImageURL(sourceURL) {
                    return sourceURL
                }
            }
        }

        return nil
    }

    private func firstRemoteImageURL(in text: String) -> URL? {
        let patterns = [
            #"<img[^>]+src=["']([^"']+)["']"#,
            #"(https?://[^\s"'<>]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else {
                continue
            }

            let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            guard let swiftRange = Range(captureRange, in: text) else { continue }

            let raw = String(text[swiftRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            if isLikelyImageURL(url) {
                return url
            }
        }

        return nil
    }

    private func debugLogPasteboardContents(_ pasteboard: NSPasteboard) {
        let debugDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/notionScatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = debugDirectory.appendingPathComponent("pasteboard-\(timestamp).log")

        var lines: [String] = []
        lines.append("Pasteboard changeCount: \(pasteboard.changeCount)")
        let typeSummary = pasteboard.types?.map { $0.rawValue }.joined(separator: ", ") ?? "없음"
        lines.append("Types: \(typeSummary)")
        lines.append("")

        if let items = pasteboard.pasteboardItems {
            for (itemIndex, item) in items.enumerated() {
                lines.append("[Item \(itemIndex)]")
                for type in item.types {
                    lines.append("Type: \(type.rawValue)")

                    if let stringValue = item.string(forType: type) {
                        lines.append("String:")
                        lines.append(stringValue)
                    } else if let dataValue = item.data(forType: type) {
                        let utf8String = String(data: dataValue, encoding: .utf8) ?? "<non-utf8 data size=\(dataValue.count)>"
                        lines.append("Data:")
                        lines.append(utf8String)
                    } else {
                        lines.append("<no readable value>")
                    }

                    lines.append("")
                }
            }
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func isLikelyImageURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(url.pathExtension.lowercased()) {
            return true
        }

        return lower.contains("notion-static.com")
            || lower.contains("amazonaws.com")
            || lower.contains("secure.notion-static")
            || lower.contains("image")
    }

    private func downloadImage(from url: URL) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func writeImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func sendKey(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func isLikelyNotion(_ app: NSRunningApplication) -> Bool {
        let nameMatch = app.localizedName?.localizedCaseInsensitiveContains("Notion") == true
        let bundleMatch = app.bundleIdentifier?.localizedCaseInsensitiveContains("notion") == true
        return nameMatch || bundleMatch
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private let notionScatchHotKeySignature = fourCharCode("NSCH")

private let notionScatchHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr, hotKeyID.signature == notionScatchHotKeySignature else {
        return noErr
    }

    let coordinator = Unmanaged<NotionSketchCoordinator>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        coordinator.handleRegisteredHotKey()
    }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
