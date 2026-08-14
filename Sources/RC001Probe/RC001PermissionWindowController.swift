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
    private let statusBanner = RC001PermissionStatusBanner()
    private let progressBadge = RC001PermissionProgressBadge()
    private let permissionGuide = RC001PermissionGuideView(
        title: "正在检查授权状态",
        detail: "请稍候，页面会自动显示下一步操作。"
    )
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
    private let refreshButton = NSButton(title: "重新检测", target: nil, action: nil)

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
        refreshButton.controlSize = .large
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "重新检测"
        )
        refreshButton.imagePosition = .imageLeading
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 618),
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
        iconView.widthAnchor.constraint(equalToConstant: 54).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let title = label("权限检查与授权", size: 25, weight: .semibold)
        let subtitle = label("完成 4 项系统设置，确保按键与语音功能正常工作。", size: 12.5, color: .secondaryLabelColor)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [iconView, heading, headerSpacer, progressBadge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let sectionTitle = label("授权项目", size: 13, weight: .semibold)
        let sectionSubtitle = label("状态会自动更新", size: 11.5, color: .tertiaryLabelColor)
        let sectionSpacer = NSView()
        sectionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sectionHeader = NSStackView(views: [sectionTitle, sectionSpacer, sectionSubtitle])
        sectionHeader.orientation = .horizontal
        sectionHeader.alignment = .centerY

        let versionLabel = label(
            RC001AppVersion().displayText,
            size: 11.5,
            color: .tertiaryLabelColor
        )
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [versionLabel, footerSpacer, refreshButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        refreshButton.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let stack = NSStackView(views: [
            header,
            statusBanner,
            sectionHeader,
            inputStep,
            accessibilityStep,
            bluetoothStep,
            microphoneStep,
            permissionGuide,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: header)
        stack.setCustomSpacing(18, after: statusBanner)
        stack.setCustomSpacing(8, after: sectionHeader)
        stack.setCustomSpacing(12, after: microphoneStep)
        stack.setCustomSpacing(12, after: permissionGuide)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBanner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sectionHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessibilityStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bluetoothStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            microphoneStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionGuide.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        let completedCount = [
            hidStatus.helperIsOperational,
            snapshot.accessibilityGranted,
            snapshot.bluetoothGranted,
            snapshot.virtualMicrophoneInstalled,
        ].filter { $0 }.count
        progressBadge.update(completed: completedCount, total: 4)
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
        updatePermissionGuide(snapshot: snapshot, hidStatus: hidStatus)

        switch hidStatus {
        case .ready where snapshot.requiredPermissionsGranted:
            updateStatusBanner(
                title: "遥控器已安全接管",
                detail: "所有授权均已完成，现在可以测试语音键和开关键。",
                color: .systemGreen,
                symbol: "checkmark.shield.fill"
            )
        case .waitingForRemote where snapshot.requiredPermissionsGranted:
            updateStatusBanner(
                title: "授权完成，正在等待遥控器",
                detail: "接管服务已经就绪，遥控器连接后即可开始使用。",
                color: .systemBlue,
                symbol: "antenna.radiowaves.left.and.right"
            )
        case .ready, .waitingForRemote:
            let remainingCount = 4 - completedCount
            updateStatusBanner(
                title: "还有 \(remainingCount) 项授权待完成",
                detail: "请完成标记为橙色的项目；授权后状态会自动更新。",
                color: .systemOrange,
                symbol: "exclamationmark.triangle.fill"
            )
        case .notInstalled:
            updateStatusBanner(
                title: "按键接管服务未安装",
                detail: "请重新安装最新版 RC001-Viber 后再试。",
                color: .systemRed,
                symbol: "xmark.octagon.fill"
            )
        case .inputMonitoringRequired:
            updateStatusBanner(
                title: "需要开启输入监控",
                detail: "完成第 1 项前请暂时不要按开关键，避免触发系统关机菜单。",
                color: .systemOrange,
                symbol: "exclamationmark.triangle.fill"
            )
        case .occupiedByAnotherApp:
            updateStatusBanner(
                title: "遥控器正在被其他应用占用",
                detail: "请先退出 Karabiner 或其他按键接管应用，然后重新检测。",
                color: .systemOrange,
                symbol: "exclamationmark.triangle.fill"
            )
        case .failed(let code):
            updateStatusBanner(
                title: "遥控器接管失败",
                detail: "错误代码：\(code)。请重新检测或重新安装应用。",
                color: .systemRed,
                symbol: "xmark.octagon.fill"
            )
        default:
            updateStatusBanner(
                title: "正在检查按键接管状态",
                detail: "完成授权前请暂时不要按开关键，macOS 仍可能显示关机菜单。",
                color: .systemOrange,
                symbol: "exclamationmark.triangle.fill"
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

    private func updateStatusBanner(
        title: String,
        detail: String,
        color: NSColor,
        symbol: String
    ) {
        statusBanner.update(title: title, detail: detail, color: color, symbol: symbol)
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

    private func updatePermissionGuide(
        snapshot: RC001PermissionSnapshot,
        hidStatus: RC001HIDAccessStatus
    ) {
        if !hidStatus.helperIsOperational {
            permissionGuide.update(
                title: "完成输入监控授权",
                detail: "点击“打开输入监控”，用“+”添加 RC001-Viber HID Helper.app 并打开开关。"
            )
        } else if !snapshot.accessibilityGranted {
            permissionGuide.update(
                title: "完成辅助功能授权",
                detail: "点击“打开辅助功能”，在应用列表中为 RC001-Viber 打开开关。"
            )
        } else if !snapshot.bluetoothGranted {
            permissionGuide.update(
                title: "完成蓝牙授权",
                detail: "点击“打开蓝牙权限”，允许 RC001-Viber 连接小米遥控器。"
            )
        } else if !snapshot.virtualMicrophoneInstalled {
            permissionGuide.update(
                title: "检查声音输入",
                detail: "打开声音输入，确认 RC001 Remote Microphone 已出现在设备列表中。"
            )
        } else {
            permissionGuide.update(
                title: "授权设置已完成",
                detail: "后续可从菜单栏的遥控器图标再次打开本页面。"
            )
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
        refreshButton.title = "正在检测…"
        refreshButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshButton.title = "重新检测"
            self?.refreshButton.isEnabled = true
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
    private let actionTitle: String
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "正在检查")
    private let statusBackground = NSView()

    init(number: Int, title: String, detail: String, buttonTitle: String) {
        actionTitle = buttonTitle
        button = NSButton(title: buttonTitle, target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
        heightAnchor.constraint(equalToConstant: 70).isActive = true

        let numberLabel = NSTextField(labelWithString: String(number))
        numberLabel.alignment = .center
        numberLabel.font = .systemFont(ofSize: 12.5, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.wantsLayer = true
        numberLabel.layer?.cornerRadius = 14
        numberLabel.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        numberLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        numberLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.25)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        let statusStack = NSStackView(views: [statusIcon, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusBackground.wantsLayer = true
        statusBackground.layer?.cornerRadius = 14
        statusBackground.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusBackground.widthAnchor.constraint(equalToConstant: 94),
            statusBackground.heightAnchor.constraint(equalToConstant: 28),
            statusStack.centerXAnchor.constraint(equalTo: statusBackground.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
        ])

        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [numberLabel, textStack, rowSpacer, statusBackground, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(ready: Bool, status: String) {
        let color: NSColor = ready ? .systemGreen : .systemOrange
        statusIcon.image = NSImage(
            systemSymbolName: ready ? "checkmark" : "exclamationmark",
            accessibilityDescription: status
        )
        statusIcon.contentTintColor = color
        statusLabel.stringValue = status
        statusLabel.textColor = color
        statusBackground.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        layer?.borderColor = (ready ? NSColor.separatorColor : color.withAlphaComponent(0.38)).cgColor
        layer?.backgroundColor = (
            ready
                ? NSColor.controlBackgroundColor.withAlphaComponent(0.42)
                : color.withAlphaComponent(0.035)
        ).cgColor
        button.title = ready ? "查看设置" : actionTitle
        button.contentTintColor = ready ? .secondaryLabelColor : .controlAccentColor
    }
}

private final class RC001PermissionStatusBanner: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "正在检查权限")
    private let detailLabel = NSTextField(labelWithString: "请稍候…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        heightAnchor.constraint(equalToConstant: 58).isActive = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [iconView, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, detail: String, color: NSColor, symbol: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.contentTintColor = color
        titleLabel.stringValue = title
        titleLabel.textColor = color
        detailLabel.stringValue = detail
        layer?.backgroundColor = color.withAlphaComponent(0.085).cgColor
        layer?.borderColor = color.withAlphaComponent(0.20).cgColor
        toolTip = "\(title)：\(detail)"
    }
}

private final class RC001PermissionProgressBadge: NSView {
    private let textLabel = NSTextField(labelWithString: "0 / 4 已完成")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 15
        widthAnchor.constraint(equalToConstant: 104).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        textLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        textLabel.alignment = .center
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(completed: Int, total: Int) {
        let isComplete = completed == total
        let color: NSColor = isComplete ? .systemGreen : .controlAccentColor
        textLabel.stringValue = "\(completed) / \(total) 已完成"
        textLabel.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
    }
}

private final class RC001PermissionGuideView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String, detail: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.48).cgColor
        heightAnchor.constraint(equalToConstant: 54).isActive = true

        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [iconView, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(title: title, detail: detail)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, detail: String) {
        iconView.image = NSImage(
            systemSymbolName: "info.circle.fill",
            accessibilityDescription: title
        )
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        toolTip = "\(title)：\(detail)"
    }
}
