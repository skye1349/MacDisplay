import AppKit
import CoreGraphics
import VirtualDisplayBridge

private struct DisplaySnapshot {
    let id: CGDirectDisplayID
    let name: String
    let bounds: CGRect
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isMain: Bool
    let isBuiltIn: Bool
    let isMirrored: Bool
    let mirrorsDisplayID: CGDirectDisplayID
    let rotation: Double
    let currentMode: CGDisplayMode?
    let modes: [CGDisplayMode]

    var persistentKey: String {
        "\(vendor)-\(model)-\(serial)"
    }
}

private final class ModeSelection: NSObject {
    let displayID: CGDirectDisplayID
    let mode: CGDisplayMode

    init(displayID: CGDirectDisplayID, mode: CGDisplayMode) {
        self.displayID = displayID
        self.mode = mode
    }
}

private final class DisplaySlider: NSSlider {
    var displayID: CGDirectDisplayID = 0
}

private final class DisplayManager {
    func activeDisplays() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }

        return ids.prefix(Int(count)).map { displayID in
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)

            return DisplaySnapshot(
                id: displayID,
                name: displayName(for: displayID),
                bounds: CGDisplayBounds(displayID),
                vendor: vendor,
                model: model,
                serial: serial,
                isMain: CGMainDisplayID() == displayID,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
                mirrorsDisplayID: CGDisplayMirrorsDisplay(displayID),
                rotation: CGDisplayRotation(displayID),
                currentMode: CGDisplayCopyDisplayMode(displayID),
                modes: availableModes(for: displayID)
            )
        }
    }

    func setMode(_ mode: CGDisplayMode, for displayID: CGDirectDisplayID) -> CGError {
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, let config else {
            return beginResult
        }

        let configureResult = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(config)
            return configureResult
        }

        return CGCompleteDisplayConfiguration(config, .forSession)
    }

    func mirror(displayID: CGDirectDisplayID, to masterID: CGDirectDisplayID) -> CGError {
        configureDisplay { config in
            CGConfigureDisplayMirrorOfDisplay(config, displayID, masterID)
        }
    }

    func stopMirroring(displayID: CGDirectDisplayID) -> CGError {
        configureDisplay { config in
            CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        }
    }

    func move(displayID: CGDirectDisplayID, rightOf anchorID: CGDirectDisplayID) -> CGError {
        let anchorBounds = CGDisplayBounds(anchorID)
        return configureDisplay { config in
            CGConfigureDisplayOrigin(config, displayID, Int32(anchorBounds.maxX), Int32(anchorBounds.minY))
        }
    }

    private func configureDisplay(_ body: (CGDisplayConfigRef) -> CGError) -> CGError {
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, let config else {
            return beginResult
        }

        let configureResult = body(config)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(config)
            return configureResult
        }

        return CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func availableModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }

        var seen = Set<String>()
        let sorted = rawModes.sorted { lhs, rhs in
            if lhs.width != rhs.width {
                return lhs.width > rhs.width
            }
            if lhs.height != rhs.height {
                return lhs.height > rhs.height
            }
            if lhs.pixelWidth != rhs.pixelWidth {
                return lhs.pixelWidth > rhs.pixelWidth
            }
            if lhs.pixelHeight != rhs.pixelHeight {
                return lhs.pixelHeight > rhs.pixelHeight
            }
            return lhs.refreshRate > rhs.refreshRate
        }

        return sorted.filter { mode in
            let key = modeKey(mode)
            return seen.insert(key).inserted
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        if vendor != 0 || model != 0 {
            return "Display \(displayID) (\(vendor):\(model))"
        }

        return "Display \(displayID)"
    }
}

private struct DisplayPreset: Codable {
    let id: UUID
    var name: String
    var displayKey: String
    var modeKey: String?
    var dimmingLevel: Double
}

private final class PresetManager {
    private let defaultsKey = "MacDisplay.presets"
    private let defaults = UserDefaults.standard

