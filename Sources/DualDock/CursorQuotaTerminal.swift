import Darwin
import Foundation

/// Launch a private terminal session. A partial slash command is completed only
/// by accepting a matching built-in in the client's own command palette.
enum CursorQuotaTerminal {
    static func read(source: CursorQuotaSource, binary: URL, arguments: [String],
                     environment: [String: String], workspace: URL, deadline: TimeInterval) throws -> AIQuotaSnapshot {
        var master: Int32 = -1, slave: Int32 = -1
        var device = [CChar](repeating: 0, count: 1024)
        var size = winsize(ws_row: 40, ws_col: 112, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, &device, nil, &size) == 0 else { throw AIQuotaError.unavailable }
        defer { close(master); close(slave) }
        var attributes: posix_spawnattr_t?, files: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw AIQuotaError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&files) == 0 else { throw AIQuotaError.unavailable }
        defer { posix_spawn_file_actions_destroy(&files) }
        let chdir: Int32
        if #available(macOS 26.0, *) { chdir = posix_spawn_file_actions_addchdir(&files, workspace.path) }
        else { chdir = posix_spawn_file_actions_addchdir_np(&files, workspace.path) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              chdir == 0,
              posix_spawn_file_actions_addopen(&files, STDIN_FILENO, &device, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&files, STDIN_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&files, STDIN_FILENO, STDERR_FILENO) == 0 else { throw AIQuotaError.unavailable }
        var argv = ([binary.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, binary.path, &files, &attributes, &argv, &envp) == 0 else { throw AIQuotaError.unavailable }
        // SETSID gives the child its own process group. The PID is not reaped
        // until cleanup, preventing reuse while signalling its descendants.
        defer {
            kill(-pid, SIGHUP)
            kill(-pid, SIGTERM)
            usleep(45_000)
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        let flags = fcntl(master, F_GETFL)
        guard flags != -1, fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1 else { throw AIQuotaError.unavailable }
        var screen = CursorQuotaScreen()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var consumed = 0
        var partialSent = false, accepted = false, dirty = false
        var typedShow = false, selectedShow = false
        var lastPaint = ProcessInfo.processInfo.systemUptime
        let start = lastPaint
        func input(_ string: String) throws {
            let raw = Array(string.utf8)
            guard Darwin.write(master, raw, raw.count) == raw.count else { throw AIQuotaError.unavailable }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            var child = siginfo_t()
            if waitid(P_PID, id_t(pid), &child, WEXITED | WNOHANG | WNOWAIT) == 0, child.si_pid == pid { throw AIQuotaError.unavailable }
            var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&poller, 1, 70)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw AIQuotaError.unavailable }
            let now = ProcessInfo.processInfo.systemUptime
            if ready > 0 {
                let count = Darwin.read(master, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw AIQuotaError.unavailable }
                consumed += count
                guard consumed <= 2_097_152 else { throw AIQuotaError.invalid }
                for byte in bytes.prefix(count) {
                    if let response = screen.consume(byte) { try input(response) }
                }
                lastPaint = now
                dirty = true
            }
            guard dirty, now - lastPaint >= 0.08 || ready > 0 else { continue }
            let view = screen.text
            let lower = view.lowercased()
            if ["not logged in", "please log in", "sign in with grok", "sign in to grok", "authenticate with cursor", "authentication required",
                "log in or sign up", "login to cursor", "sign in to continue", "choose a login method"].contains(where: lower.contains) { throw AIQuotaError.signIn }
            if ["failed to load usage", "usage details are not available", "spend details are not available",
                "personal spend for the current billing period"].contains(where: lower.contains) { throw AIQuotaError.unavailable }
            if accepted {
                let report = source == .cursorCLI ? CursorQuotaReport.legacy(view, now: Date()) : CursorQuotaReport.sharedScreen(view, now: Date())
                if let report, now - lastPaint >= 0.12 { return report }
                // For consumer Grok accounts accepting /usage may first open a
                // submenu containing "show" and "manage". Select only "show".
                if source == .xSubscription && !selectedShow && lower.contains("/usage") && lower.contains("view usage") {
                    if !typedShow && lower.contains("manage billing") {
                        try input("show")
                        typedShow = true
                    } else if typedShow && lower.contains("/usage show") {
                        try input("\r")
                        selectedShow = true
                    }
                }
            } else if partialSent {
                // No arbitrary prompt is ever submitted. Pressing Return while
                // the typed prefix is incomplete selects the verified native completion.
                let menu = source == .cursorCLI
                    ? lower.contains("show plan and on-demand usage")
                    : lower.range(of: #"/?usage[^\n]*(?:usage limit|usage information|usage stats|usage details|usage and|show usage|view.*usage|current usage|session usage)"#, options: .regularExpression) != nil
                if menu && lower.contains("/usag") { try input("\r"); accepted = true }
            } else if now - start >= 0.3,
                      ["plan, search, build anything", "add a follow-up", "type a message", "type / for commands",
                       "ask about this codebase", "chat about your code", "plan to review and build"].contains(where: lower.contains),
                      !["connecting…", "trust this", "trust the files", "trust the contents", "press enter to sign",
                        "open a browser", "choose how"].contains(where: lower.contains) {
                try input("/usag")
                partialSent = true
            }
            dirty = !partialSent || accepted
        }
        throw AIQuotaError.timeout
    }
}

/// Small bounded VT display for the quota page. Preserve line/column position
/// when a TUI repaints in place. Ignore styling and terminal hyperlinks.
private struct CursorQuotaScreen {
    private let width = 112, height = 40
    private var cells = Array(repeating: Array(repeating: Character(" "), count: 112), count: 40)
    private var row = 0, col = 0, saved = (0, 0)
    private enum State { case text, escape, csi, string, stringEscape }
    private var state = State.text
    private var parameters = ""
    private var utf8: [UInt8] = []
    var text: String { cells.map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }

