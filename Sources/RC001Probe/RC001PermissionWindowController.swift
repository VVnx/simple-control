import AppKit
import ApplicationServices
import CoreBluetooth
import RC001Core
import RC001HIDBridgeProtocol

struct RC001PermissionSnapshot {
    let hidHelperInstalled: Bool
    let accessibilityGranted: Bool
    let bluetoothAuthorization: CBManagerAuthorization
    let virtualMicrophoneInstalled: Bool

    var bluetoothGranted: Bool {
        bluetoothAuthorization == .allowedAlways
    }

    var requiredPermissionsGranted: Bool {
        hidHelperInstalled && accessibilityGranted && bluetoothGranted && virtualMicrophoneInstalled
    }
}

enum RC001PermissionChecker {
    static func snapshot() -> RC001PermissionSnapshot {
        RC001PermissionSnapshot(
            hidHelperInstalled: FileManager.default.isExecutableFile(
                atPath: RC001HIDBridgePaths.helperExecutable
            ),
            accessibilityGranted: AXIsProcessTrusted(),
            bluetoothAuthorization: CBCentralManager.authorization,
            virtualMicrophoneInstalled: FileManager.default.fileExists(
                atPath: "/Library/Audio/Plug-Ins/HAL/RC001 Remote Microphone.driver"
            )
        )
    }
}

final class RC001PermissionWindowController: NSObject, NSWindowDelegate {
    private let hidStatusProvider: () -> RC001HIDAccessStatus
    private let retryHIDAccess: () -> Void

    private var window: NSWindow?
    private var refreshTimer: Timer?
    private let safetyBanner = NSTextField(wrappingLabelWithString: "正在检查遥控器接管状态…")
    private let inputStep = RC001PermissionStepView(
        number: 1,
        title: "按键接管服务",
        detail: "在“输入监控”中添加并开启 RC001-Viber HID Helper；它只接管这只遥控器。",
        buttonTitle: "打开输入监控"
    )
    private let accessibilityStep = RC001PermissionStepView(
        number: 2,
        title: "辅助功能",
        detail: "生成右 Control 按键事件，用于豆包输入法的按住说话。",
        buttonTitle: "打开辅助功能"
    )
    private let bluetoothStep = RC001PermissionStepView(
        number: 3,
        title: "蓝牙",
        detail: "连接小米遥控器并接收按键和麦克风音频。",
        buttonTitle: "打开蓝牙权限"
    )
    private let microphoneStep = RC001PermissionStepView(
        number: 4,
        title: "虚拟麦克风",
        detail: "确认 RC001 Remote Microphone 驱动已安装并可作为声音输入。",
        buttonTitle: "打开声音输入"
    )
    private let refreshButton = NSButton(title: "重新检查并接管遥控器", target: nil, action: nil)

    init(
        hidStatusProvider: @escaping () -> RC001HIDAccessStatus,
        retryHIDAccess: @escaping () -> Void
    ) {
        self.hidStatusProvider = hidStatusProvider
        self.retryHIDAccess = retryHIDAccess
        super.init()

        inputStep.button.target = self
        inputStep.button.action = #selector(openInputMonitoring)
        accessibilityStep.button.target = self
        accessibilityStep.button.action = #selector(openAccessibility)
        bluetoothStep.button.target = self
        bluetoothStep.button.action = #selector(openBluetooth)
        microphoneStep.button.target = self
        microphoneStep.button.action = #selector(openSoundInput)
        refreshButton.target = self
        refreshButton.action = #selector(refreshAndRetry)
        refreshButton.keyEquivalent = "\r"
        refreshButton.bezelStyle = .rounded
    }

