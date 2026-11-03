import Foundation

/// 新しいバージョンを自動で確認するかを、一度だけ聞くための記録。
/// 許可なく通信しないよう確認は既定でオフにしてあり、最初の起動はアクセシビリティの許可などで
/// 忙しいので、2 回目の起動で聞く。
public struct UpdateCheckPrompt {
    static let launchCountKey = "launchCount"
    static let askedKey = "askedAboutUpdateChecks"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var hasAsked: Bool { defaults.bool(forKey: Self.askedKey) }

    /// 聞いたことにする（設定で自分で選んだときも呼ぶ）
    public func markAsked() {
        defaults.set(true, forKey: Self.askedKey)
    }

    /// 起動を数え、今回の起動で聞くなら true を返して、聞いたことにする
    public func registerLaunch() -> Bool {
        guard !hasAsked else { return false }
        let launches = defaults.integer(forKey: Self.launchCountKey) + 1
        defaults.set(launches, forKey: Self.launchCountKey)
        guard launches >= 2 else { return false }
        markAsked()
        return true
    }
}
