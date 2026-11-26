import AppKit
import SwiftUI
import DualDockCore
import QuartzCore
import ScreenCaptureKit

/// Native settings captures with isolated preferences, app lists and permissions.
/// Default: hidden view-cache rendering. --window-server briefly orders only
/// owned fixtures behind current windows to capture native material accurately.
@main struct RenderSettings {
    @MainActor private static var useWindowServer = false
    @MainActor private static var captureCount = 0

    @MainActor static func main() throws {
        // The standalone renderer uses its own defaults domain. Never use the
        // installed app's preference domain, even when a capture fails.
        precondition(Bundle.main.bundleIdentifier != "local.ronny.DualDock" &&
                     ProcessInfo.processInfo.processName == "RenderSettings")
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--expect-language" {
            guard AppLanguage.current.rawValue == CommandLine.arguments[2] else { exit(1) }
            return
        }
        let defaults = UserDefaults.standard
        let savedLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let savedLanguage { defaults.set(savedLanguage, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        AppLanguage.set(.simplifiedChinese)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let nativeOnly = CommandLine.arguments.dropFirst(3).contains("--compact-windows")
        useWindowServer = nativeOnly || CommandLine.arguments.dropFirst(3).contains("--window-server")
        if useWindowServer && !CGPreflightScreenCaptureAccess() {
            throw NSError(domain:"RenderSettings",code:1,userInfo:[NSLocalizedDescriptionKey:
                "Window capture requires existing screen-capture permission; no permission prompt was requested."])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApp.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        let directory = output.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DockConfiguration()
        config.hideSystemDock = false; config.showBadges = false; config.showPreviews = false
        config.customSizing = .visualDefault
        config.entries = ["Mail", "Calendar", "Notes", "Reminders", "Safari", "Preview", "Music"].map { name in
            let path = name == "Safari" ? "/Applications/Safari.app" : "/System/Applications/\(name).app"
            let id = Bundle(path:path)?.bundleIdentifier ?? "fixture.\(name)"
            return DockEntry(name: name, apps: [AppReference(id:id,name:name,path:path)])
        }
        config.entries.append(DockEntry(name: "工作", apps: [
            .init(id:"fixture.TextEdit",name:"TextEdit",path:"/System/Applications/TextEdit.app"),
            .init(id:"fixture.Preview2",name:"Preview",path:"/System/Applications/Preview.app")], isGroup: true))
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let fixtureApps = config.entries.flatMap(\.apps)
        var fixturePermissions = (accessibility:true,capture:true)
        let store = AppStore(directory: directory,runningAppsProvider:{ fixtureApps },
                             permissionsProvider:{ fixturePermissions })
        store.stopBackgroundServices()
        store.updateDisplays([
            .init(id:"A",runtimeID:1,name:"内建视网膜显示屏",frame:CGRect(x:0,y:0,width:1800,height:1169),visibleFrame:CGRect(x:0,y:0,width:1800,height:1129),isPrimary:true),
            .init(id:"B",runtimeID:2,name:"Studio Display",frame:CGRect(x:1800,y:0,width:2560,height:1440),visibleFrame:CGRect(x:1800,y:0,width:2560,height:1415))])
        let login = LaunchAtLoginService(environment: .init(status: { .notRegistered },
            register: {}, unregister: {}, openSettings: {}))
        if nativeOnly {
            try checkSettingsNavigation(store: store, login: login, output: output)
            store.stopBackgroundServices()
            return
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for section in SettingsSection.allCases {
                try capture(AnyView(SettingsView(store:store,initialSection:section,displayID:"A",launchAtLoginService:login)),
                            name:"\(section.rawValue)-\(theme)", size:NSSize(width:1060,height:760),dark:dark,output:output)
            }
            try capture(AnyView(SettingsView(store:store,initialSection:.appearance,displayID:"A")),
                        name:"appearance-compact-\(theme)",size:NSSize(width:820,height:580),dark:dark,output:output)
            try capture(AnyView(AppearanceSettingsView(store:store,selectedDisplayID:.constant("A"),advancedInitially:true)
                        .font(.system(size:13)).toggleStyle(.switch).controlSize(.regular).padding(26)),
                        name:"appearance-advanced-\(theme)",size:NSSize(width:850,height:1260),dark:dark,output:output)
        }
        for dark in [false, true] {
            try capture(AnyView(SettingsView(store:store,initialSection:.about,displayID:"A")),
                        name:"about-compact-\(dark ? "dark" : "light")",size:NSSize(width:820,height:580),dark:dark,output:output)
        }
        for edge in [DockEdge.left, .right, .top] {
            store.setEdge(edge, for:"A")
            try capture(AnyView(SettingsView(store:store,initialSection:.appearance,displayID:"A")),
                        name:"appearance-\(edge.rawValue)-light",size:NSSize(width:1060,height:760),dark:false,output:output)
        }
        store.setEdge(.bottom, for:"A")
        store.setAdaptiveSizing(true)
        try capture(AnyView(SettingsView(store:store,initialSection:.appearance,displayID:"A")),
                    name:"appearance-native-dark",size:NSSize(width:1060,height:760),dark:true,output:output)
        store.setAdaptiveSizing(false)
        fixturePermissions = (accessibility:false,capture:false)
        store.refreshPermissions()
        try capture(AnyView(SettingsView(store:store,initialSection:.permissions,displayID:"A")),
                    name:"permissions-needed-light",size:NSSize(width:820,height:580),dark:false,output:output)
        store.update { $0.customSizing = nil }
        try capture(AnyView(AppearanceSettingsView(store:store,selectedDisplayID:.constant("A"),advancedInitially:true)
                    .font(.system(size:13)).toggleStyle(.switch).padding(26)),
                    name:"appearance-manual-overrides-light",size:NSSize(width:850,height:1360),dark:false,output:output)
        store.update {
            $0.customSizing = .visualDefault
            for index in 0..<24 {
                let source = fixtureApps[index % fixtureApps.count]
                let app = AppReference(id:"fixture.extra.\(index)",name:source.name,path:source.path)
                $0.entries.append(DockEntry(name:source.name,apps:[app]))
            }
        }
        for dark in [false,true] {
            try capture(AnyView(SettingsView(store:store,initialSection:.appearance,displayID:"A")),
                        name:"appearance-many-apps-\(dark ? "dark" : "light")",size:NSSize(width:1060,height:760),dark:dark,output:output)
        }
        store.update { $0.entries = config.entries; $0.customSizing = .visualDefault }
        fixturePermissions = (accessibility:true,capture:true)
        store.refreshPermissions()
        try languageMatrix(store: store, login: login, output: output)
        if useWindowServer { try checkSettingsNavigation(store: store, login: login, output: output) }
        store.stopBackgroundServices()
        let metadata: [String:Any] = [
            "captureMode":useWindowServer ? "window-server-owned-fixtures" : "hidden-view-cache",
            "generatedAt":ISO8601DateFormatter().string(from:Date()),
            "fixture":"Synthetic preferences, eight pinned entries, two displays, simulated permissions; many-app state adds 24 sample entries.",
            "limitations":useWindowServer
                ? "Native views captured in inactive fixture windows with an owned solid backdrop; no live user configuration or interactions are represented."
                : "Native backdrop material is unavailable offscreen: sidebar selected-row fill is unreliable. Content rendering only; do not use to accept sidebar appearance.",
            "windows":"No activation requested. Window-server mode closes each owned fixture and its backdrop immediately after capture.",
            "captureCount":captureCount
        ]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("capture-metadata.json"))
        print("Rendered \(captureCount) native settings captures using isolated fixtures; mode: \(useWindowServer ? "window server" : "hidden view cache")")
    }

    /// Exercise the actual preferences toolbar and photograph its window chrome.
    @MainActor private static func checkSettingsNavigation(store: AppStore, login: LaunchAtLoginService, output: URL) throws {
        let navigation = SettingsNavigation()
        let controller = SettingsWindowController(store: store, navigation: navigation, launchAtLoginService: login)
        defer { controller.stop(); AppLanguage.set(.simplifiedChinese) }
        guard let window = controller.window, let toolbar = window.toolbar else { fatalError("Missing settings toolbar") }
        precondition(toolbar.displayMode == .iconAndLabel)
        for category in SettingsCategory.allCases {
            guard let button = toolbar.items.first(where: { $0.itemIdentifier.rawValue == category.rawValue }),
                  let action = button.action else { fatalError("Missing native category") }
            precondition(NSApp.sendAction(action, to: button.target, from: button))
            precondition(navigation.selected.category == category)
        }
        for (query, expected) in [("badge size", SettingsSection.notifications), ("角标", .notifications), ("工具页", .tools), ("Tool cards", .tools),
                                  ("English", .general), ("辅助功能", .permissions)] {
            navigation.query = query
            precondition(navigation.visibleSections.contains(expected))
            navigation.show(expected)
            precondition(toolbar.selectedItemIdentifier?.rawValue == expected.category.rawValue && navigation.query.isEmpty)
        }
        precondition(SettingsCategory.dock.sections == [.appearance, .displays, .groupAppearance, .tools])
        for query in ["文件夹外观", "背景颜色", "背景透明度", "folder style", "background opacity"] {
            navigation.query = query
            precondition(navigation.visibleSections.contains(.groupAppearance))
        }
        for (query, target) in [("多屏和显示内容", SettingsSection.displays), ("Displays & Content", .displays),
                                ("屏幕与位置", .displays), ("Dock position", .displays),
                                ("显示内容", .contents), ("running apps only", .contents)] {
            navigation.query = query
            precondition(navigation.visibleSections == [.displays])
            navigation.selectSidebarEntry(.displays)
            precondition(navigation.selected == target && navigation.selected.sidebarEntry == .displays)
        }
        navigation.query = "unmatched-98e1"
        precondition(navigation.visibleSections.isEmpty)
        navigation.show(SettingsSection.notifications)
        navigation.show(SettingsCategory.general)
        navigation.show(SettingsCategory.interaction)
        precondition(navigation.selected == .notifications)
        guard let screen = NSScreen.main else { fatalError("A display is required") }
        window.setFrameTopLeftPoint(NSPoint(x:screen.visibleFrame.minX + 30, y:screen.visibleFrame.maxY - 20))
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        func settle() {
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.26))
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        func demand(_ condition: Bool, _ reason: String) throws {
            if !condition { throw NSError(domain:"SettingsDensity",code:1,
                userInfo:[NSLocalizedDescriptionKey:reason]) }
        }
        func captureNative(_ name: String) throws -> [String:Any] {
            settle()
            let size = window.frame.size
            let viewport = window.contentLayoutRect.size
            let bitmap = try windowServerCapture(window:window,size:size,appearance:window.effectiveAppearance,
                                                 preserveFrame:true)
            try demand(abs(window.frame.height - size.height) < 1,
                       "Window had not settled before capture: " + name)
            guard let data = bitmap.representation(using:.png,properties:[:]) else { fatalError("No window capture") }
            try data.write(to:output.appendingPathComponent(name + ".png"))
            captureCount += 1
            let blank = bottomMargin(bitmap, windowSize: size)
            print("\(name): frame \(Int(size.width))×\(Int(size.height)), content \(Int(viewport.width))×\(Int(viewport.height)), trailing detail margin ≈\(blank) pt")
            fflush(stdout)
            return ["name":name, "width":size.width, "height":size.height,
                    "contentWidth":viewport.width, "contentHeight":viewport.height,
                    "trailingBlankPoints":blank]
        }
        func descendantScrollViews(_ view:NSView?) -> [NSScrollView] {
            guard let view else { return [] }
            return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { descendantScrollViews($0) }
        }
        var samples: [[String:Any]] = []
        let defaultFrame = window.frame
        try demand(defaultFrame.size == NSSize(width:820,height:560),
                   "Settings should open at the common compact size, including its toolbar")
        for lang in [AppLanguage.simplifiedChinese, .english] {
            AppLanguage.set(lang)
            let dark = lang == .simplifiedChinese
            let appearance = NSAppearance(named:dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            window.appearance = appearance
            for section in SettingsSection.allCases {
                navigation.show(section)
                let name = "compact-" + lang.rawValue + "-" + section.rawValue
                let sample = try captureNative(name)
                samples.append(sample)
                try demand(navigation.selected == section, "Selecting a sidebar or search entry lost the target: " + name)
                try demand(window.frame == defaultFrame, "Settings page moved or resized the window: " + name)
                if section == .appearance {
                    let source = output.appendingPathComponent(name + ".png")
                    try Data(contentsOf:source).write(to:output.appendingPathComponent("settings-window-" + lang.rawValue + ".png"))
                }
            }
        }

        // Both sections share one document; programmatic navigation should
        // reveal the final section without moving the window or losing the target.
        navigation.show(SettingsSection.general)
        settle()
        guard let generalScroll = descendantScrollViews(window.contentView).first(where: { $0.bounds.width > 300 }),
              let document = generalScroll.documentView else { fatalError("Missing settings detail document") }
        let firstOffset = generalScroll.contentView.bounds.origin.y
        navigation.show(SettingsSection.permissions)
        settle()
        try demand(generalScroll.documentView === document && generalScroll.contentView.bounds.origin.y > firstOffset + 30
                   && navigation.selected == .permissions, "The sidebar did not reveal Permissions in the general form")
        let scrollUp = CGEvent(scrollWheelEvent2Source:nil, units:.pixel,
                               wheelCount:1, wheel1:240, wheel2:0, wheel3:0)!
        let wheel = NSEvent(cgEvent:scrollUp)!
        for _ in 0..<8 { generalScroll.scrollWheel(with:wheel) }
        settle()
        try demand(abs(generalScroll.contentView.bounds.origin.y - firstOffset) < 2,
                   "The fixture's scroll events did not reach the first section")
        try demand(navigation.selected == .general,
                   "Scrolling to the first section left the sidebar on " + navigation.selected.rawValue)

        // Exercise live-resize bounds with the native window, without posting
        // pointer events. Navigation and dynamic content must preserve its frame.
        navigation.show(SettingsSection.contents)
        settle()
        var resized = window.frame
        let minimum = controller.windowWillResize(window, to: NSSize(width:100, height:100))
        try demand(minimum.width == 740 && minimum.height >= 320 + window.frame.height - window.contentLayoutRect.height,
                   "The supported minimum size was lost")
        resized.size.width = minimum.width
        try demand(controller.windowWillResize(window, to: resized.size) == resized.size,
                   "The supported compact width is rejected")
        window.setFrame(resized, display:true)
        settle()
        navigation.show(SettingsSection.appearance)
        samples.append(try captureNative("compact-en-minimum-appearance"))
        let originalFolder = store.configuration.folderAppearance
        navigation.show(SettingsSection.groupAppearance)
        store.update {
            $0.folderAppearance = DockFolderAppearance(style: .glass,
                backgroundColor: DockFolderColor(red: 0.2, green: 0.55, blue: 0.65), backgroundOpacity: 0.6)
        }
        samples.append(try captureNative("compact-en-minimum-groupAppearance-tinted"))
        store.update { $0.folderAppearance.backgroundOpacity = 0 }
        samples.append(try captureNative("compact-en-minimum-groupAppearance-clear"))
        store.update { $0.folderAppearance = originalFolder }
        try demand(window.frame == resized,
                   "Category navigation changed the resized window")

        navigation.show(SettingsSection.contents)
        settle()
        let shortFrame = window.frame
        store.message = String(repeating:"This fixture tests wrapping of an inline settings notice. ",count:12)
        settle()
        try demand(window.frame == shortFrame, "Showing an inline notice resized the window")
        store.message = String(repeating:"Long fixture notice. ",count:300)
        settle()
        try demand(window.frame == shortFrame, "Long text resized the window instead of scrolling")
        try demand(descendantScrollViews(window.contentView).contains { scroll in
            guard let document = scroll.documentView else { return false }
            return scroll.bounds.width > 300 && document.bounds.height > scroll.contentView.bounds.height + 50
        }, "Long content was not reachable through the detail scroll view")
        store.message = nil
        settle()
        try demand(window.frame == shortFrame, "Dismissing an inline notice changed the window frame")

        resized = window.frame
        resized.size.height += 68
        resized.origin.y -= 68
        window.setFrame(resized, display:true)
        navigation.show(SettingsSection.appearance)
        settle()
        try demand(window.frame == resized, "Switching pages overrode a manual height adjustment")

        try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("compact-window-metrics.json"))
        print("Verified native settings: \(SettingsSection.sidebarEntries.count) sidebar entries, \(SettingsSection.allCases.count) sections × 2 languages, search, toolbar, live content changes and user resizing")
    }