    var presets: [DisplayPreset] {
        get {
            guard let data = defaults.data(forKey: defaultsKey) else {
                return []
            }
            return (try? JSONDecoder().decode([DisplayPreset].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            defaults.set(data, forKey: defaultsKey)
        }
    }

    func save(_ preset: DisplayPreset) {
        var allPresets = presets
        allPresets.removeAll { $0.id == preset.id || ($0.displayKey == preset.displayKey && $0.name == preset.name) }
        allPresets.append(preset)
        allPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        presets = allPresets
    }

    func delete(id: UUID) {
        presets = presets.filter { $0.id != id }
    }
}

private struct HiDPIResolution {
    let framebufferWidth: Int
    let framebufferHeight: Int

    var logicalWidth: Int {
        framebufferWidth / 2
    }

    var logicalHeight: Int {
        framebufferHeight / 2
    }

    var label: String {
        "\(framebufferWidth)x\(framebufferHeight) (looks like \(logicalWidth)x\(logicalHeight) HiDPI)"
    }
}

private final class VirtualDisplaySession {
    let handle: MDVirtualDisplayHandle
    let displayID: CGDirectDisplayID
    let mirroredDisplayID: CGDirectDisplayID

    init(handle: MDVirtualDisplayHandle, displayID: CGDirectDisplayID, mirroredDisplayID: CGDirectDisplayID) {
        self.handle = handle
        self.displayID = displayID
        self.mirroredDisplayID = mirroredDisplayID
    }

    deinit {
        MDVirtualDisplayRelease(handle)
    }
}

private final class VirtualDisplayManager {
    private(set) var session: VirtualDisplaySession?

    var isAvailable: Bool {
        MDVirtualDisplayAPIAvailable()
    }

    var hasActiveSession: Bool {
        session != nil
    }

    func createHiDPIMirror(for display: DisplaySnapshot, targetWidth: Int, targetHeight: Int, displayManager: DisplayManager) throws -> CGDirectDisplayID {
        if session != nil {
            throw error("A MacDisplay virtual mirror is already active.")
        }

        guard targetWidth >= 640, targetHeight >= 360 else {
            throw error("Enter a valid target framebuffer size.")
        }

        guard targetWidth <= UInt32.max, targetHeight <= UInt32.max else {
            throw error("Target framebuffer is too large.")
        }

        guard isAvailable else {
            throw error("CGVirtualDisplay is not available on this macOS version.")
        }

        var handle: MDVirtualDisplayHandle?
        var virtualDisplayID: UInt32 = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let serial = display.serial == 0 ? display.id : display.serial
        let created = MDVirtualDisplayCreate(
            "MacDisplay Virtual HiDPI",
            UInt32(targetWidth),
            UInt32(targetHeight),
            60,
            true,
            serial,
            &handle,
            &virtualDisplayID,
            &errorBuffer,
            errorBuffer.count
        )

        guard created, let handle, virtualDisplayID != 0 else {
            let message = String(cString: errorBuffer)
            throw error(message.isEmpty ? "Could not create virtual display." : message)
        }

        let result = displayManager.mirror(displayID: display.id, to: virtualDisplayID)
        guard result == .success else {
            MDVirtualDisplayRelease(handle)
            throw error("Created virtual display \(virtualDisplayID), but mirroring failed with CoreGraphics error \(result.rawValue).")
        }

        session = VirtualDisplaySession(handle: handle, displayID: virtualDisplayID, mirroredDisplayID: display.id)
        return virtualDisplayID
    }

    func destroy(displayManager: DisplayManager) -> CGError? {
        guard let session else {
            return nil
        }

        let result = displayManager.stopMirroring(displayID: session.mirroredDisplayID)
        self.session = nil
        return result
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "MacDisplay.VirtualDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class HiDPIOverrideManager {
    private let fileManager = FileManager.default

    var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacDisplay/HiDPI", isDirectory: true)
    }

    func exportReport(displays: [DisplaySnapshot]) throws -> URL {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent("MacDisplay-display-report.txt")
        let report = displayReport(displays: displays)
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func createOverrideKit(display: DisplaySnapshot, targetWidth: Int, targetHeight: Int) throws -> URL {
        let vendorHex = hex(display.vendor)
        let productHex = hex(display.model)
        let kitURL = baseDirectory
            .appendingPathComponent("DisplayVendorID-\(vendorHex)", isDirectory: true)
            .appendingPathComponent("DisplayProductID-\(productHex)-kit", isDirectory: true)
        let vendorDirectoryName = "DisplayVendorID-\(vendorHex)"
        let productFileName = "DisplayProductID-\(productHex)"
        let plistURL = kitURL.appendingPathComponent("\(productFileName).plist")

        try fileManager.createDirectory(at: kitURL, withIntermediateDirectories: true)

        let resolutions = candidateResolutions(targetWidth: targetWidth, targetHeight: targetHeight)
        try overridePlist(display: display, resolutions: resolutions)
            .write(to: plistURL, atomically: true, encoding: .utf8)
        try installScript(vendorDirectoryName: vendorDirectoryName, productFileName: productFileName)
            .write(to: kitURL.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try uninstallScript(vendorDirectoryName: vendorDirectoryName, productFileName: productFileName)
            .write(to: kitURL.appendingPathComponent("uninstall.sh"), atomically: true, encoding: .utf8)
        try kitReadme(display: display, targetWidth: targetWidth, targetHeight: targetHeight, resolutions: resolutions)
            .write(to: kitURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try displayReport(displays: [display])
            .write(to: kitURL.appendingPathComponent("display-report.txt"), atomically: true, encoding: .utf8)

        try makeExecutable(kitURL.appendingPathComponent("install.sh"))
        try makeExecutable(kitURL.appendingPathComponent("uninstall.sh"))

        return kitURL
    }

    func installOverride(display: DisplaySnapshot, targetWidth: Int, targetHeight: Int) throws -> URL {
        let kitURL = try createOverrideKit(display: display, targetWidth: targetWidth, targetHeight: targetHeight)
        let vendorDirectoryName = "DisplayVendorID-\(hex(display.vendor))"
        let productFileName = "DisplayProductID-\(hex(display.model))"
        let plistURL = kitURL.appendingPathComponent("\(productFileName).plist")
        let targetDirectory = "/Library/Displays/Contents/Resources/Overrides/\(vendorDirectoryName)"
        let targetFile = "\(targetDirectory)/\(productFileName)"
        let command = [
            "/bin/mkdir -p \(shellQuote(targetDirectory))",
            "/bin/cp \(shellQuote(plistURL.path)) \(shellQuote(targetFile))",
            "/usr/sbin/chown root:wheel \(shellQuote(targetFile))",
            "/bin/chmod 0644 \(shellQuote(targetFile))",
            "/usr/bin/defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true"
        ].joined(separator: " && ")

        try runPrivilegedShell(command)
        return kitURL
    }

    func uninstallOverride(display: DisplaySnapshot) throws {
        let vendorDirectoryName = "DisplayVendorID-\(hex(display.vendor))"
        let productFileName = "DisplayProductID-\(hex(display.model))"
        let targetFile = "/Library/Displays/Contents/Resources/Overrides/\(vendorDirectoryName)/\(productFileName)"
        try runPrivilegedShell("/bin/rm -f \(shellQuote(targetFile))")
    }

    private func displayReport(displays: [DisplaySnapshot]) -> String {
        var lines: [String] = []
        lines.append("MacDisplay Display Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        for display in displays {
            lines.append("Display: \(display.name)")
            lines.append("  CGDisplayID: \(display.id)")
            lines.append("  Vendor/Product/Serial: \(display.vendor)/\(display.model)/\(display.serial)")
            lines.append("  Override path: /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(hex(display.vendor))/DisplayProductID-\(hex(display.model))")
            lines.append("  Bounds: \(Int(display.bounds.width))x\(Int(display.bounds.height)) at (\(Int(display.bounds.minX)), \(Int(display.bounds.minY)))")
            lines.append("  Main: \(display.isMain)")
            lines.append("  Built-in: \(display.isBuiltIn)")
            lines.append("  Mirrored: \(display.isMirrored)")
            lines.append("  Rotation: \(Int(display.rotation))")
            if let mode = display.currentMode {
                lines.append("  Current mode: \(modeTitle(mode))")
                lines.append("  Current logical pixels: \(mode.width)x\(mode.height)")
                lines.append("  Current framebuffer pixels: \(mode.pixelWidth)x\(mode.pixelHeight)")
                lines.append("  Current HiDPI: \(isHiDPIMode(mode))")
            }
            lines.append("  Available modes:")
            for mode in display.modes {
                lines.append("    - \(modeTitle(mode)); key=\(modeKey(mode))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func candidateResolutions(targetWidth: Int, targetHeight: Int) -> [HiDPIResolution] {
        let safeWidth = max(640, targetWidth)
        let safeHeight = max(360, targetHeight)
        let multipliers: [Double] = [1.0, 0.875, 5.0 / 6.0, 0.75, 2.0 / 3.0, 0.5]
        var seen = Set<String>()
        var result: [HiDPIResolution] = []

        for multiplier in multipliers {
            let width = makeEven(Int((Double(safeWidth) * multiplier).rounded()))
            let height = makeEven(Int((Double(safeHeight) * multiplier).rounded()))
            guard width >= 640, height >= 360 else {
                continue
            }

            let key = "\(width)x\(height)"
            if seen.insert(key).inserted {
                result.append(HiDPIResolution(framebufferWidth: width, framebufferHeight: height))
            }
        }

        return result
    }

    private func overridePlist(display: DisplaySnapshot, resolutions: [HiDPIResolution]) -> String {
        let productName = xmlEscape(display.name)
        let dataLines = resolutions.map { resolution in
            "    <data>\(scaleResolutionData(width: resolution.framebufferWidth, height: resolution.framebufferHeight).base64EncodedString())</data>"
        }.joined(separator: "\n")

        let serialBlock = display.serial == 0 ? "" : "  <key>DisplaySerialNumber</key>\n  <integer>\(display.serial)</integer>\n"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>DisplayProductName</key>
          <string>\(productName) MacDisplay HiDPI</string>
          <key>DisplayVendorID</key>
          <integer>\(display.vendor)</integer>
          <key>DisplayProductID</key>
          <integer>\(display.model)</integer>
        \(serialBlock)  <key>scale-resolutions</key>
          <array>
        \(dataLines)
          </array>
        </dict>
        </plist>
        """
    }

    private func installScript(vendorDirectoryName: String, productFileName: String) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        OVERRIDES_DIR="/Library/Displays/Contents/Resources/Overrides"
        TARGET_DIR="$OVERRIDES_DIR/\(vendorDirectoryName)"
        TARGET_FILE="$TARGET_DIR/\(productFileName)"

        echo "Installing MacDisplay HiDPI override:"
        echo "  $TARGET_FILE"
        sudo mkdir -p "$TARGET_DIR"
        sudo cp "$SCRIPT_DIR/\(productFileName).plist" "$TARGET_FILE"
        sudo chown root:wheel "$TARGET_FILE"
        sudo chmod 0644 "$TARGET_FILE"
        sudo defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true

        echo
        echo "Installed. Restart macOS, then open System Settings > Displays."
        echo "If the display goes out of range, run uninstall.sh from this folder and restart."
        """
    }

    private func uninstallScript(vendorDirectoryName: String, productFileName: String) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        TARGET_FILE="/Library/Displays/Contents/Resources/Overrides/\(vendorDirectoryName)/\(productFileName)"
        echo "Removing MacDisplay HiDPI override:"
        echo "  $TARGET_FILE"
        sudo rm -f "$TARGET_FILE"
        echo "Removed. Restart macOS."
        """
    }

    private func kitReadme(display: DisplaySnapshot, targetWidth: Int, targetHeight: Int, resolutions: [HiDPIResolution]) -> String {
        let modeLines = resolutions.map { "- \($0.label)" }.joined(separator: "\n")
        return """
        MacDisplay HiDPI Override Kit

        Display:
        - Name: \(display.name)
        - Vendor ID: \(display.vendor) / 0x\(hex(display.vendor))
        - Product ID: \(display.model) / 0x\(hex(display.model))
        - Serial: \(display.serial)
        - Target framebuffer: \(targetWidth)x\(targetHeight)

        Generated scale resolutions:
        \(modeLines)

        Install:
          ./install.sh

        Uninstall:
          ./uninstall.sh

        Notes:
        - Restart macOS after installing or uninstalling.
        - On Apple Silicon, macOS may still reject some custom HiDPI overrides.
        - If your cable or adapter cannot carry the target framebuffer, this override cannot make the signal physically possible.
        - For Samsung 57-inch Neo G9, the clearest baseline is usually 7680x2160 framebuffer with a 3840x1080 HiDPI logical desktop.
        """
    }

    private func scaleResolutionData(width: Int, height: Int) -> Data {
        var values = [
            UInt32(width).bigEndian,
            UInt32(height).bigEndian,
            UInt32(1).bigEndian,
            UInt32(0x0020_0000).bigEndian
        ]
        return Data(bytes: &values, count: MemoryLayout<UInt32>.size * values.count)
    }

    private func makeExecutable(_ url: URL) throws {
        var attributes = try fileManager.attributesOfItem(atPath: url.path)
        attributes[.posixPermissions] = 0o755
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func makeEven(_ value: Int) -> Int {
        value % 2 == 0 ? value : value - 1
    }

    private func hex(_ value: UInt32) -> String {
        String(format: "%x", value)
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func shellQuote(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ string: String) -> String {
        "\"\(string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func runPrivilegedShell(_ command: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptString(command)) with administrator privileges"
        ]
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MacDisplay.HiDPIOverride",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Administrator authorization failed or was cancelled."]
            )
        }
    }
}

private final class DimmerController {
    private var dimmingLevels: [CGDirectDisplayID: Double] = [:]
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    func level(for displayID: CGDirectDisplayID) -> Double {
        dimmingLevels[displayID, default: 0]
    }

    func setLevel(_ level: Double, for displayID: CGDirectDisplayID) {
        let clampedLevel = min(max(level, 0), 0.9)
        dimmingLevels[displayID] = clampedLevel
        applyLevel(clampedLevel, for: displayID)
    }

    func refreshWindows(activeDisplayIDs: Set<CGDirectDisplayID>) {
        for displayID in Array(windows.keys) where !activeDisplayIDs.contains(displayID) {
            windows[displayID]?.close()
            windows.removeValue(forKey: displayID)
            dimmingLevels.removeValue(forKey: displayID)
        }

        for (displayID, level) in dimmingLevels {
            applyLevel(level, for: displayID)
        }
    }

    private func applyLevel(_ level: Double, for displayID: CGDirectDisplayID) {
        guard level > 0.001 else {
            windows[displayID]?.close()
            windows.removeValue(forKey: displayID)
            return
        }

        guard let screen = NSScreen.screen(with: displayID) else {
            return
        }

        let window = windows[displayID] ?? makeWindow(for: screen)
        if window.screen != screen || window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }

        window.backgroundColor = NSColor.black.withAlphaComponent(level)
        window.alphaValue = 1
        window.orderFrontRegardless()
        windows[displayID] = window
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        return window
    }
}

private final class ControlPanelWindowController: NSWindowController {
    private let displayManager: DisplayManager
    private let dimmerController: DimmerController
    private let presetManager = PresetManager()
    private let hidpiOverrideManager = HiDPIOverrideManager()
    private let virtualDisplayManager = VirtualDisplayManager()
    private let onStateChange: () -> Void

    private var displays: [DisplaySnapshot] = []
    private var selectedDisplayID: CGDirectDisplayID?

    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dimmingSlider = NSSlider(value: 0, minValue: 0, maxValue: 0.95, target: nil, action: nil)
    private let dimmingValueLabel = NSTextField(labelWithString: "0%")
    private let statusLabel = NSTextField(labelWithString: "")
    private let identityLabel = NSTextField(labelWithString: "")
    private let modeDetailsLabel = NSTextField(labelWithString: "")
    private let mirrorButton = NSButton(title: "Mirror to Main", target: nil, action: nil)
    private let unmirrorButton = NSButton(title: "Stop Mirroring", target: nil, action: nil)
    private let moveRightButton = NSButton(title: "Move Right of Main", target: nil, action: nil)
    private let presetNameField = NSTextField()
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyModeButton = NSButton(title: "Apply Mode", target: nil, action: nil)
    private let savePresetButton = NSButton(title: "Save Preset", target: nil, action: nil)
    private let applyPresetButton = NSButton(title: "Apply Preset", target: nil, action: nil)
    private let deletePresetButton = NSButton(title: "Delete Preset", target: nil, action: nil)
    private let hidpiWidthField = NSTextField()
    private let hidpiHeightField = NSTextField()
    private let installHiDPIButton = NSButton(title: "Install HiDPI Override", target: nil, action: nil)
    private let removeHiDPIButton = NSButton(title: "Remove Override", target: nil, action: nil)
    private let exportHiDPIKitButton = NSButton(title: "Export Kit", target: nil, action: nil)
    private let createVirtualMirrorButton = NSButton(title: "Create Virtual HiDPI Mirror", target: nil, action: nil)
    private let removeVirtualMirrorButton = NSButton(title: "Remove Virtual Mirror", target: nil, action: nil)
    private let exportReportButton = NSButton(title: "Export Report", target: nil, action: nil)
    private let openHiDPIFolderButton = NSButton(title: "Open HiDPI Folder", target: nil, action: nil)
    private let hidpiInfoLabel = NSTextField(labelWithString: "")

    init(displayManager: DisplayManager, dimmerController: DimmerController, onStateChange: @escaping () -> Void) {
        self.displayManager = displayManager
        self.dimmerController = dimmerController
        self.onStateChange = onStateChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacDisplay"
        window.minSize = NSSize(width: 720, height: 650)
        window.center()

        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshClicked() {
        refresh()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        let titleLabel = NSTextField(labelWithString: "MacDisplay")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        root.addArrangedSubview(titleLabel)

        root.addArrangedSubview(displaySelectorSection())
        root.addArrangedSubview(modeSection())
        root.addArrangedSubview(hiDPISection())
        root.addArrangedSubview(brightnessSection())
        root.addArrangedSubview(arrangementSection())
        root.addArrangedSubview(presetSection())

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(refreshButton)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(quitButton)

        root.addArrangedSubview(buttonRow)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    fileprivate func refresh() {
        displays = displayManager.activeDisplays()
        if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        }

        populateDisplayPopup()
        populateModePopup()
        populatePresetPopup()
        updateControlState()
    }

    private func displaySelectorSection() -> NSView {
        let section = makeSection(title: "Display")
        let row = makeRow()

        displayPopup.target = self
        displayPopup.action = #selector(selectedDisplayChanged)
        displayPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        row.addArrangedSubview(displayPopup)

        identityLabel.font = .systemFont(ofSize: 12)
        identityLabel.textColor = .secondaryLabelColor
        identityLabel.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(identityLabel)

        section.addArrangedSubview(row)
        return section
    }

    private func modeSection() -> NSView {
        let section = makeSection(title: "Resolution")
        let row = makeRow()

        modePopup.target = self
        modePopup.action = #selector(modePopupChanged)
        modePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        row.addArrangedSubview(modePopup)

        applyModeButton.target = self
        applyModeButton.action = #selector(applyModeClicked)
        applyModeButton.bezelStyle = .rounded
        row.addArrangedSubview(applyModeButton)

        modeDetailsLabel.font = .systemFont(ofSize: 12)
        modeDetailsLabel.textColor = .secondaryLabelColor
        modeDetailsLabel.lineBreakMode = .byTruncatingTail

        section.addArrangedSubview(row)
        section.addArrangedSubview(modeDetailsLabel)
        return section
    }

    private func brightnessSection() -> NSView {
        let section = makeSection(title: "Brightness")
        let row = makeRow()

        let label = NSTextField(labelWithString: "Software dimming")
        label.font = .systemFont(ofSize: 13)
        row.addArrangedSubview(label)

        dimmingSlider.target = self
        dimmingSlider.action = #selector(dimmingChanged)
        dimmingSlider.isContinuous = true
        dimmingSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        row.addArrangedSubview(dimmingSlider)

        dimmingValueLabel.alignment = .right
        dimmingValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dimmingValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(dimmingValueLabel)

        section.addArrangedSubview(row)
        return section
    }

    private func hiDPISection() -> NSView {
        let section = makeSection(title: "HiDPI Override")
        let targetRow = makeRow()

        let targetLabel = NSTextField(labelWithString: "Target framebuffer")
        targetLabel.font = .systemFont(ofSize: 13)
        targetRow.addArrangedSubview(targetLabel)

        hidpiWidthField.placeholderString = "7680"
        hidpiWidthField.alignment = .right
        hidpiWidthField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hidpiWidthField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        targetRow.addArrangedSubview(hidpiWidthField)

        targetRow.addArrangedSubview(NSTextField(labelWithString: "x"))

        hidpiHeightField.placeholderString = "2160"
        hidpiHeightField.alignment = .right
        hidpiHeightField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hidpiHeightField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        targetRow.addArrangedSubview(hidpiHeightField)

        let buttonRow = makeRow()
        installHiDPIButton.target = self
        installHiDPIButton.action = #selector(installHiDPIOverrideClicked)
        installHiDPIButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(installHiDPIButton)

        removeHiDPIButton.target = self
        removeHiDPIButton.action = #selector(removeHiDPIOverrideClicked)
        removeHiDPIButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(removeHiDPIButton)

        exportHiDPIKitButton.target = self
        exportHiDPIKitButton.action = #selector(exportHiDPIKitClicked)
        exportHiDPIKitButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(exportHiDPIKitButton)

        exportReportButton.target = self
        exportReportButton.action = #selector(exportReportClicked)
        exportReportButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(exportReportButton)

        openHiDPIFolderButton.target = self
        openHiDPIFolderButton.action = #selector(openHiDPIFolderClicked)
        openHiDPIFolderButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(openHiDPIFolderButton)

        let virtualRow = makeRow()
        let virtualLabel = NSTextField(labelWithString: "Virtual display")
        virtualLabel.font = .systemFont(ofSize: 13)
        virtualRow.addArrangedSubview(virtualLabel)

        createVirtualMirrorButton.target = self
        createVirtualMirrorButton.action = #selector(createVirtualHiDPIMirrorClicked)
        createVirtualMirrorButton.bezelStyle = .rounded
        virtualRow.addArrangedSubview(createVirtualMirrorButton)

        removeVirtualMirrorButton.target = self
        removeVirtualMirrorButton.action = #selector(removeVirtualMirrorClicked)
        removeVirtualMirrorButton.bezelStyle = .rounded
        virtualRow.addArrangedSubview(removeVirtualMirrorButton)

        hidpiInfoLabel.font = .systemFont(ofSize: 12)
        hidpiInfoLabel.textColor = .secondaryLabelColor
        hidpiInfoLabel.lineBreakMode = .byWordWrapping
        hidpiInfoLabel.maximumNumberOfLines = 3
        hidpiInfoLabel.preferredMaxLayoutWidth = 700
        hidpiInfoLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700).isActive = true

        section.addArrangedSubview(targetRow)
        section.addArrangedSubview(buttonRow)
        section.addArrangedSubview(virtualRow)
        section.addArrangedSubview(hidpiInfoLabel)
        return section
    }

    private func arrangementSection() -> NSView {
        let section = makeSection(title: "Arrangement")
        let row = makeRow()

        mirrorButton.target = self
        mirrorButton.action = #selector(mirrorToMainClicked)
        mirrorButton.bezelStyle = .rounded
        row.addArrangedSubview(mirrorButton)

        unmirrorButton.target = self
        unmirrorButton.action = #selector(stopMirroringClicked)
        unmirrorButton.bezelStyle = .rounded
        row.addArrangedSubview(unmirrorButton)

        moveRightButton.target = self
        moveRightButton.action = #selector(moveRightOfMainClicked)
        moveRightButton.bezelStyle = .rounded
        row.addArrangedSubview(moveRightButton)

        section.addArrangedSubview(row)
        return section
    }

    private func presetSection() -> NSView {
        let section = makeSection(title: "Presets")
        let saveRow = makeRow()

        presetNameField.placeholderString = "Preset name"
        presetNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        saveRow.addArrangedSubview(presetNameField)

        savePresetButton.target = self
        savePresetButton.action = #selector(savePresetClicked)
        savePresetButton.bezelStyle = .rounded
        saveRow.addArrangedSubview(savePresetButton)

        let applyRow = makeRow()
        presetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        applyRow.addArrangedSubview(presetPopup)

        applyPresetButton.target = self
        applyPresetButton.action = #selector(applyPresetClicked)
        applyPresetButton.bezelStyle = .rounded
        applyRow.addArrangedSubview(applyPresetButton)

        deletePresetButton.target = self
        deletePresetButton.action = #selector(deletePresetClicked)
        deletePresetButton.bezelStyle = .rounded
        applyRow.addArrangedSubview(deletePresetButton)

        section.addArrangedSubview(saveRow)
        section.addArrangedSubview(applyRow)
        return section
    }

    private func makeSection(title: String) -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        section.widthAnchor.constraint(greaterThanOrEqualToConstant: 680).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        section.addArrangedSubview(label)

        return section
    }

    private func makeRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func populateDisplayPopup() {
        let selectedID = selectedDisplayID
        displayPopup.removeAllItems()

        for display in displays {
            displayPopup.addItem(withTitle: display.name + (display.isMain ? " - Main" : ""))
            displayPopup.lastItem?.representedObject = NSNumber(value: display.id)
        }

        if let selectedID,
           let item = displayPopup.itemArray.first(where: { ($0.representedObject as? NSNumber)?.uint32Value == selectedID }) {
            displayPopup.select(item)
        }
    }

    private func populateModePopup() {
        modePopup.removeAllItems()
        guard let display = selectedDisplay else {
            return
        }

        for mode in display.modes.prefix(120) {
            modePopup.addItem(withTitle: modeTitle(mode))
            modePopup.lastItem?.representedObject = modeKey(mode)
        }

        if let currentMode = display.currentMode {
            selectMode(withKey: modeKey(currentMode))
        }
    }

    private func populatePresetPopup() {
        presetPopup.removeAllItems()
        guard let display = selectedDisplay else {
            return
        }

        let presets = presetManager.presets.filter { $0.displayKey == display.persistentKey }
        for preset in presets {
            presetPopup.addItem(withTitle: preset.name)
            presetPopup.lastItem?.representedObject = preset.id.uuidString
        }
    }

    private func updateControlState() {
        guard let display = selectedDisplay else {
            identityLabel.stringValue = "No active display"
            modeDetailsLabel.stringValue = ""
            setControlsEnabled(false)
            return
        }

        setControlsEnabled(true)
        identityLabel.stringValue = "ID \(display.id) - vendor \(display.vendor), model \(display.model), serial \(display.serial)"
        modeDetailsLabel.stringValue = controlPanelDetails(display)
        updateHiDPIFields(display)

        let dimming = dimmerController.level(for: display.id)
        dimmingSlider.doubleValue = dimming
        dimmingValueLabel.stringValue = "\(Int(dimming * 100))%"

        let canArrange = displays.count > 1
        mirrorButton.isEnabled = canArrange && !display.isMain
        unmirrorButton.isEnabled = canArrange && display.isMirrored
        moveRightButton.isEnabled = canArrange && !display.isMain
        applyPresetButton.isEnabled = presetPopup.numberOfItems > 0
        deletePresetButton.isEnabled = presetPopup.numberOfItems > 0
        createVirtualMirrorButton.isEnabled = virtualDisplayManager.isAvailable && !virtualDisplayManager.hasActiveSession
        removeVirtualMirrorButton.isEnabled = virtualDisplayManager.hasActiveSession
    }

    private func setControlsEnabled(_ enabled: Bool) {
        modePopup.isEnabled = enabled
        dimmingSlider.isEnabled = enabled
        applyModeButton.isEnabled = enabled
        mirrorButton.isEnabled = false
        unmirrorButton.isEnabled = false
        moveRightButton.isEnabled = false
        savePresetButton.isEnabled = enabled
        applyPresetButton.isEnabled = false
        deletePresetButton.isEnabled = false
        hidpiWidthField.isEnabled = enabled
        hidpiHeightField.isEnabled = enabled
        installHiDPIButton.isEnabled = enabled
        removeHiDPIButton.isEnabled = enabled
        exportHiDPIKitButton.isEnabled = enabled
        createVirtualMirrorButton.isEnabled = enabled && virtualDisplayManager.isAvailable && !virtualDisplayManager.hasActiveSession
        removeVirtualMirrorButton.isEnabled = virtualDisplayManager.hasActiveSession
        exportReportButton.isEnabled = enabled
        openHiDPIFolderButton.isEnabled = true
    }

    private var selectedDisplay: DisplaySnapshot? {
        guard let selectedDisplayID else {
            return nil
        }
        return displays.first { $0.id == selectedDisplayID }
    }

    private func controlPanelDetails(_ display: DisplaySnapshot) -> String {
        let builtInText = display.isBuiltIn ? "Built-in" : "External"
        let mirrorText: String
        if display.mirrorsDisplayID != kCGNullDirectDisplay {
            mirrorText = " - mirrors \(display.mirrorsDisplayID)"
        } else {
            mirrorText = ""
        }

        guard let mode = display.currentMode else {
            return "\(builtInText) - \(Int(display.bounds.width))x\(Int(display.bounds.height)) - rotation \(Int(display.rotation)) deg\(mirrorText)"
        }

        let refresh = mode.refreshRate > 0 ? String(format: " @ %.0fHz", mode.refreshRate) : ""
        let scale = isHiDPIMode(mode) ? " HiDPI" : ""
        return "\(builtInText) - \(mode.width)x\(mode.height)\(refresh)\(scale) - physical \(mode.pixelWidth)x\(mode.pixelHeight) - rotation \(Int(display.rotation)) deg\(mirrorText)"
    }

    private func updateHiDPIFields(_ display: DisplaySnapshot) {
        let width = display.currentMode?.pixelWidth ?? Int(display.bounds.width)
        let height = display.currentMode?.pixelHeight ?? Int(display.bounds.height)
        if hidpiWidthField.stringValue.isEmpty || hidpiHeightField.stringValue.isEmpty {
            hidpiWidthField.stringValue = "\(width)"
            hidpiHeightField.stringValue = "\(height)"
        }

        let logicalWidth = max(1, (Int(hidpiWidthField.intValue) / 2))
        let logicalHeight = max(1, (Int(hidpiHeightField.intValue) / 2))
        hidpiInfoLabel.stringValue = "Installs a macOS Display Override or creates a virtual HiDPI mirror. For Samsung 57-inch Neo G9, try target framebuffer 7680x2160 for a 3840x1080 HiDPI baseline if the cable/adapter can carry it."
        if logicalWidth > 0 && logicalHeight > 0 {
            hidpiInfoLabel.stringValue += " Current target looks like \(logicalWidth)x\(logicalHeight) HiDPI."
        }
    }

    private func selectMode(withKey key: String) {
        if let item = modePopup.itemArray.first(where: { $0.representedObject as? String == key }) {
            modePopup.select(item)
        }
    }

    private func selectedPreset() -> DisplayPreset? {
        guard let selectedID = presetPopup.selectedItem?.representedObject as? String,
              let uuid = UUID(uuidString: selectedID) else {
            return nil
        }
        return presetManager.presets.first { $0.id == uuid }
    }

    @objc private func selectedDisplayChanged() {
        selectedDisplayID = (displayPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value
        populateModePopup()
        populatePresetPopup()
        updateControlState()
    }

    @objc private func modePopupChanged() {
        guard let selectedModeKey = modePopup.selectedItem?.representedObject as? String,
              let display = selectedDisplay,
              let mode = display.modes.first(where: { modeKey($0) == selectedModeKey }) else {
            return
        }
        modeDetailsLabel.stringValue = modeTitle(mode)
    }

    @objc private func installHiDPIOverrideClicked() {
        guard let display = selectedDisplay,
              let target = validatedHiDPITarget() else {
            return
        }

        do {
            statusLabel.stringValue = "Waiting for administrator authorization..."
            _ = try hidpiOverrideManager.installOverride(display: display, targetWidth: target.width, targetHeight: target.height)
            statusLabel.stringValue = "HiDPI override installed. Restart macOS."
        } catch {
            statusLabel.stringValue = "Install failed: \(error.localizedDescription)"
        }
    }

    @objc private func removeHiDPIOverrideClicked() {
        guard let display = selectedDisplay else {
            return
        }

        do {
            try hidpiOverrideManager.uninstallOverride(display: display)
            statusLabel.stringValue = "HiDPI override removed. Restart macOS."
        } catch {
            statusLabel.stringValue = "Remove failed: \(error.localizedDescription)"
        }
    }

    @objc private func exportHiDPIKitClicked() {
        guard let display = selectedDisplay else {
            return
        }

        guard let target = validatedHiDPITarget() else {
            return
        }

        do {
            let kitURL = try hidpiOverrideManager.createOverrideKit(display: display, targetWidth: target.width, targetHeight: target.height)
            NSWorkspace.shared.activateFileViewerSelecting([kitURL])
            statusLabel.stringValue = "HiDPI override kit exported"
        } catch {
            statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
        }
    }

    private func validatedHiDPITarget() -> (width: Int, height: Int)? {
        let width = Int(hidpiWidthField.intValue)
        let height = Int(hidpiHeightField.intValue)
        guard width >= 640, height >= 360 else {
            statusLabel.stringValue = "Enter a valid target framebuffer size"
            return nil
        }
        return (width, height)
    }

    @objc private func createVirtualHiDPIMirrorClicked() {
        guard let display = selectedDisplay,
              let target = validatedHiDPITarget() else {
            return
        }

        do {
            statusLabel.stringValue = "Creating virtual HiDPI mirror..."
            let virtualDisplayID = try virtualDisplayManager.createHiDPIMirror(
                for: display,
                targetWidth: target.width,
                targetHeight: target.height,
                displayManager: displayManager
            )
            statusLabel.stringValue = "Virtual HiDPI mirror active as display \(virtualDisplayID)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.refresh()
                self?.onStateChange()
            }
        } catch {
            statusLabel.stringValue = "Virtual mirror failed: \(error.localizedDescription)"
        }
    }

    @objc private func removeVirtualMirrorClicked() {
        if let result = virtualDisplayManager.destroy(displayManager: displayManager), result != .success {
            statusLabel.stringValue = "Stopped virtual display, but unmirror returned \(result.rawValue)"
        } else {
            statusLabel.stringValue = "Virtual mirror removed"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refresh()
            self?.onStateChange()
        }
    }

    @objc private func exportReportClicked() {
        do {
            let reportURL = try hidpiOverrideManager.exportReport(displays: displays)
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
            statusLabel.stringValue = "Display report exported"
        } catch {
            statusLabel.stringValue = "Could not export report: \(error.localizedDescription)"
        }
    }

    @objc private func openHiDPIFolderClicked() {
        let folderURL = hidpiOverrideManager.baseDirectory
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    @objc private func applyModeClicked() {
        guard let selectedModeKey = modePopup.selectedItem?.representedObject as? String,
              let display = selectedDisplay,
              let mode = display.modes.first(where: { modeKey($0) == selectedModeKey }) else {
            return
        }

        let result = displayManager.setMode(mode, for: display.id)
        handleResult(result, success: "Applied \(modeTitle(mode))")
    }

    @objc private func dimmingChanged() {
        guard let display = selectedDisplay else {
            return
        }

        dimmerController.setLevel(dimmingSlider.doubleValue, for: display.id)
        dimmingValueLabel.stringValue = "\(Int(dimmingSlider.doubleValue * 100))%"
        onStateChange()
    }

    @objc private func mirrorToMainClicked() {
        guard let display = selectedDisplay else {
            return
        }
        handleResult(displayManager.mirror(displayID: display.id, to: CGMainDisplayID()), success: "Mirroring enabled")
    }

    @objc private func stopMirroringClicked() {
        guard let display = selectedDisplay else {
            return
        }
        handleResult(displayManager.stopMirroring(displayID: display.id), success: "Mirroring disabled")
    }

    @objc private func moveRightOfMainClicked() {
        guard let display = selectedDisplay else {
            return
        }
        handleResult(displayManager.move(displayID: display.id, rightOf: CGMainDisplayID()), success: "Display moved")
    }

    @objc private func savePresetClicked() {
        guard let display = selectedDisplay else {
            return
        }

        let trimmedName = presetNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName: String
        if let mode = display.currentMode {
            fallbackName = "\(mode.width)x\(mode.height) \(Int(dimmerController.level(for: display.id) * 100))%"
        } else {
            fallbackName = "Preset \(presetManager.presets.count + 1)"
        }

        let preset = DisplayPreset(
            id: UUID(),
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            displayKey: display.persistentKey,
            modeKey: display.currentMode.map(modeKey),
            dimmingLevel: dimmerController.level(for: display.id)
        )
        presetManager.save(preset)
        presetNameField.stringValue = ""
        populatePresetPopup()
        updateControlState()
        statusLabel.stringValue = "Preset saved"
    }

    @objc private func applyPresetClicked() {
        guard let preset = selectedPreset(),
              let display = selectedDisplay else {
            return
        }

        dimmerController.setLevel(preset.dimmingLevel, for: display.id)
        if let savedModeKey = preset.modeKey,
           let mode = display.modes.first(where: { modeKey($0) == savedModeKey }) {
            let result = displayManager.setMode(mode, for: display.id)
            handleResult(result, success: "Preset applied")
        } else {
            statusLabel.stringValue = "Preset applied"
            refresh()
            onStateChange()
        }
    }

    @objc private func deletePresetClicked() {
        guard let preset = selectedPreset() else {
            return
        }
        presetManager.delete(id: preset.id)
        populatePresetPopup()
        updateControlState()
        statusLabel.stringValue = "Preset deleted"
    }

    private func handleResult(_ result: CGError, success: String) {
        if result == .success {
            statusLabel.stringValue = success
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refresh()
                self?.onStateChange()
            }
        } else {
            statusLabel.stringValue = "CoreGraphics returned \(result.rawValue)"
        }
    }

    func tearDownVirtualDisplay() {
        _ = virtualDisplayManager.destroy(displayManager: displayManager)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let displayManager = DisplayManager()
    private let dimmerController = DimmerController()
    private lazy var controlPanel = ControlPanelWindowController(
        displayManager: displayManager,
        dimmerController: dimmerController
    ) { [weak self] in
        self?.rebuildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        rebuildMenu()
        showControlPanel()

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, pointer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlPanel.tearDownVirtualDisplay()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, pointer)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel()
        return true
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MacDisplay")
            button.image?.isTemplate = true
            button.toolTip = "MacDisplay"
        }
    }

    @objc private func rebuildMenu() {
        let displays = displayManager.activeDisplays()
        let activeIDs = Set(displays.map(\.id))
        dimmerController.refreshWindows(activeDisplayIDs: activeIDs)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "MacDisplay", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if displays.isEmpty {
            let emptyItem = NSMenuItem(title: "No active displays found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for display in displays {
                addDisplay(display, to: menu)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Control Panel", action: #selector(showControlPanel), keyEquivalent: "o", target: self))
        menu.addItem(NSMenuItem(title: "Refresh Displays", action: #selector(rebuildMenu), keyEquivalent: "r", target: self))
        menu.addItem(NSMenuItem(title: "Quit MacDisplay", action: #selector(quit), keyEquivalent: "q", target: self))

        statusItem.menu = menu
    }

    private func addDisplay(_ display: DisplaySnapshot, to menu: NSMenu) {
        let displayTitle = display.name + (display.isMain ? " - Main" : "")
        let heading = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        let details = NSMenuItem(title: displayDetails(display), action: nil, keyEquivalent: "")
        details.isEnabled = false
        details.indentationLevel = 1
        menu.addItem(details)

        let dimmerItem = NSMenuItem()
        dimmerItem.view = dimmerView(for: display)
        menu.addItem(dimmerItem)

        let modesItem = NSMenuItem(title: "Resolution and Refresh Rate", action: nil, keyEquivalent: "")
        modesItem.indentationLevel = 1
        let modesMenu = NSMenu()

        if display.modes.isEmpty {
            let emptyModes = NSMenuItem(title: "No switchable modes found", action: nil, keyEquivalent: "")
            emptyModes.isEnabled = false
            modesMenu.addItem(emptyModes)
        } else {
            for mode in display.modes.prefix(80) {
                let item = NSMenuItem(
                    title: modeTitle(mode),
                    action: #selector(setDisplayMode(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ModeSelection(displayID: display.id, mode: mode)
                if let currentMode = display.currentMode, modeKey(currentMode) == modeKey(mode) {
                    item.state = .on
                }
                modesMenu.addItem(item)
            }
        }

        modesItem.submenu = modesMenu
        menu.addItem(modesItem)
        menu.addItem(.separator())
    }

    private func dimmerView(for display: DisplaySnapshot) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))

        let label = NSTextField(labelWithString: "Software dimming")
        label.frame = NSRect(x: 18, y: 22, width: 150, height: 16)
        label.font = .systemFont(ofSize: 12)
        view.addSubview(label)

        let valueLabel = NSTextField(labelWithString: "\(Int(dimmerController.level(for: display.id) * 100))%")
        valueLabel.frame = NSRect(x: 220, y: 22, width: 44, height: 16)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.tag = 42
        view.addSubview(valueLabel)

        let slider = DisplaySlider(value: dimmerController.level(for: display.id), minValue: 0, maxValue: 0.9, target: self, action: #selector(dimmerChanged(_:)))
        slider.displayID = display.id
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 2, width: 248, height: 22)
        view.addSubview(slider)

        return view
    }

    private func displayDetails(_ display: DisplaySnapshot) -> String {
        let builtInText = display.isBuiltIn ? "Built-in" : "External"
        guard let mode = display.currentMode else {
            return "\(builtInText) - \(Int(display.bounds.width))x\(Int(display.bounds.height))"
        }

        let refresh = mode.refreshRate > 0 ? String(format: " @ %.0fHz", mode.refreshRate) : ""
        let scale = isHiDPIMode(mode) ? " HiDPI" : ""
        return "\(builtInText) - \(mode.width)x\(mode.height)\(refresh)\(scale), physical \(mode.pixelWidth)x\(mode.pixelHeight)"
    }

    @objc private func dimmerChanged(_ sender: DisplaySlider) {
        dimmerController.setLevel(sender.doubleValue, for: sender.displayID)
        if let valueLabel = sender.superview?.viewWithTag(42) as? NSTextField {
            valueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
        }
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModeSelection else {
            return
        }

        let result = displayManager.setMode(selection.mode, for: selection.displayID)
        if result != .success {
            presentError("Could not change display mode. CoreGraphics returned \(result.rawValue).")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showControlPanel() {
        controlPanel.showWindow(nil)
    }

    fileprivate func handleDisplayChange() {
        controlPanel.refresh()
        rebuildMenu()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacDisplay"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else {
        return
    }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.handleDisplayChange()
    }
}

private func modeTitle(_ mode: CGDisplayMode) -> String {
    let refresh = mode.refreshRate > 0 ? String(format: " @ %.0fHz", mode.refreshRate) : ""
    let hidpi = isHiDPIMode(mode) ? " HiDPI" : ""
    let physical = isHiDPIMode(mode) ? " (\(mode.pixelWidth)x\(mode.pixelHeight) px)" : ""
    return "\(mode.width)x\(mode.height)\(refresh)\(hidpi)\(physical)"
}

private func modeKey(_ mode: CGDisplayMode) -> String {
    let refresh = Int((mode.refreshRate * 100).rounded())
    return "\(mode.width)x\(mode.height)-\(mode.pixelWidth)x\(mode.pixelHeight)-\(refresh)-\(mode.ioFlags)"
}

private func isHiDPIMode(_ mode: CGDisplayMode) -> Bool {
    mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func screen(with displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
