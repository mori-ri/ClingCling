import Foundation

/// 履歴の Item をファイルに書き出すときの決まりごと（名前・拡張子・中身）
public enum ExportFile {
    /// ファイルに保存できる Item か。
    /// ディスクに書かないと判断した一時 Item（Secret・認証コード）は、ファイルにも書かない。
    public static func canExport(_ item: ClipItem) -> Bool {
        !item.isTemporary
    }

    /// 拡張子。画像は PNG、JSON は `.json`、それ以外のテキストは `.txt`
    public static func fileExtension(for item: ClipItem) -> String {
        if item.isImage { return "png" }
        return item.contentType == .json ? "json" : "txt"
    }

    /// 拡張子を除いたファイル名（「ClingCling 2026-11-03 09.41.05」）。
    /// Finder で日付順に並び、`:` を含まないようにする。
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "ClingCling \(formatter.string(from: date))"
    }

    /// `folder` の中で既存のファイルと重ならない保存先。重なれば「… 2」「… 3」と番号を付ける。
    public static func uniqueURL(
        in folder: URL,
        baseName: String,
        fileExtension: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return url
    }

    /// テキスト Item の中身（UTF-8）。画像 Item の本文はラベルなので、画像には使わない。
    public static func textData(for item: ClipItem) -> Data {
        Data(item.content.utf8)
    }
}