    /// Approximate the empty strip below the last detail row. Ignore sidebar,
    /// rounded corners and low-contrast antialiasing at the window edges.
    private static func bottomMargin(_ bitmap:NSBitmapImageRep, windowSize:NSSize) -> Int {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        let scale = CGFloat(height) / windowSize.height
        func level(_ x:Int, _ y:Int) -> CGFloat {
            guard let c = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return (c.redComponent+c.greenComponent+c.blueComponent)/3
        }
        let bg = level(width-24,height-16)
        for y in stride(from:height-16, through:16, by:-2) {
            var count = 0
            for x in stride(from:Int(CGFloat(width)*0.32), to:width-24, by:12) {
                if abs(level(x,y)-bg) > 0.012 { count += 1 }
                if count >= 3 { return Int(CGFloat(height-y)/scale) }
            }
        }
        return Int(windowSize.height)
    }

    @MainActor private static func languageMatrix(store: AppStore, login: LaunchAtLoginService, output: URL) throws {
        // All three stages reuse the exact same SettingsView, hosting view and
        // window. Only the production language preference changes between frames.
        let transitions: [(AppLanguage, String)] = [
            (.simplifiedChinese, "live-general-zh"), (.english, "live-general-en"), (.simplifiedChinese, "live-general-zh-restored")
        ]
        try capture(AnyView(SettingsView(store: store, initialSection: .general, displayID: "A",
            launchAtLoginService: login)), name: "live-general", size: NSSize(width: 1060, height: 760),
            dark: false, output: output, transitions: transitions)

        try verifyLiveSidebar(in: output, names: transitions.map { $0.1 })
        AppLanguage.set(.english)
        try verifyPreferenceAfterRelaunch(.english)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for section in SettingsSection.allCases {
                try capture(AnyView(SettingsView(store: store, initialSection: section, displayID: "A",
                    launchAtLoginService: login)), name: "en-\(section.rawValue)-\(theme)",
                    size: NSSize(width: 1060, height: 760), dark: dark, output: output)
            }
            for section in [SettingsSection.general, .appearance] {
                try capture(AnyView(SettingsView(store: store, initialSection: section, displayID: "A",
                    launchAtLoginService: login)), name: "en-\(section.rawValue)-compact-\(theme)",
                    size: NSSize(width: 820, height: 580), dark: dark, output: output)
            }
            try capture(AnyView(AppearanceSettingsView(store:store,selectedDisplayID:.constant("A"),advancedInitially:true)
                .font(.system(size:13)).toggleStyle(.switch).controlSize(.regular).padding(26)
                .environment(\.dualDockLanguage, .english).environment(\.locale, Locale(identifier:"en"))),
                name:"en-appearance-advanced-\(theme)",size:NSSize(width:850,height:1260),dark:dark,output:output)
        }

