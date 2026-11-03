import Foundation

/// ローカルの利用統計
public protocol ActionStatsProvider {
    /// (content_type, source_app) ごとの action 選択回数
    func actionCounts(contentType: ContentType, sourceKey: String?) -> [SmartAction: Int]
}

/// Smart Action の候補生成と順位付け
public struct ActionRanker {
    public static let maxVisible = 3

    public init() {}

    /// 分類・コピー元アプリから見た「既定の推奨順」
    public static func baseCandidates(for type: ContentType, source: SourceApp) -> [SmartAction] {
        switch type {
        case .url: return [.open, .markdown, .copy]
        case .error: return [.explain, .search, .copy]
        case .command: return [.copy, .run, .explain]
        case .text: return [.copy, .polish, .shorten, .translate]
        case .email:
            return source.bundleID == "com.apple.mail" ? [.newMail, .copy] : [.copy, .newMail]
        case .address: return [.copy, .openMaps]
        case .json: return [.copy, .format, .inspect]
        case .code: return [.copy, .explain]
        case .image: return [.copy, .pasteText, .saveImage]
        case .credential, .verificationCode, .other: return [.copy]
        }
    }

    /// 表示する Action（最大 3 つ、左端が最も推奨）
    public func rank(_ item: ClipItem, stats: ActionStatsProvider?) -> [SmartAction] {
        var candidates = Self.baseCandidates(for: item.contentType, source: item.source)
        // 文字が写っていない画像には、テキストで貼り付ける操作を出さない
        if item.recognizedText == nil {
            candidates.removeAll { $0 == .pasteText }
        }
        if !item.externalAllowed {
            candidates.removeAll(where: \.sendsContentExternally)
        }
        if !candidates.contains(.copy) { candidates.append(.copy) }

        guard let stats else { return Array(candidates.prefix(Self.maxVisible)) }

        let appCounts = stats.actionCounts(contentType: item.contentType, sourceKey: item.source.statsKey)
        let typeCounts = stats.actionCounts(contentType: item.contentType, sourceKey: nil)
        let scores = Self.scores(candidates: candidates, appCounts: appCounts, typeCounts: typeCounts)

        return candidates.enumerated()
            .sorted { lhs, rhs in
                let l = scores[lhs.element] ?? 0, r = scores[rhs.element] ?? 0
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)
            .prefix(Self.maxVisible)
            .map { $0 }
    }

    /// 既定順の事前スコア + 利用履歴によるブースト。
    /// 同じアプリでの履歴を強く、分類全体での履歴を弱く効かせる。
    /// 少数回の選択で順位が暴れないよう、総数 5 回までは影響を線形に弱める。
    static func scores(
        candidates: [SmartAction],
        appCounts: [SmartAction: Int],
        typeCounts: [SmartAction: Int]
    ) -> [SmartAction: Double] {
        func shares(_ counts: [SmartAction: Int]) -> (total: Int, share: (SmartAction) -> Double) {
            let total = candidates.reduce(0) { $0 + (counts[$1] ?? 0) }
            return (total, { total == 0 ? 0 : Double(counts[$0] ?? 0) / Double(total) })
        }
        let app = shares(appCounts)
        let type = shares(typeCounts)
        let appWeight = 1.0 * min(Double(app.total), 5) / 5
        let typeWeight = 0.5 * min(Double(type.total), 5) / 5

        var result: [SmartAction: Double] = [:]
        for (index, action) in candidates.enumerated() {
            let prior = 1.0 - Double(index) * 0.25
            result[action] = prior + appWeight * app.share(action) * 1.5 + typeWeight * type.share(action) * 1.5
        }
        return result
    }
}
