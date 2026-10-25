import Cocoa

/// 调试用的截图与焦点导出。正常运行路径不会进这里。
enum Snapshots {

    /// 主窗口截图。
    /// 截图时必须临时变成普通应用并抢到 key window，
    /// 否则 NSSwitch 会按「窗口非活跃」渲染成灰色，看起来像「已关闭」。
    static func window(to path: String) {
        NSApp.setActivationPolicy(.regular)
        let settings = SettingsWindowController.shared
        settings.show()

        guard let win = settings.contentViewForSnapshot?.window else { return }
        win.makeKeyAndOrderFront(nil)
        // 从终端 / LaunchServices 拉起时第一次 activate 常被系统忽略，多试几次
        for _ in 0..<12 {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            win.makeKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if NSApp.isActive && win.isKeyWindow { break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        log("snapshot: isActive=\(NSApp.isActive) isKey=\(win.isKeyWindow) policy=\(NSApp.activationPolicy().rawValue)")

        guard let view = settings.contentViewForSnapshot else { return }
        writePNG(view, to: path)
    }

    /// 菜单栏小面板截图
    static func panel(to path: String, host: AppActions, demoBundle: String?) {
        let panel = QuickPanelController()
        panel.app = host
        // 截图时固定展示某个应用，避免抓到的正好是当前前台的小工具
        if let b = demoBundle { host.lastExternalBundle = b }
        // 前台是本进程，读不到目标应用的焦点元素，
        // 用 AUTOSWITCH_DEMO_SPOT 伪造一个指纹来预览「此处」那一行
        if let raw = ProcessInfo.processInfo.environment["AUTOSWITCH_DEMO_SPOT"], !raw.isEmpty {
            var fp = FocusFingerprint()
            fp.role = "AXTextField"
            fp.domClasses = raw.split(separator: ",").map(String.init)
            panel.demoFingerprint = fp
        }

        let view = panel.view
        panel.refresh()
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        writePNG(view, to: path)
    }

    /// 把焦点元素的 AX 特征写成文本，用来配细分规则；写完退出应用
    static func focusDump(to path: String, bundleID: String?, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var out = "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
            out += "time: \(Date())\n"

            let targets: [NSRunningApplication]
            if let b = bundleID, !b.isEmpty {
                targets = NSRunningApplication.runningApplications(withBundleIdentifier: b)
            } else if let f = NSWorkspace.shared.frontmostApplication {
                targets = [f]
            } else {
                targets = []
            }

            if targets.isEmpty {
                out += "\n未找到目标应用（可能没在运行）\n"
            }

            // 用和运行期完全相同的读取路径（含重试），
            // 这样「诊断能读到、面板读不到」这类偏差不会出现
            var remaining = targets.count
            guard remaining > 0 else {
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
                log("ax dump -> \(path)")
                NSApp.terminate(nil)
                return
            }

            for app in targets {
                let b = app.bundleIdentifier ?? "?"
                let pid = app.processIdentifier
                let result = focusedElementResult(pid: pid)
                out += "\n=== \(b) pid=\(pid) active=\(app.isActive) ===\n"
                out += "  focusedUIElement: \(axErrorName(result.error))\n"
                if let el = result.element, let fp = fingerprintOfElement(el) {
                    out += "  \(fp.summary)\n"
                    out += "  ancestorTitles: \(fp.ancestorTitles)\n"
                    out += "  ancestorIDs: \(fp.ancestorIDs)\n"
                } else {
                    out += "  <拿不到焦点元素>\n"
                }

                // 再跑一遍重试链，验证「等一下就能读到」这个假设
                FocusProbe.retryAsync(bundle: b) { fp in
                    out += "  重试后: \(fp.summary)\n"
                    remaining -= 1
                    if remaining == 0 { flush(out, to: path) }
                } onGiveUp: {
                    out += "  重试后: 仍然拿不到\n"
                    remaining -= 1
                    if remaining == 0 { flush(out, to: path) }
                }
            }
        }
    }

    private static func flush(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        log("ax dump -> \(path)")
        NSApp.terminate(nil)
    }

    /// 深挖某个应用的 AX 可用性：逐项读关键属性，看它到底暴露了什么。
    /// 用于判断「读不到焦点」是权限、是懒构建，还是应用根本没开 AX 树。
    static func deepProbe(to path: String, bundleID: String?, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var out = "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
            out += "time: \(Date())\n\n"

            let apps: [NSRunningApplication]
            if let b = bundleID, !b.isEmpty {
                apps = NSRunningApplication.runningApplications(withBundleIdentifier: b)
            } else if let f = NSWorkspace.shared.frontmostApplication {
                apps = [f]
            } else {
                apps = []
            }

            let attrs = [
                kAXFocusedUIElementAttribute,
                kAXFocusedWindowAttribute,
                kAXWindowsAttribute,
                kAXMainWindowAttribute,
                kAXTitleAttribute,
                kAXRoleAttribute,
            ]

            for app in apps {
                let b = app.bundleIdentifier ?? "?"
                out += "=== \(b) pid=\(app.processIdentifier) active=\(app.isActive) ===\n"
                let el = AXUIElementCreateApplication(app.processIdentifier)
                for a in attrs {
                    var v: CFTypeRef?
                    let e = AXUIElementCopyAttributeValue(el, a as CFString, &v)
                    var desc = "nil"
                    if let v = v {
                        if let s = v as? String { desc = s.prefix(60).description }
                        else if let arr = v as? [AXUIElement] { desc = "<\(arr.count) elements>" }
                        else if CFGetTypeID(v) == AXUIElementGetTypeID() {
                            let sub = v as! AXUIElement
                            desc = "role=\(axString(sub, kAXRoleAttribute)) title=\(axString(sub, kAXTitleAttribute).prefix(40)) dom=\(axStringArray(sub, "AXDOMClassList"))"
                        } else { desc = String(describing: v).prefix(60).description }
                    }
                    out += "  \(a.padding(toLength: 28, withPad: " ", startingAt: 0)) \(axErrorName(e))  \(desc)\n"
                }
                out += "\n"
            }

            flush(out, to: path)
        }
    }

    /// 2x 渲染，保证 README 里在 Retina 屏上不糊
    private static func writePNG(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        view.cacheDisplay(in: bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            log("snapshot -> \(path) size=\(bounds.size)@\(Int(scale))x")
        }
    }
}
