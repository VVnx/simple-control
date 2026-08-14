import AppKit
import RC001Core

final class RC001StatusMenu: NSObject {
    private let statusItem: NSStatusItem
    private let remoteItem = NSMenuItem(title: "遥控器：正在连接…", action: nil, keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "麦克风：等待遥控器", action: nil, keyEquivalent: "")
    private var settingsWindow: NSWindow?
    private var hidAccessStatus: RC001HIDAccessStatus = .starting
    var retryHIDAccessHandler: (() -> Void)?
    private lazy var permissionWindowController = RC001PermissionWindowController(
        hidStatusProvider: { [weak self] in self?.hidAccessStatus ?? .starting },
        retryHIDAccess: { [weak self] in self?.retryHIDAccessHandler?() }
    )

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let driverInstalled = FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/RC001 Remote Microphone.driver"
        )
        microphoneItem.title = driverInstalled ? "麦克风：就绪" : "麦克风：驱动未安装"

        if let button = statusItem.button {
            let remoteIcon = NSImage(
                systemSymbolName: "appletvremote.gen4.fill",
                accessibilityDescription: "RC001-Viber"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            )
            remoteIcon?.isTemplate = true
            button.image = remoteIcon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "RC001-Viber"
        }

        remoteItem.isEnabled = false
        microphoneItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(remoteItem)
        menu.addItem(microphoneItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "权限检查与授权…", action: #selector(showPermissions), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "打开映射与状态…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "打开录音目录", action: #selector(openRecordings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 RC001-Viber", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    func setRemoteStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.remoteItem.title = "遥控器：\(status)"
        }
    }

    func setMicrophoneStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.microphoneItem.title = "麦克风：\(status)"
        }
    }

    func setHIDAccessStatus(_ status: RC001HIDAccessStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.hidAccessStatus = status
        }
    }

    func showPermissionsIfNeeded() {
        permissionWindowController.showIfNeeded()
    }

    @objc func showPermissions() {
        permissionWindowController.show()
    }

    @objc func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RC001-Viber"
        window.center()
        window.isReleasedWhenClosed = false

        let title = label("RC001-Viber", size: 24, weight: .semibold)
        let subtitle = label("小米蓝牙语音遥控器 → macOS", size: 13, color: .secondaryLabelColor)
        let mappingTitle = label("当前映射", size: 15, weight: .semibold)
        let voiceMapping = mappingRow(source: "语音键（F5）", destination: "右 Control（按住）")
        let powerMapping = mappingRow(source: "开关键", destination: "打开 Codex")
        let microphone = mappingRow(source: "遥控器麦克风", destination: "RC001 Remote Microphone")
        let permissionNote = label(
            "首次使用需要给 HID Helper 输入监控权限、给 RC001-Viber 辅助功能与蓝牙权限；虚拟麦克风驱动安装后会出现在所有录音应用中。",
            size: 12,
            color: .secondaryLabelColor
        )
        permissionNote.maximumNumberOfLines = 3
        let permissionButton = NSButton(title: "检查权限与授权…", target: self, action: #selector(showPermissions))
        permissionButton.bezelStyle = .rounded
        let versionLabel = label(
            RC001AppVersion().displayText,
            size: 11.5,
            color: .tertiaryLabelColor
        )
        versionLabel.alignment = .right
        versionLabel.widthAnchor.constraint(equalToConstant: 464).isActive = true

        let stack = NSStackView(views: [
            title,
            subtitle,
            separator(),
            mappingTitle,
            voiceMapping,
            powerMapping,
            microphone,
            separator(),
            permissionNote,
            permissionButton,
            versionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
        ])

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func mappingRow(source: String, destination: String) -> NSView {
        let sourceLabel = label(source, size: 13, weight: .medium)
        sourceLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let arrow = label("→", size: 13, color: .tertiaryLabelColor)
        let destinationLabel = label(destination, size: 13)
        let row = NSStackView(views: [sourceLabel, arrow, destinationLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
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

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return box
    }

    @objc private func openRecordings() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RC001MacBridge", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
