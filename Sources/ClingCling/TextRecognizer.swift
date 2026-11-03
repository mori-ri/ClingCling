import CoreGraphics
import Vision

/// 画像に写っている文字を Vision で読み取る（OCR）。
/// 読み取りはこの Mac の中だけで行い、画像も文字も外に出さない。
enum TextRecognizer {
    /// 読み取りに使う言語（優先順）。UI と同じく日本語と英語
    private static let preferredLanguages = ["ja-JP", "en-US"]

    /// 読み取った文字を、Vision が返した順（上から下）に 1 行ずつ改行でつないで返す。
    /// 文字が無い・読み取れないときは空文字。時間がかかることがあるのでメインスレッドでは呼ばない。
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        // 日本語は accurate でしか読めない
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = preferredLanguages.filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // 読み取れなかった画像は、文字の無い画像と同じく扱う（内容の推測につながるので詳細は残さない）
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