    func show() {
        let window = window ?? makeWindow()
        refresh()
        startRefreshTimer()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showIfNeeded() {
        let snapshot = RC001PermissionChecker.snapshot()
        if !snapshot.requiredPermissionsGranted || !hidStatusProvider().helperIsOperational {
            show()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RC001-Viber 权限检查"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = label("权限检查与授权", size: 24, weight: .semibold)
        let subtitle = label("按顺序完成下面 4 步，再让 RC001-Viber 接管遥控器。", size: 13, color: .secondaryLabelColor)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5

        let header = NSStackView(views: [iconView, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        safetyBanner.font = .systemFont(ofSize: 13, weight: .medium)
        safetyBanner.maximumNumberOfLines = 2
        safetyBanner.drawsBackground = true
        safetyBanner.isBezeled = false
        safetyBanner.isEditable = false
        safetyBanner.isSelectable = false
        safetyBanner.wantsLayer = true
        safetyBanner.layer?.cornerRadius = 9
        safetyBanner.layer?.masksToBounds = true
        safetyBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

        let hint = NSTextField(wrappingLabelWithString:
            "第 1 步：点“打开输入监控”→ 点“+”→ 选择 /Applications/RC001-Viber HID Helper.app → 开启开关。授权后返回本页，服务会自动重试；无需给 RC001-Viber 主应用输入监控权限。"
        )
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3

        let footer = NSStackView(views: [hint, refreshButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        refreshButton.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let versionLabel = label(
            RC001AppVersion().displayText,
            size: 11.5,
            color: .tertiaryLabelColor
        )
        versionLabel.alignment = .right

        let stack = NSStackView(views: [
            header,
            safetyBanner,
            inputStep,
            accessibilityStep,
            bluetoothStep,
            microphoneStep,
            footer,
            versionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -22),
            safetyBanner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessibilityStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bluetoothStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            microphoneStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        self.window = window
        return window
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let snapshot = RC001PermissionChecker.snapshot()
        let hidStatus = hidStatusProvider()
        inputStep.update(
            ready: hidStatus.helperIsOperational,
            status: helperStatusText(hidStatus)
        )
        accessibilityStep.update(ready: snapshot.accessibilityGranted, status: snapshot.accessibilityGranted ? "已授权" : "未授权")
        bluetoothStep.update(
            ready: snapshot.bluetoothGranted,
            status: bluetoothStatus(snapshot.bluetoothAuthorization)
        )
        microphoneStep.update(
            ready: snapshot.virtualMicrophoneInstalled,
            status: snapshot.virtualMicrophoneInstalled ? "驱动已安装" : "驱动未安装"
        )

        switch hidStatus {
        case .ready where snapshot.requiredPermissionsGranted:
            updateSafetyBanner(
                "✓ 遥控器按键已被安全接管，可以测试语音键和开关键。",
                color: .systemGreen
            )
        case .waitingForRemote where snapshot.requiredPermissionsGranted:
            updateSafetyBanner(
                "✓ 按键接管服务已就绪，正在等待遥控器连接。连接后再测试开关键。",
                color: .systemBlue
            )
        case .notInstalled:
            updateSafetyBanner(
                "⚠ HID Helper 未安装，请重新安装最新版 RC001-Viber。",
                color: .systemRed
            )
        case .inputMonitoringRequired:
            updateSafetyBanner(
                "⚠ 暂时不要按开关键：请先在输入监控中授权 RC001-Viber HID Helper。",
                color: .systemRed
            )
        case .occupiedByAnotherApp:
            updateSafetyBanner(
                "⚠ 暂时不要按开关键：遥控器正被 Karabiner 或其他应用占用。",
                color: .systemOrange
            )
        case .failed(let code):
            updateSafetyBanner(
                "⚠ 暂时不要按开关键：遥控器接管失败（\(code)）。",
                color: .systemRed
            )
        default:
            updateSafetyBanner(
                "⚠ 暂时不要按开关键：按键尚未被接管，macOS 仍可能显示关机菜单。",
                color: .systemOrange
            )
        }
    }

    private func helperStatusText(_ status: RC001HIDAccessStatus) -> String {
        switch status {
        case .notInstalled: "未安装"
        case .starting: "正在启动"
        case .inputMonitoringRequired: "未授权"
        case .waitingForRemote: "服务已就绪"
        case .ready: "已接管"
        case .occupiedByAnotherApp: "被占用"
        case .failed: "服务异常"
        }
    }

    private func updateSafetyBanner(_ text: String, color: NSColor) {
        safetyBanner.stringValue = "   \(text)"
        safetyBanner.textColor = color
        safetyBanner.backgroundColor = color.withAlphaComponent(0.10)
    }

    private func bluetoothStatus(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: "已授权"
        case .notDetermined: "等待授权"
        case .denied: "未授权"
        case .restricted: "受系统限制"
        @unknown default: "未知状态"
        }
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    @objc private func openInputMonitoring() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc private func openAccessibility() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openBluetooth() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    @objc private func openSoundInput() {
        openSystemSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    @objc private func refreshAndRetry() {
        retryHIDAccess()
        refreshButton.title = "正在重新检查…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshButton.title = "重新检查并接管遥控器"
            self?.refresh()
        }
    }

    private func openSystemSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class RC001PermissionStepView: NSView {
    let button: NSButton
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "正在检查")

    init(number: Int, title: String, detail: String, buttonTitle: String) {
        button = NSButton(title: buttonTitle, target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.56).cgColor
        heightAnchor.constraint(equalToConstant: 92).isActive = true

        let numberLabel = NSTextField(labelWithString: String(number))
        numberLabel.alignment = .center
        numberLabel.font = .systemFont(ofSize: 13, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.wantsLayer = true
        numberLabel.layer?.cornerRadius = 15
        numberLabel.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        numberLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        numberLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.widthAnchor.constraint(equalToConstant: 19).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 19).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let statusStack = NSStackView(views: [statusIcon, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 6

        button.bezelStyle = .rounded
        button.widthAnchor.constraint(equalToConstant: 126).isActive = true

        let row = NSStackView(views: [numberLabel, textStack, statusStack, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(ready: Bool, status: String) {
        let color: NSColor = ready ? .systemGreen : .systemOrange
        statusIcon.image = NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            accessibilityDescription: status
        )
        statusIcon.contentTintColor = color
        statusLabel.stringValue = status
        statusLabel.textColor = color
    }
}
