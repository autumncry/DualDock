import AppKit
import DualDockCore

/// Injected native boundary: no real window enumeration/actions or input.
@main
struct WindowInteractionChecks {
    @MainActor static func main() async {
        let app = AppReference(id: "test.windows", name: "Fixture", path: "/Applications/Fixture.app")
        let date = Date(timeIntervalSince1970: 100)
        func item(_ number: UInt32, minimized: Bool = false, front: Bool = true, fullscreen: Bool = false,
                  maximized: Bool = false, launchDate: Date? = nil) -> DockWindowItem {
            .init(id: .init(pid: 123, processLaunchDate: launchDate ?? date, applicationPath: app.path, windowID: number),
                  title: "Window \(number)", frame: CGRect(x: 100, y: 100, width: 700, height: 500),
                  isMinimized: minimized, isFullscreen: fullscreen, isMaximized: maximized,
                  isFrontmost: front, isFocused: front, isMain: number == 1)
        }
        var failures: [String] = []
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; if !value { failures.append(message) } }
        func handled(_ value: WindowInteractionResult) -> Bool { value == .handled }
        var windows = [item(1)]
        var calls: [(UInt32, DockWindowAction)] = []
        var nextOutcome = DockWindowActionOutcome.performed
        var readDelay: UInt64 = 0
        var actionDelay: UInt64 = 0
        var reads = 0
        var readIssue: DockWindowInventory?
        var recoveries: [DockWindowIdentity] = []
        var recovered = false
        let environment = WindowInteractionService.Environment(read: { _ in
            reads += 1
            if readDelay > 0 { try? await Task.sleep(nanoseconds: readDelay) }
            return readIssue ?? .available(windows)
        }, perform: { selected, action, _ in
            calls.append((selected.id.windowID, action))
            if actionDelay > 0 { try? await Task.sleep(nanoseconds: actionDelay) }
            guard nextOutcome == .performed else { return nextOutcome }
            windows = windows.map { current in
                let target = current.id == selected.id
                return .init(id: current.id, title: current.title, frame: current.frame,
                    isMinimized: target ? action == .minimize : current.isMinimized,
                    isFullscreen: current.isFullscreen, isMaximized: current.isMaximized,
                    isFrontmost: target && action != .minimize,
                    isFocused: target && action != .minimize, isMain: current.isMain)
            }
            return .performed
        }, recover: { identity, target in
            check(target == app, "Recovery lost the requested application")
            recoveries.append(identity)
            return recovered
        })
        var service = WindowInteractionService(environment: environment)

        for expected in [DockWindowAction.minimize, .restore, .minimize, .restore] {
            check(handled(await service.toggle(for: app)), "ordinary toggle failed")
            check(calls.last?.1 == expected, "repeat click did not alternate \(expected)")
            check(windows[0].isMinimized == (expected == .minimize), "native minimized state mismatch")
        }
        windows = [item(1, front: false)]
        check(handled(await service.toggle(for: app)), "background activation failed")
        check(calls.last?.1 == .activate, "background window was minimized")
        check(handled(await service.toggle(for: app)) && calls.last?.1 == .minimize, "second frontmost click did not minimize")

