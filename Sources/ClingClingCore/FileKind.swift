import Foundation

/// Finder などでコピーしたファイルの種類。Action の候補と一覧のアイコンを決める。
///
/// 判定には拡張子と、フォルダかどうか（パスの末尾の `/`）だけを使う。ファイルの中身は読まない。
/// `.app` や `.pages` のようなパッケージはフォルダだが、Finder と同じく 1 つのファイルとして扱う。
public enum FileKind: String, Sendable, CaseIterable {
    case folder
    case application
    case image
    case pdf
    /// プレーンテキスト・Markdown・CSV など
    case text
    /// ソースコード・設定ファイル
    case code
    /// Word・Pages・RTF など
    case document
    case spreadsheet
    case presentation
    case archive
    case diskImage
    case installer
    /// 開くとそのまま実行されることがあるもの（`.command`、`.sh` など）
    case script
    case audio
    case video
    case other
    /// 種類の違う複数のファイル
    case mixed

    /// この件数を超えるファイルをまとめて開くときは確認する
    public static let maxOpenWithoutConfirmation = 10

    /// 1 つのパスの種類。フォルダのパスは末尾が `/`（`ClipItem.filePaths` の決まり）。
    public static func classify(path: String) -> FileKind {
        let isDirectory = path.hasSuffix("/")
        let trimmed = isDirectory ? String(path.dropLast()) : path
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if isDirectory {
            // 「v1.2」のようなフォルダ名を拡張子と取り違えないよう、パッケージの拡張子だけを見る
            return packageExtensions[ext] ?? .folder
        }
        return fileExtensions[ext] ?? .other
    }

    /// 複数のパスの種類。すべて同じならその種類、違えば `mixed`。
    public static func of(paths: [String]) -> FileKind {
        let kinds = Set(paths.map(classify(path:)))
        guard let first = kinds.first else { return .other }
        return kinds.count == 1 ? first : .mixed
    }

    /// 開くとアプリの起動・インストール・スクリプトの実行につながる
    public var launchesCode: Bool {
        switch self {
        case .application, .installer, .script: true
        default: false
        }
    }

    /// 中身をテキストとしてコピーできる
    public var isTextual: Bool {
        switch self {
        case .text, .code, .script: true
        default: false
        }
    }

    // MARK: - Extensions

    private static let packageExtensions: [String: FileKind] = [
        "app": .application,
        "pages": .document, "rtfd": .document,
        "numbers": .spreadsheet,
        "key": .presentation,
        "pkg": .installer, "mpkg": .installer,
        "sparsebundle": .diskImage,
        "workflow": .script,
    ]

    private static let fileExtensions: [String: FileKind] = {
        let groups: [(FileKind, [String])] = [
            (.image, ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "ico", "icns",
                      "psd", "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf"]),
            (.pdf, ["pdf"]),
            (.text, ["txt", "text", "md", "markdown", "csv", "tsv", "log"]),
            (.code, ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "scala", "go", "rs",
                     "py", "rb", "php", "pl", "lua", "r", "dart", "ex", "exs", "hs", "ml", "zig", "js", "mjs", "cjs",
                     "ts", "tsx", "jsx", "vue", "svelte", "html", "htm", "css", "scss", "sass", "less", "sql", "json",
                     "yaml", "yml", "toml", "xml", "plist", "ini", "conf", "gradle", "graphql", "proto", "env"]),
            (.script, ["command", "tool", "sh", "zsh", "bash", "fish", "terminal"]),
            (.document, ["doc", "docx", "pages", "rtf", "odt", "epub"]),
            (.spreadsheet, ["xls", "xlsx", "numbers", "ods"]),
            (.presentation, ["ppt", "pptx", "key", "odp"]),
            (.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]),
            (.diskImage, ["dmg", "iso", "sparseimage"]),
            (.installer, ["pkg", "mpkg"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf"]),
            (.video, ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        ]
        var map: [String: FileKind] = [:]
        for (kind, extensions) in groups {
            for ext in extensions { map[ext] = kind }
        }
        return map
    }()
}

/// コピーしたファイルの扱いの決まりごと
public enum CopiedFiles {
    /// これより多いファイルをまとめてコピーしたときはキャプチャしない
    public static let maxCount = 200

    /// 中身をテキストとしてコピーする上限
    public static let maxTextBytes = 1_000_000

    /// アプリが受け渡しのために一時ディレクトリへ書き出したファイルか。
    /// 画像や本文と一緒に載ることがあり、ファイルはすぐ消えるので、履歴にはファイルではなく本文や画像を残す。
    public static func isTemporaryLocation(_ path: String) -> Bool {
        ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains { path.hasPrefix($0) }
    }

    /// 画面に出す名前（フォルダの末尾の `/` は付けない）
    public static func displayName(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    /// 「パスをコピー」で書き出すパス。Finder の「パス名をコピー」と同じく、フォルダの末尾に `/` を付けない。
    public static func plainPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension ClipItem {
    public var isFile: Bool { contentType == .file }

    /// ファイル Item のパス（1 行に 1 つ。フォルダは末尾が `/`）。ファイル以外では空。
    public var filePaths: [String] {
        guard isFile else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// ファイル Item の種類。ファイル以外では nil。
    public var fileKind: FileKind? {
        isFile ? FileKind.of(paths: filePaths) : nil
    }
}