    mutating func consume(_ b: UInt8) -> String? {
        switch state {
        case .text:
            switch b {
            case 27: state = .escape; utf8.removeAll()
            case 10: newline()
            case 13: col = 0
            case 8: col = max(0, col - 1)
            case 9: col = min(width - 1, (col / 8 + 1) * 8)
            case 32...126: paint(Character(UnicodeScalar(b)))
            case 128...255:
                if b >= 192 { utf8.removeAll(keepingCapacity: true) }
                utf8.append(b)
                if let symbol = String(bytes: utf8, encoding: .utf8)?.first { paint(symbol); utf8.removeAll(keepingCapacity: true) }
                if utf8.count >= 4 { utf8.removeAll(keepingCapacity: true) }
            default: break
            }
        case .escape:
            state = .text
            switch b {
            case 91: state = .csi; parameters = ""
            case 93, 80: state = .string
            case 55: saved = (row, col)
            case 56: (row, col) = saved
            default: break
            }
        case .string:
            if b == 7 { state = .text } else if b == 27 { state = .stringEscape }
        case .stringEscape:
            state = b == 92 ? .text : .string
        case .csi:
            if (64...126).contains(b) {
                state = .text
                return csi(b)
            }
            if parameters.utf8.count < 40 { parameters += String(UnicodeScalar(b)) }
        }
        return nil
    }

    private mutating func newline() {
        if row == height - 1 { cells.removeFirst(); cells.append(Array(repeating: " ", count: width)) }
        else { row += 1 }
    }

    private mutating func paint(_ symbol: Character) {
        if col >= width { newline(); col = 0 }
        cells[row][col] = symbol
        col += 1
    }

    private mutating func csi(_ op: UInt8) -> String? {
        let args = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let n = max(1, args.first ?? 1)
        switch op {
        case 65: row = max(0, row - min(height,n))
        case 66: row = min(height-1, row + min(height,n))
        case 67: col = min(width-1, col + min(width,n))
        case 68: col = max(0, col - min(width,n))
        case 69: row = min(height-1, row + min(height,n)); col = 0
        case 70: row = max(0, row - min(height,n)); col = 0
        case 71: col = min(width,n) - 1
        case 72, 102: row = min(height,n) - 1; col = min(width,max(1,args.dropFirst().first ?? 1)) - 1
        case 74:
            if [2,3].contains(args.first ?? 0) { cells = Array(repeating: Array(repeating: " ", count: width), count: height) }
            else if (args.first ?? 0) == 0 {
                for r in row..<height { for c in (r == row ? min(col,width) : 0)..<width { cells[r][c] = " " } }
            }
        case 75:
            let mode = args.first ?? 0
            let from = mode == 0 ? min(width,col) : 0, to = mode == 1 ? min(width,col+1) : width
            for c in from..<to { cells[row][c] = " " }
        case 110: if n == 6 { return "\u{1b}[\(row+1);\(min(width,col+1))R" }
        default: break
        }
        return nil
    }
}