        windows = [item(1), item(2, front: false)]
        check(handled(await service.select(windows[1], for: app)), "window B selection failed")
        let listed = await service.list(for: app)
        check(listed.selectedID?.windowID == 2 && listed.items.count == 2, "menu checkmark did not remember window B")
        let retainedWindows = windows
        readIssue = .unavailable
        check((await service.list(for: app)).items.isEmpty, "unavailable snapshot was not empty")
        readIssue = nil
        windows = retainedWindows
        check((await service.list(for: app)).selectedID?.windowID == 2, "temporary AX unavailability lost selected B")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .minimize,
              "icon click did not minimize selected B")
        // Minimizing B can make A focused, but the next icon click must restore B.
        windows = [item(1), item(2, minimized: true, front: false)]
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .restore,
              "focused A replaced remembered minimized B")
        let staleB = windows[1]
        windows = [item(1)]
        let beforeStale = calls.count
        check(await service.select(staleB, for: app) == .targetUnavailable,
              "explicit stale selection was not quietly rejected")
        check(calls.count == beforeStale, "stale window dispatched action")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 1, "closed target did not use fresh focused window")

        let old = item(1)
        windows = [item(1, launchDate: Date(timeIntervalSince1970: 200))]
        let beforeReuse = calls.count
        check(await service.select(old, for: app) == .targetUnavailable,
              "PID/window ID reuse was not quietly rejected")
        check(calls.count == beforeReuse, "reused PID dispatched action")

        for (fullscreen, maximized) in [(true, false), (false, true), (true, true)] {
            service = WindowInteractionService(environment: environment)
            windows = [item(1, fullscreen: fullscreen, maximized: maximized)]
            check(handled(await service.toggle(for: app)), "protected window activation failed")
            check(calls.last?.1 == .activate, "fullscreen/maximized window was minimized")
            check(handled(await service.toggle(for: app)) && calls.last?.1 == .activate, "repeated protected click minimized")
        }

        service = WindowInteractionService(environment: environment)
        windows = [item(1)]
        nextOutcome = .unsupported
        if case .failure = await service.toggle(for: app) { check(true, "unsupported minimize") }
        else { check(false, "unsupported minimize was silently reported successful") }
        nextOutcome = .missing
        check(await service.toggle(for: app) == .targetUnavailable,
              "missing action target produced a global warning or application fallback")
        nextOutcome = .superseded
        check(handled(await service.toggle(for: app)), "superseded action became user error")
        nextOutcome = .performed
        windows = []
        check(await service.toggle(for: app) == .fallbackToApplication, "no-window application did not use native reopen fallback")

        // A second click arriving before the first native state change finishes
        // must read after it, rather than deciding against the same stale state.
        windows = [item(1)]
        calls = []
        actionDelay = 5_000_000
        service = WindowInteractionService(environment: environment)
        let current = service
        let clicks = (0..<6).map { _ in Task { @MainActor in await current.toggle(for: app) } }
        for click in clicks { check(handled(await click.value), "queued toggle failed") }
        check(calls.map(\.1) == [.minimize, .restore, .minimize, .restore, .minimize, .restore], "rapid clicks consumed stale state")
        check(windows[0].isMinimized == false, "even queued click count left window minimized")
        actionDelay = 0

        // Stop/preview selection must invalidate a delayed click before it can
        // apply a window mutation after the user chose a different target.
        readDelay = 20_000_000
        calls = []
        let readsBefore = reads
        let cancelled = Task { @MainActor in await current.toggle(for: app) }
        while reads == readsBefore { await Task.yield() }
        current.cancel()
        check(handled(await cancelled.value), "cancel result")
        check(calls.isEmpty, "cancelled read still mutated a window")
        readDelay = 0

        windows = [item(1), item(2, front: false)]
        service = WindowInteractionService(environment: environment)
        service.remember(WindowPreview(windowID: 2, pid: 123, title: "B", image: nil, frame: windows[1].frame,
            processLaunchDate: date, applicationPath: app.path), for: app)
        check((await service.list(for: app)).selectedID == windows[1].id, "preview choice not reflected in menu")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .activate,
              "preview-selected background B not activated")
        // Partial AX reads are unavailable inventories, not evidence of closure.
        // B must remain the target while A is still readable and focused.
        windows = [item(1), item(2, minimized: true, front: false)]
        let completeWindows = windows
        windows = [item(1)]
        readIssue = .unavailable
        let beforeIncomplete = calls.count
        check((await service.list(for: app)).items.isEmpty, "partial snapshot exposed incomplete menu")
        check(await service.toggle(for: app) == .targetUnavailable,
              "incomplete selected-window snapshot was not quietly rejected")
        check(calls.count == beforeIncomplete, "incomplete snapshot mutated another window")
        check(recoveries == [completeWindows[1].id], "incomplete snapshot did not retry the exact remembered window")
        recovered = true
        check(handled(await service.toggle(for: app)) && recoveries == Array(repeating:completeWindows[1].id, count:2),
              "a visible remembered window remained unreachable after a partial AX read")
        check(calls.count == beforeIncomplete, "recovering B from the window server acted on A")
        windows = completeWindows
        readIssue = nil
        check((await service.list(for: app)).selectedID?.windowID == 2, "incomplete snapshot lost remembered B")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .restore,
              "complete snapshot did not restore remembered B")
        readIssue = .permissionDenied
        check(await service.toggle(for: app) == .fallbackToApplication, "no-permission path lost native open fallback")
        readIssue = nil
        windows = []
        check((await service.list(for: app)).selectedID == nil, "complete empty inventory retained closed target")
        windows = [item(1), item(2, front: false)]
        check((await service.list(for: app)).selectedID?.windowID == 1,
              "complete empty inventory did not invalidate closed selection")
        await checkHostedBrowser(check)
        print("Window interaction: \(count) checks, \(failures.count) failures; injected native boundary only")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}

