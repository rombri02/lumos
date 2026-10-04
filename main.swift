import AppKit
import SwiftUI
import MetalKit

// Tiny HDR view: its only job is to keep EDR active so macOS raises the backlight
// and opens headroom above SDR white.
final class EDRTrigger: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue

    init(frame: NSRect, device: MTLDevice) {
        queue = device.makeCommandQueue()!
        super.init(frame: frame, device: device)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        clearColor = MTLClearColor(red: 2, green: 2, blue: 2, alpha: 1) // > 1.0 = HDR content
        // Draw once: a static HDR frame keeps EDR on. A render loop can block the main
        // thread in nextDrawable (up to 1s) and freezes the menu slider.
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

final class LumosApp: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let device = MTLCreateSystemDefaultDevice()!
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var originalGamma: [CGDirectDisplayID: [[CGGammaValue]]] = [:]
    private var applied: [CGDirectDisplayID: Float] = [:] // eased boost currently on screen
    private var lastReapply: TimeInterval = 0
    private var timer: Timer?
    private var hdrScreens: [(screen: NSScreen, id: CGDirectDisplayID)] = []
    private let model = Model()
    private let popover = NSPopover()
    // Shown when the app is opened from Applications / Spotlight (e.g. with the menu bar icon hidden).
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: true)

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "wand.and.rays", accessibilityDescription: "Lumos")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.isVisible = model.showIcon

        model.onQuit = { [weak self] in self?.quit() }
        model.onShowIconChange = { [weak self] visible in
            self?.statusItem.isVisible = visible
            if !visible { self?.showWindow() } // popover anchor is gone: keep the controls on screen
        }

        // Slider lives in a popover, not an NSMenu: drag tracking inside a status-bar menu gets stuck.
        // SwiftUI content is created on open and dropped on close: idle, Lumos holds no UI in memory.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .alertPanel

        // Opened by hand with the icon hidden: show the window, otherwise there's no UI at all.
        // At login (or with the icon visible) stay quietly in the background.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !model.showIcon && !atLogin { showWindow() }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Wake resets gamma: re-apply immediately instead of waiting for the 1 s heartbeat.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        refreshScreens()
        listenForBrightnessChanges()
        update()
    }

    private func refreshScreens() {
        hdrScreens = NSScreen.screens.compactMap { screen in
            guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (screen, id)
        }
    }

    // macOS pushes brightness changes (keys, Control Center, auto-brightness), so idle Lumos
    // only wakes once a second to re-apply gamma. 30 Hz runs only while easing a change.
    // If the push API is missing, fall back to polling at 10 Hz.
    private var brightnessPush = false

    private func schedule(fast: Bool) {
        let interval = fast ? 1.0 / 30 : (brightnessPush ? 1.0 : 0.1)
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        timer?.tolerance = interval * 0.2 // lets macOS coalesce wakeups
    }

    // System brightness where Lumos starts adding its boost; at 100% it reaches `boost`.
    static let boostStart: Float = 0.65

    static func targetBoost(brightness: Float, max: Float) -> Float {
        1 + (max - 1) * min(1, Swift.max(0, (brightness - boostStart) / (1 - boostStart)))
    }

    // Private DisplayServices API (no public one): built-in display brightness 0...1.
    private static let getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private func listenForBrightnessChanges() {
        typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        guard let sym = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return }
        let register = unsafeBitCast(sym, to: Register.self)
        let me = Unmanaged.passUnretained(self).toOpaque()
        brightnessPush = hdrScreens.allSatisfy { _, id in
            register(id, me) { _, observer, _, _, _ in
                guard let observer else { return }
                let app = Unmanaged<LumosApp>.fromOpaque(observer).takeUnretainedValue()
                // Only wake the 30 Hz loop: calling update() per notification (~120/s during
                // a key animation) would speed up the easing and bring back the dip.
                DispatchQueue.main.async { app.schedule(fast: true) }
            } == 0
        }
    }

    private func brightness(of id: CGDirectDisplayID) -> Float {
        var value: Float = 1 // unreadable (e.g. some external displays): treat as 100%
        _ = LumosApp.getBrightness?(id, &value)
        return value
    }

    @objc private func screensChanged() {
        windows.values.forEach { $0.orderOut(nil) } // positions are stale; update() recreates them
        windows = [:]
        lastReapply = 0 // force gamma re-apply now
        refreshScreens()
        update()
    }

    private func makeTrigger(on screen: NSScreen) -> NSWindow {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = EDRTrigger(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device)
        window.orderFrontRegardless()
        return window
    }

    // Per-tick easing (30 Hz): ~0.3s to settle, matching macOS's own brightness-key animation.
    // Jumping instantly while the backlight is still ramping causes a visible dip.
    static func ease(from current: Float, to target: Float) -> Float {
        let next = current + (target - current) * 0.25
        return abs(target - next) < 0.002 ? target : next
    }

    private func update() {
        var active = Set<CGDirectDisplayID>()
        var liveBrightness: Float = 0, liveBoost: Float = 1, easing = false
        // macOS resets gamma on wake, Night Shift, display changes: re-apply ~1x/s anyway.
        let now = ProcessInfo.processInfo.systemUptime
        let reapply = now - lastReapply > 0.9
        if reapply { lastReapply = now }
        for (screen, id) in hdrScreens {
            let level = brightness(of: id)
            liveBrightness = max(liveBrightness, level)
            let target = model.enabled ? LumosApp.targetBoost(brightness: level, max: Float(model.boost)) : 1
            let current = applied[id] ?? 1
            let next = LumosApp.ease(from: current, to: target)
            applied[id] = next
            if next != target { easing = true }
            guard next > 1.001 else { continue }
            active.insert(id)
            // EDR (raised backlight) only while boosting: it costs battery.
            if windows[id] == nil { windows[id] = makeTrigger(on: screen) }
            if originalGamma[id] == nil {
                var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
                var count: UInt32 = 0
                CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &count)
                originalGamma[id] = [r, g, b].map { Array($0.prefix(Int(count))) }
            }
            // Clamp to current headroom: it ramps up when EDR starts and shrinks when the panel is hot.
            let factor = min(next, Float(screen.maximumExtendedDynamicRangeColorComponentValue))
            if next != current || reapply {
                let t = originalGamma[id]!.map { $0.map { LumosApp.toneMap($0, factor) } }
                CGSetDisplayTransferByTable(id, UInt32(t[0].count), t[0], t[1], t[2])
            }
            liveBoost = max(liveBoost, factor)
        }
        // Every write to the @Observable model re-renders the UI: write only when the
        // displayed value (2 decimals) changes, not on every 30 Hz easing step.
        let shownBrightness = (Double(liveBrightness) * 100).rounded() / 100
        let shownBoost = (Double(liveBoost) * 100).rounded() / 100
        if model.brightness != shownBrightness { model.brightness = shownBrightness }
        if model.currentBoost != shownBoost { model.currentBoost = shownBoost }
        for (id, window) in windows where !active.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
            applied[id] = nil
            if let o = originalGamma[id] { CGSetDisplayTransferByTable(id, UInt32(o[0].count), o[0], o[1], o[2]) }
        }
        schedule(fast: easing)
    }

    // Shadows and midtones get the full extra boost; above the knee the extra boost fades
    // smoothly down to `highlightBoost` at pure white, so highlights don't clip.
    // Every tone's extra brightness is proportional to (factor - 1): the slider feels linear.
    static let knee: Float = 0.35
    // Fraction of the extra boost that pure white receives.
    static let highlightBoost: Float = 0.16

    static func toneMap(_ x: Float, _ factor: Float) -> Float {
        let t = max(0, (x - knee) / (1 - knee))
        let weight = 1 - (1 - highlightBoost) * t * t * (3 - 2 * t) // smoothstep fade
        return x * (1 + (factor - 1) * weight)
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        window.close()
        if popover.contentViewController == nil {
            let content = NSHostingController(rootView: ControlsView(model: model))
            content.sizingOptions = .preferredContentSize
            popover.contentViewController = content
        }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showWindow() {
        popover.performClose(nil)
        if window.contentViewController == nil {
            let content = NSHostingController(rootView: ControlsView(model: model))
            window.contentViewController = content
            window.setContentSize(content.view.fittingSize)
        }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
    func windowWillClose(_ notification: Notification) { window.contentViewController = nil }

    // Launching the app again from Applications / Spotlight while it's running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    private func quit() {
        CGDisplayRestoreColorSyncSettings()
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--selftest") {
    let f: Float = 1.8
    let curve = stride(from: Float(0), through: 1, by: 1 / 255).map { LumosApp.toneMap($0, f) }
    precondition(LumosApp.toneMap(0.2, f) == 0.2 * f, "midtones get the full boost")
    precondition(zip(curve, curve.dropFirst()).allSatisfy { $0 < $1 }, "monotonic: no highlight detail lost")
    precondition(curve.last! < f, "peak stays below a plain linear boost")
    precondition(LumosApp.toneMap(0.8, 1) == 0.8, "factor 1 is identity")
    precondition(stride(from: Float(0), through: 1, by: 0.01).allSatisfy { LumosApp.toneMap($0, 1.2) >= $0 }, "never darker than original")
    precondition(stride(from: Float(0), through: 1, by: 0.01).allSatisfy {
        abs((LumosApp.toneMap($0, 1.5) - $0) * 2 - (LumosApp.toneMap($0, 2) - $0)) < 1e-5
    }, "extra brightness is linear in the slider value")
    precondition(LumosApp.targetBoost(brightness: 0.5, max: 1.8) == 1, "no boost below boostStart")
    precondition(LumosApp.targetBoost(brightness: 1, max: 1.8) == 1.8, "full boost at 100%")
    precondition(abs(LumosApp.targetBoost(brightness: 0.825, max: 1.8) - 1.4) < 1e-5, "linear ramp in between")
    var eased: Float = 1, steps = 0
    while 1.8 - eased > 0.04 { eased = LumosApp.ease(from: eased, to: 1.8); steps += 1 }
    precondition((8...12).contains(steps), "easing reaches 95% in ~0.3s at 30 Hz (took \(steps) ticks)")
    while eased != 1.8 { eased = LumosApp.ease(from: eased, to: 1.8) } // must terminate exactly
    print("selftest ok, white ->", curve.last!)
    exit(0)
}

let app = NSApplication.shared
let delegate = LumosApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
