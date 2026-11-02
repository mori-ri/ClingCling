import AppKit

/// 終了して起動し直す。表示言語は起動時にしか切り替わらない。
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        // 先に起動すると、新しいプロセスと今のプロセスが並んでしまう。
        // 切り離したシェルでこのプロセスの終了を待ってから起動する。
        let bundleURL = Bundle.main.bundleURL
        let launch = bundleURL.pathExtension == "app"
            ? "/usr/bin/open -n \(shellQuoted(bundleURL.path))"
            // `swift run` にはバンドルがないので、実行ファイルを直接起動する
            : "\(shellQuoted(Bundle.main.executablePath ?? CommandLine.arguments[0])) >/dev/null 2>&1 &"
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; \(launch)"]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
