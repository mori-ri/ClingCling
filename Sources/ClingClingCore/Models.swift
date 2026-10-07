import Foundation

/// Clipboard Item の内容分類（仕様 §7）
public enum ContentType: String, Codable, CaseIterable, Sendable {
    case text
    case url
    case code
    case command
    case error
    case email
    case address
    case json
    case credential
    case verificationCode = "verification_code"
    /// 画像（スクリーンショットなど）。中身を検査できないので常に Local only
    case image
    case other
}

/// 機密度。`normal` 以外は外部送信不可（Fail Closed）。
public enum Sensitivity: String, Codable, Sendable, Comparable {
    /// 既知の Secret は検出されず、外部送信の候補になり得る
    case normal
    /// メールアドレス・電話番号・住所などの個人情報
    case personal
    /// 高エントロピー文字列など「安全と断定できない」もの
    case suspicious
    /// 既知形式の Secret / Credential / OTP
    case secret

    private var rank: Int {
        switch self {
        case .normal: 0
        case .personal: 1
        case .suspicious: 2
        case .secret: 3
        }
    }

    public static func < (lhs: Sensitivity, rhs: Sensitivity) -> Bool { lhs.rank < rhs.rank }
}

/// 保存期間（仕様 §36 の最小構成）
public enum Retention: String, Codable, Sendable {
    /// メモリ上のみ・一定時間で自動削除（ディスクには書かない）
    case temporary
    case normal
    case pinned
}

/// アプリ単位のキャプチャポリシー（仕様 §33 Applications）
public enum AppCapturePolicy: String, Codable, CaseIterable, Sendable {
    case capture
    case neverCapture
    case localOnly
}

public struct SourceApp: Hashable, Codable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    public static let unknown = SourceApp(bundleID: nil, name: nil)

    /// 統計のキー。bundle ID が無ければ名前、それも無ければ "unknown"
    public var statsKey: String { bundleID ?? name ?? "unknown" }
}

/// 画像 Item のメタデータ。画像本体は ClipStore が DB とは別のファイルに保存する。
public struct ClipImage: Hashable, Codable, Sendable {
    /// 保存先ディレクトリ内のファイル名（`<content hash>.png`）
    public var fileName: String
    public var width: Int
    public var height: Int

    public init(fileName: String, width: Int, height: Int) {
        self.fileName = fileName
        self.width = width
        self.height = height
    }
}

public struct ClipItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var lastCopiedAt: Date
    /// 本文。画像 Item では一覧・検索用のラベル（「画像 1280×720」）
    public var content: String
    public var contentHash: String
    public var contentType: ContentType
    public var source: SourceApp
    public var sensitivity: Sensitivity
    public var retention: Retention
    public var copyCount: Int
    public var externalAllowed: Bool
    public var expiresAt: Date?
    /// Privacy Gate が付与した判定理由（UI 表示・デバッグ用）
    public var reasons: [String]
    /// 画像 Item のときだけ値がある
    public var image: ClipImage?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        lastCopiedAt: Date? = nil,
        content: String,
        contentHash: String,
        contentType: ContentType,
        source: SourceApp,
        sensitivity: Sensitivity,
        retention: Retention,
        copyCount: Int = 1,
        externalAllowed: Bool,
        expiresAt: Date?,
        reasons: [String],
        image: ClipImage? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.content = content
        self.contentHash = contentHash
        self.contentType = contentType
        self.source = source
        self.sensitivity = sensitivity
        self.retention = retention
        self.copyCount = copyCount
        self.externalAllowed = externalAllowed
        self.expiresAt = expiresAt
        self.reasons = reasons
        self.image = image
    }

    public var isPinned: Bool { retention == .pinned }
    public var isTemporary: Bool { retention == .temporary }
    public var isLocalOnly: Bool { !externalAllowed }
    public var isImage: Bool { image != nil }
}