        let firstRegistration = LaunchAtLoginService(environment: .init(status: { .notFound },
            register: { throw NSError(domain: "LoginFixture", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Registration could not be completed."]) },
            unregister: {}, openSettings: {}))
        firstRegistration.setEnabled(true)
        try capture(AnyView(SettingsView(store: store, initialSection: .general, displayID: "A",
            launchAtLoginService: firstRegistration)), name: "en-general-registration-failed",
            size: NSSize(width: 820, height: 720), dark: false, output: output)
        AppLanguage.set(.simplifiedChinese)
        try verifyPreferenceAfterRelaunch(.simplifiedChinese)
    }

    private static func verifyLiveSidebar(in output: URL, names: [String]) throws {
        // Compare only the category labels in the sidebar; this excludes the
        // picker, content-specific state, window chrome, scroll and animations.
        let windowSize = CGSize(width: 1060, height: 760)
        let region = CGRect(x: 46, y: 76, width: 121, height: 260)
        func grayscaleLabels(_ name: String) throws -> [UInt8] {
            let url = output.appendingPathComponent(name + ".png")
            guard let data = try? Data(contentsOf: url),
                  let image = NSBitmapImageRep(data: data)?.cgImage,
                  let crop = image.cropping(to: region.applying(
                    CGAffineTransform(scaleX: CGFloat(image.width) / windowSize.width,
                                      y: CGFloat(image.height) / windowSize.height))) else {
                throw NSError(domain: "RenderSettings", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot inspect live sidebar image"])
            }
            let width = Int(region.width), height = Int(region.height)
            var bytes = [UInt8](repeating: 0, count: width * height)
            try bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    throw NSError(domain: "RenderSettings", code: 8)
                }
                context.draw(crop, in: CGRect(origin: .zero, size: region.size))
            }
            return bytes
        }
        let zh = try grayscaleLabels(names[0])
        let en = try grayscaleLabels(names[1])
        let back = try grayscaleLabels(names[2])
        func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 32 }.count) / Double(a.count)
        }
        let switched = changedFraction(zh, en), restored = changedFraction(zh, back)
        guard switched > 0.02 && restored < switched * 0.25 else {
            throw NSError(domain: "RenderSettings", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Live sidebar switch failed: changed=\(switched), restored=\(restored)"
            ])
        }
        print("Same-window language change verified in sidebar text: changed=\(switched), restored=\(restored)")
    }

    @MainActor private static func verifyPreferenceAfterRelaunch(_ language: AppLanguage) throws {
        UserDefaults.standard.synchronize()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--expect-language", language.rawValue]
        try child.run()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            throw NSError(domain: "RenderSettings", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Language preference did not survive a fresh process"])
        }
    }

    @MainActor static func capture(_ view:AnyView,name:String,size:NSSize,dark:Bool,output:URL,
                                   transitions: [(AppLanguage, String)]? = nil) throws {
        let appearance = NSAppearance(named:dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        var captureError: Error?
        appearance.performAsCurrentDrawingAppearance {
            do {
                // Host the production views at a fixed viewport. NSHostingView's
                // intrinsic sizing must not enlarge the invisible capture window.
                let hosting = NSHostingView(rootView:view
                    .environment(\.colorScheme,dark ? .dark : .light)
                    .frame(width:size.width,height:size.height,alignment:.topLeading))
                hosting.sizingOptions = []
                hosting.appearance = appearance
                let bounds = NSRect(origin:.zero,size:size)
                let window = NSWindow(contentRect:bounds,styleMask:[.borderless],backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.backgroundColor = .windowBackgroundColor
                window.contentView = hosting
                window.setContentSize(size)
                hosting.frame = bounds
                defer { window.close() }
                let stages = transitions ?? [(AppLanguage.current, name)]
                for (language, name) in stages {
                    AppLanguage.set(language)
                    captureCount += 1
                    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
                    hosting.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    hosting.display()
                    CATransaction.flush()
                    precondition(hosting.bounds.size == size, "Capture viewport changed")
                    if useWindowServer {
                        let bitmap = try windowServerCapture(window:window,size:size,appearance:appearance)
                        guard let data = bitmap.representation(using:.png,properties:[:]) else { fatalError("No PNG") }
                        try data.write(to:output.appendingPathComponent(name+".png"))
                        print("\(name): \(Int(size.width))×\(Int(size.height)) pt, \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px (window server)")
                        continue
                    }
                    guard let cached = hosting.bitmapImageRepForCachingDisplay(in:bounds) else { fatalError("No bitmap") }
                    hosting.cacheDisplay(in:bounds,to:cached)

                    // cacheDisplay captures the view's alpha, excluding the real
                    // NSWindow background. Preserve native control alpha by drawing
                    // the NSImage source-over the same resolved AppKit background.
                    // NSBitmapImageRep.draw uses copy and would erase the background.
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:cached.pixelsWide,
                        pixelsHigh:cached.pixelsHigh,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,
                        isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    bitmap.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                    NSColor.windowBackgroundColor.setFill()
                    bounds.fill()
                    let rendered = NSImage(size:size)
                    rendered.addRepresentation(cached)
                    rendered.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1)
                    NSGraphicsContext.restoreGraphicsState()
                    precondition(bitmap.colorAt(x:bitmap.pixelsWide-1,y:bitmap.pixelsHigh-1)?.alphaComponent == 1,
                                 "Capture still has a transparent background")
                    guard let data = bitmap.representation(using:.png,properties:[:]) else { fatalError("No PNG") }
                    try data.write(to:output.appendingPathComponent(name+".png"))
                    print("\(name): \(Int(size.width))×\(Int(size.height)) pt, \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px")
                }
            } catch { captureError = error }
        }
        if let captureError { throw captureError }
    }

    @MainActor private static func windowServerCapture(window:NSWindow,size:NSSize,appearance:NSAppearance,preserveFrame:Bool = false) throws -> NSBitmapImageRep {
        guard let screen = NSScreen.screens.max(by:{ $0.visibleFrame.height < $1.visibleFrame.height }) else {
            throw NSError(domain:"RenderSettings",code:2,userInfo:[NSLocalizedDescriptionKey:"No display available"])
        }
        let visible = screen.visibleFrame
        // Anchor the top edge inside a display. Tall full-content captures may
        // extend below it; the independent-window API captures the whole surface.
        let frame = preserveFrame ? window.frame : NSRect(x:visible.minX+20,y:visible.maxY-size.height-20,width:size.width,height:size.height)
        let backdrop = NSWindow(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        backdrop.isReleasedWhenClosed = false
        backdrop.appearance = appearance
        backdrop.backgroundColor = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.collectionBehavior = [.transient,.ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient,.ignoresCycle]
        if !preserveFrame { window.setFrame(frame,display:false) }
        defer { window.orderOut(nil); backdrop.close() }
        backdrop.orderBack(nil)
        window.order(.above,relativeTo:backdrop.windowNumber)
        precondition(!window.isKeyWindow, "Fixture must not take keyboard focus")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let windowID = CGWindowID(window.windowNumber)
        let processID = getpid()
        var result: Result<CGImage,Error>?
        SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly:false) { content,error in
            guard let ownWindow = content?.windows.first(where:{
                $0.windowID == windowID && $0.owningApplication?.processID == processID
            }) else {
                DispatchQueue.main.async {
                    result = .failure(error ?? NSError(domain:"RenderSettings",code:3,
                        userInfo:[NSLocalizedDescriptionKey:"Owned fixture window unavailable for capture"]))
                }
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow:ownWindow)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width*2)
            configuration.height = Int(size.height*2)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration) { image,error in
                DispatchQueue.main.async {
                    if let image { result = .success(image) }
                    else { result = .failure(error ?? NSError(domain:"RenderSettings",code:4,
                        userInfo:[NSLocalizedDescriptionKey:"Owned fixture capture returned no image"])) }
                }
            }
        }
        let deadline = Date(timeIntervalSinceNow:10)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        }
        guard let result else {
            throw NSError(domain:"RenderSettings",code:5,userInfo:[NSLocalizedDescriptionKey:"Owned fixture capture timed out"])
        }
        return NSBitmapImageRep(cgImage:try result.get())
    }
}
