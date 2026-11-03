import Foundation
import Testing
@testable import ClingClingCore

struct ExportFileTests {
    func item(_ type: ContentType, content: String = "x", retention: Retention = .normal,
              image: ClipImage? = nil) -> ClipItem {
        ClipItem(createdAt: Date(), content: content, contentHash: "h", contentType: type,
                 source: .unknown, sensitivity: .normal, retention: retention,
                 externalAllowed: true, expiresAt: nil, reasons: [], image: image)
    }

    @Test func temporaryItemsAreNotExported() {
        #expect(ExportFile.canExport(item(.text)))
        #expect(ExportFile.canExport(item(.text, retention: .pinned)))
        #expect(!ExportFile.canExport(item(.credential, retention: .temporary)))
        #expect(!ExportFile.canExport(item(.verificationCode, retention: .temporary)))
    }

    @Test func extensionFollowsContentType() {
        #expect(ExportFile.fileExtension(for: item(.text)) == "txt")
        #expect(ExportFile.fileExtension(for: item(.code)) == "txt")
        #expect(ExportFile.fileExtension(for: item(.json)) == "json")
        let image = item(.image, image: ClipImage(fileName: "h.png", width: 2, height: 2))
        #expect(ExportFile.fileExtension(for: image) == "png")
    }

    @Test func baseNameIsSortableAndHasNoColons() {
        let date = Date(timeIntervalSince1970: 1_793_698_865) // 2026-11-03 09:41:05 UTC
        let name = ExportFile.baseName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "ClingCling 2026-11-03 09.41.05")
    }

    @Test func uniqueURLNumbersCollisions() {
        let folder = URL(fileURLWithPath: "/tmp/exports")
        let taken: Set<String> = ["a.txt", "a 2.txt"]
        let url = ExportFile.uniqueURL(in: folder, baseName: "a", fileExtension: "txt") {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "a 3.txt")
        let free = ExportFile.uniqueURL(in: folder, baseName: "b", fileExtension: "json") { _ in false }
        #expect(free.lastPathComponent == "b.json")
    }

    @Test func textDataIsUTF8AndImagesHaveNone() {
        #expect(ExportFile.textData(for: item(.text, content: "こんにちは\n")) == Data("こんにちは\n".utf8))
        let image = item(.image, image: ClipImage(fileName: "h.png", width: 2, height: 2))
        #expect(ExportFile.textData(for: image) == nil)
    }
}
