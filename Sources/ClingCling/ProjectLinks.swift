import AppKit

/// アプリから開く GitHub のページ。フィードバックは Discussions に集める
/// （質問や要望を不具合の報告の形に書かなくて済むように）。
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/mori-ri/ClingCling")!
    static let newFeedback = URL(string: "https://github.com/mori-ri/ClingCling/discussions/new?category=general")!
    static let sponsors = URL(string: "https://github.com/sponsors/mori-ri")!
    /// `bundle.sh` が同梱するライセンス。`swift run` では無い。
    static var license: URL? { Bundle.main.url(forResource: "LICENSE", withExtension: "txt") }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
