import AppKit

/// アプリから開く GitHub のページ。フィードバックは Discussions に集める
/// （質問や要望を不具合の報告の形に書かなくて済むように）。
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/mori-ri/ClingCling")!
    static let newFeedback = URL(string: "https://github.com/mori-ri/ClingCling/discussions/new?category=general")!
    static let sponsors = URL(string: "https://github.com/sponsors/mori-ri")!
    static let releases = URL(string: "https://github.com/mori-ri/ClingCling/releases")!
    /// 最新のリリースのページ。zip は CPU ごとに名前が違うので、ファイルではなくページを開く。
    /// ブラウザでダウンロードするので隔離属性が付き、Gatekeeper が確かめる。
    static let latestRelease = URL(string: "https://github.com/mori-ri/ClingCling/releases/latest")!
    /// 新しいバージョンの確認とお知らせ（`UpdateChecker`）が読むリリースの一覧
    static let releasesAPI = URL(string: "https://api.github.com/repos/mori-ri/ClingCling/releases?per_page=10")!
    /// `bundle.sh` が同梱するライセンス。`swift run` では無い。
    static var license: URL? { Bundle.main.url(forResource: "LICENSE", withExtension: "txt") }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
