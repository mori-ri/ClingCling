import Combine
import Foundation

/// `0.6.0` や `v0.6.0-beta.1` のようなリリースのバージョン。それ以外の形は受け付けないので、
/// ネットワークから来た文字がそのまま画面に出ることはない。プレリリースは同じ番号のリリースより前に並ぶ
/// （プレリリース同士は順位を付けない）。
public struct AppVersion: Comparable, Sendable {
    public let text: String
    private let numbers: [Int]
    private let isPrerelease: Bool

    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count),
              fields.allSatisfy({ field in (1...6).contains(field.count) && field.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        if parts.count > 1 {
            let suffix = parts[1]
            guard !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
            else { return nil }
        }
        let numbers = fields.compactMap { Int($0) }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        isPrerelease = parts.count > 1
        text = trimmed
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.isPrerelease == rhs.isPrerelease
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.numbers == rhs.numbers
            ? lhs.isPrerelease && !rhs.isPrerelease : lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
    }
}

/// GitHub の API が返すリリース
public struct PublishedRelease: Decodable, Sendable {
    public var tagName: String
    public var body: String?
    public var publishedAt: Date?
    public var prerelease: Bool
    public var draft: Bool

    public init(
        tagName: String, body: String? = nil, publishedAt: Date? = nil, prerelease: Bool = false, draft: Bool = false
    ) {
        self.tagName = tagName
        self.body = body
        self.publishedAt = publishedAt
        self.prerelease = prerelease
        self.draft = draft
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case publishedAt = "published_at"
        case prerelease
        case draft
    }
}

/// GitHub に公開済みのリリースを問い合わせ、最新がこのビルドより新しいかを覚え、お知らせのページ用に
/// リリースノートを持つ。インストールはしない（ダウンロードはブラウザで最新リリースのページを開く）。
///
/// 送るのはリリース一覧の問い合わせだけで、履歴やコピーした内容には触れない。
@MainActor
public final class UpdateChecker: ObservableObject {
    /// リポジトリのリリースを新しい順に返す
    public typealias FetchReleases = @Sendable () async throws -> [PublishedRelease]

    /// 知らせる新しいバージョン
    @Published public private(set) var availableVersion: String?
    /// 正式なリリースを新しい順に。お知らせのページ用
    @Published public private(set) var notes: [ReleaseNote] = []
    @Published public private(set) var isLoading = false
    /// 直前の問い合わせに失敗したか。お知らせのページで再試行を出すため
    @Published public private(set) var loadFailed = false
    /// このビルドのバージョン。`swift run` では nil
    public let currentVersion: AppVersion?

    /// お知らせのページに出すリリースの数
    static let noteLimit = 5
    private static let interval: Duration = .seconds(24 * 60 * 60)
    /// ログイン時の起動はネットワークより先に動くことが多いので、失敗したら早めに再試行する
    private static let retryInterval: Duration = .seconds(60 * 60)

    private let isEnabled: @MainActor () -> Bool
    private let fetchReleases: FetchReleases
    private var task: Task<Void, Never>?

    public init(
        currentVersion: String?, isEnabled: @escaping @MainActor () -> Bool, fetchReleases: @escaping FetchReleases
    ) {
        self.currentVersion = currentVersion.flatMap(AppVersion.init)
        self.isEnabled = isEnabled
        self.fetchReleases = fetchReleases
    }

    /// 今すぐ確認し、起動している間は 1 日に 1 回確認する
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let succeeded = await self?.check() else { return }
                try? await Task.sleep(for: succeeded ? Self.interval : Self.retryInterval)
            }
        }
    }

    /// 確認できなかったら false を返す。設定がオフなら問い合わせず、出していた知らせも消す。
    @discardableResult
    public func check() async -> Bool {
        guard isEnabled(), currentVersion != nil else {
            availableVersion = nil
            return true
        }
        guard let releases = await fetch() else { return false }
        apply(releases)
        return true
    }

    /// お知らせのページ用にノートを読み込む。`check` と違って設定がオフでも問い合わせるので、
    /// ユーザーが頼んだときだけ呼ぶ。新しいバージョンの知らせは設定に従う。
    public func loadNotes() async {
        guard let releases = await fetch() else { return }
        apply(releases)
    }

    /// 最新のノートが、お知らせのページで最後に見たものより新しいか。
    /// ページを一度も開いていなければ未読とする（お知らせのない版から更新した人にも気づいてもらうため）。
    public func hasUnreadNotes(lastSeen: String?) -> Bool {
        guard let newest = notes.first?.version else { return false }
        guard let seen = lastSeen.flatMap(AppVersion.init) else { return true }
        return newest > seen
    }

    private func fetch() async -> [PublishedRelease]? {
        isLoading = true
        defer { isLoading = false }
        do {
            let releases = try await fetchReleases()
            loadFailed = false
            return releases
        } catch {
            loadFailed = true
            NSLog("ClingCling: update check failed")
            return nil
        }
    }

    private func apply(_ releases: [PublishedRelease]) {
        notes = Self.notes(from: releases)
        // 問い合わせている間に設定がオフにされたかもしれない
        guard isEnabled(), let currentVersion, let newest = notes.first?.version, newest > currentVersion else {
            availableVersion = nil
            return
        }
        availableVersion = newest.text
    }

    /// タグがバージョンの形をした正式なリリースを新しい順に。下書きとプレリリースは除く
    /// （GitHub の「最新のリリース」も除くので、ダウンロードの行き先と揃う）。
    static func notes(from releases: [PublishedRelease]) -> [ReleaseNote] {
        let notes = releases.filter { !$0.draft && !$0.prerelease }.compactMap { release -> ReleaseNote? in
            guard let version = AppVersion(release.tagName) else { return nil }
            let blocks = ReleaseNotes.blocks(from: release.body ?? "")
            return ReleaseNote(version: version, publishedAt: release.publishedAt, blocks: blocks)
        }
        return Array(notes.sorted { $0.version > $1.version }.prefix(noteLimit))
    }

    /// `url`（GitHub のリリース一覧の API）を読む関数を返す。Cookie もキャッシュも残さない。
    nonisolated public static func releasesFetcher(url: URL) -> FetchReleases {
        { @Sendable in
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ClingCling", forHTTPHeaderField: "User-Agent")
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([PublishedRelease].self, from: data)
        }
    }
}