private extension WindowInteractionChecks {
    @MainActor static func checkHostedBrowser(_ check: @escaping (Bool, String) -> Void) async {
        typealias Router = WeChatBrowserWindowRouter
        let app = AppReference(id:"com.tencent.flue.WeChatAppEx", name:"Web",
                               path:"/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app")
        let host = AppReference(id:"com.tencent.xinWeChat", name:"WeChat", path:"/Applications/WeChat.app")
        let started = Date(timeIntervalSince1970:100)
        var pair = Router.Pair(icon:.init(pid:12,launched:started,path:app.path),
                               host:.init(pid:11,launched:started,path:host.path), hostApp:host)
        func item(_ n: CGWindowID, minimized: Bool = false, focused: Bool = false,
                  protected: Bool = false, fullscreen: Bool = false, title: String = "Fixture") -> DockWindowItem {
            DockWindowItem(id:.init(pid:11,processLaunchDate:started,applicationPath:host.path,windowID:n),
                           title:title, frame:CGRect(x:0,y:0,width:600,height:500), isMinimized:minimized,
                           isFullscreen:fullscreen, isMaximized:protected, isFrontmost:focused,
                           isFocused:focused, isMain:focused)
        }
        func observed(_ items:[DockWindowItem], _ visible:Set<CGWindowID>, _ exposed:Set<CGWindowID>,
                      _ front:pid_t, companion:Set<CGWindowID> = []) -> Router.Observation {
            .init(windows:items,visibleIDs:visible,exposedIDs:exposed,companionIDs:companion,frontPID:front)
        }
        let initial = observed([item(1,minimized:true),item(2,minimized:true)],[],[],50)
        let revealed = observed([item(1,minimized:true),item(2)],[2],[2],12)
        var current = initial
        var afterActivation = revealed
        var requests = 0
        var canPair = true
        let env = Router.Environment(pair:{ _ in canPair ? pair : nil },observe:{ _ in current },
                                     activate:{ _ in requests += 1; current = afterActivation; return true },pause:{})
        var mutations: [(CGWindowID, DockWindowAction)] = []
        var direct: [DockWindowItem] = []
        func service() -> WindowInteractionService {
            let router = Router(environment:env)
            return .init(environment:.init(read:{ _ in .available(direct) },perform:{ window,action,owner in
                let directTarget = direct.contains(where:{ $0.id == window.id })
                check(owner == (directTarget ? app : host), "Wrong action owner for browser window")
                if !directTarget { check(window.foregroundProxy == pair.icon, "Bound proxy incarnation lost") }
                mutations.append((window.id.windowID,action))
                if !directTarget {
                    current = current.windows.contains(where: { $0.id.windowID == 2 }) && action != .minimize ? revealed : initial
                }
                return .performed
            },browser:router))
        }
        func dismisses(_ result: WindowInteractionResult) -> Bool { result == .handled }
        check(Router.hostURL(for:app)?.path == host.path,"AppEx nesting not recognized")
        let icon2 = AppReference(id:"com.tencent.xinWeChat.WeChatHelper",name:"Proxy",
                                 path:host.path+"/Contents/MacOS/WeChatHelper.app")
        check(Router.hostURL(for:icon2)?.path == host.path,"WeChatHelper nesting not recognized")
        check(Router.hostURL(for:.init(id:app.id,name:"Wrong",path:"/Applications/WeChatAppEx.app")) == nil,
              "Standalone bundle treated as a proxy")
        check(Router.hostURL(for:.init(id:"com.tencent.flue.helper.renderer",name:"Worker",path:app.path)) == nil,
              "Renderer treated as the browser icon")
        var clicks=service()
        check(dismisses(await clicks.toggle(for:app)) && mutations.count == 1 && mutations.last?.1 == .activate && requests == 1,
              "The first helper click must bring its learned window forward, without minimizing")
        check(dismisses(await clicks.toggle(for:app)) && mutations.last?.0 == 2 && mutations.last?.1 == .minimize,
              "Proxy foreground with nil AX focus did not minimize the bound host page")
        check(dismisses(await clicks.toggle(for:app)) && mutations.last?.0 == 2 && mutations.last?.1 == .restore,
              "The minimized browser was not restored by its original proxy")
        check(mutations.allSatisfy { $0.0 == 2 } && requests == 1, "Browser cycle touched chat or reopened unrelated windows")
        for (zoom,full) in [(true,false),(false,true)] {
            current = observed([item(1,minimized:true),item(2,protected:zoom,fullscreen:full)],[2],[2],12)
            _ = await clicks.toggle(for:app)
            check(mutations.last?.1 == .activate,"Protected browser window was minimized")
        }

        // An already-visible but covered page can also be revealed without
        // changing AXMinimized. Seeing the same window still behind another
        // application never constitutes successful identification.
        clicks=service();mutations=[]
        current=observed([item(1,minimized:true),item(2)],[2],[],50)
        afterActivation=revealed
        _ = await clicks.toggle(for:app); _ = await clicks.toggle(for:app)
        check(mutations.count == 2 && mutations.first?.1 == .activate && mutations.last?.0 == 2 && mutations.last?.1 == .minimize,
              "An actual exposure change failed to establish the proxy's target")

        clicks=service();mutations=[];current=observed([item(1,focused:true),item(2,minimized:true)],[1],[1],11)
        afterActivation=observed([item(1,focused:true),item(2)],[1,2],[1],11)
        _ = await clicks.toggle(for:app)
        check(mutations.first?.0 == 2 && mutations.first?.1 == .activate,
              "Chat stole focus after the proxy restored the browser; the learned page was not raised")

        clicks=service();mutations=[]
        current=observed([item(1,minimized:true,title:"微信"), item(2,minimized:true)],[],[],50)
        afterActivation=observed([item(1,title:"微信"),item(2,minimized:true)],[1],[1],12)
        _ = await clicks.toggle(for:app);_ = await clicks.toggle(for:app)
        check(mutations.isEmpty, "A helper-side reopen was allowed to identify main chat by accident")

        // Cold-start with a page already in front: only a separate companion
        // surface and stable proxy foreground corroborate that exact host ID.
        clicks=service();mutations=[]
        current=observed([item(1,minimized:true),item(2)],[2],[2],12,companion:[2]);afterActivation=current
        _ = await clicks.toggle(for:app)
        check(mutations.count == 1 && mutations.last?.0 == 2 && mutations.last?.1 == .minimize,
              "A corroborated already-visible browser requires an extra click")

        clicks=service();mutations=[]
        current=observed([item(1,minimized:true),item(2,focused:true)],[2],[2],11,companion:[2]);afterActivation=current
        _ = await clicks.toggle(for:app)
        check(mutations.count == 1 && mutations.last?.0 == 2 && mutations.last?.1 == .minimize,
              "Awake browser whose host kept focus ignored the first click")

        clicks=service();mutations=[]
        current=observed([item(1),item(2)],[1,2],[1],12);afterActivation=current
        _ = await clicks.toggle(for:app);_ = await clicks.toggle(for:app)
        check(mutations.isEmpty,"Cold proxy guessed an arbitrary exposed chat window")
        let choices=await clicks.list(for:app)
        check(choices.isHostedChoice && choices.items.count == 2 && choices.selectedID == nil,
              "Ambiguous hosted windows were not explicitly selectable")
        check(dismisses(await clicks.select(choices.items[1],for:app)) && mutations.last?.0 == 2 && mutations.last?.1 == .activate,
              "Explicit hosted selection did not bring the chosen page forward")
        _ = await clicks.toggle(for:app)
        check(mutations.last?.0 == 2 && mutations.last?.1 == .minimize,"Explicit browser choice did not persist")

        // A change in proxy birth invalidates a cached mapping even for a reused PID.
        pair = .init(icon:.init(pid:12,launched:started.addingTimeInterval(1),path:app.path),host:pair.host,hostApp:host)
        let oldMenuSelection = await clicks.select(choices.items[1],for:app)
        check(oldMenuSelection == .targetUnavailable, "A stale helper menu bound a new proxy process")
        current=observed([item(1),item(2)],[1,2],[1],12);afterActivation=current;mutations=[]
        _ = await clicks.toggle(for:app)
        check(mutations.isEmpty, "Recycled proxy PID reused the previous window binding")
        canPair=false
        check(await clicks.toggle(for:app) == .fallbackToApplication && mutations.isEmpty,
              "An ambiguous or missing live process pair routed a host mutation")
        direct=[item(5,focused:true)]
        _ = await clicks.toggle(for:app)
        check(mutations.last?.0 == 5 && mutations.last?.1 == .minimize, "Own proxy window lost priority over host routing")

        clicks=service();mutations=[];direct=[];canPair=true;current=initial
        afterActivation=observed([item(1),item(2)],[1,2],[1],60)
        _ = await clicks.toggle(for:app)
        current=afterActivation;_ = await clicks.toggle(for:app)
        check(mutations.isEmpty, "Unrelated foreground change was claimed by the browser proxy")
    }
}
