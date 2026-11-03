import Foundation
import Testing
@testable import ClingClingCore

struct FileKindTests {
    @Test(arguments: [
        ("/Users/me/Documents/", FileKind.folder),
        ("/Users/me/Releases/v1.2/", .folder),
        ("/Applications/Safari.app/", .application),
        ("/Users/me/Desktop/Screenshot 2026-11-03.PNG", .image),
        ("/Users/me/Downloads/invoice.pdf", .pdf),
        ("/Users/me/notes.md", .text),
        ("/Users/me/src/main.swift", .code),
        ("/Users/me/deploy.command", .script),
        ("/Users/me/setup.sh", .script),
        ("/Users/me/Automator/Rename.workflow/", .script),
        ("/Users/me/Report.pages/", .document),
        ("/Users/me/Report.docx", .document),
        ("/Users/me/Budget.xlsx", .spreadsheet),
        ("/Users/me/Talk.key/", .presentation),
        ("/Users/me/backup.tar.gz", .archive),
        ("/Users/me/Downloads/App.dmg", .diskImage),
        ("/Users/me/Downloads/Tool.pkg", .installer),
        ("/Users/me/song.m4a", .audio),
        ("/Users/me/clip.mov", .video),
        ("/Users/me/Makefile", .other),
        // フォルダ名に「.txt」が付いていても、パッケージでなければフォルダ
        ("/Users/me/old.txt/", .folder),
    ])
    func classifies(_ path: String, _ expected: FileKind) {
        #expect(FileKind.classify(path: path) == expected)
    }

    @Test func combinesKinds() {
        #expect(FileKind.of(paths: ["/a.pdf", "/b.PDF"]) == .pdf)
        #expect(FileKind.of(paths: ["/a.pdf", "/b/"]) == .mixed)
        #expect(FileKind.of(paths: []) == .other)
    }

    @Test func launchesCode() {
        #expect(FileKind.application.launchesCode)
        #expect(FileKind.installer.launchesCode)
        #expect(FileKind.script.launchesCode)
        #expect(!FileKind.pdf.launchesCode)
        #expect(!FileKind.folder.launchesCode)
    }

    @Test func pathsForDisplayAndCopy() {
        #expect(CopiedFiles.displayName(of: "/Users/me/Documents/") == "Documents")
        #expect(CopiedFiles.displayName(of: "/Users/me/a.pdf") == "a.pdf")
        #expect(CopiedFiles.displayName(of: "/") == "/")
        #expect(CopiedFiles.plainPath("/Users/me/Documents/") == "/Users/me/Documents")
        #expect(CopiedFiles.plainPath("/") == "/")
    }

    @Test func temporaryLocations() {
        #expect(CopiedFiles.isTemporaryLocation("/private/var/folders/xy/T/image.png"))
        #expect(CopiedFiles.isTemporaryLocation("/tmp/a.txt"))
        #expect(!CopiedFiles.isTemporaryLocation("/Users/me/tmp/a.txt"))
    }
}

struct FileCaptureTests {
    let gate = PrivacyGate()
    let finder = SourceApp(bundleID: "com.apple.finder", name: "Finder")

    func capture(_ paths: [String], types: Set<String> = ["public.file-url"], source: SourceApp? = nil,
                 settings: PrivacySettings = PrivacySettings()) -> GateDecision {
        gate.evaluate(CaptureInput(filePaths: paths, pasteboardTypes: types, source: source ?? finder), settings: settings)
    }

    @Test func keepsPathsAsLocalOnlyFileItem() throws {
        guard case .capture(let item) = capture(["/Users/me/a.pdf", "/Users/me/Photos/"]) else {
            Issue.record("expected capture")
            return
        }
        #expect(item.contentType == .file)
        #expect(item.filePaths == ["/Users/me/a.pdf", "/Users/me/Photos/"])
        #expect(item.fileKind == .mixed)
        #expect(item.externalAllowed == false)
        #expect(item.retention == .normal)
        #expect(item.sensitivity == .normal)
    }

    // パスを文字としてコピーした Item とは、重複排除で混ざらない
    @Test func hashDiffersFromSameText() throws {
        guard case .capture(let file) = capture(["/Users/me/a.pdf"]),
              case .capture(let text) = gate.evaluate(
                CaptureInput(text: "/Users/me/a.pdf", pasteboardTypes: [], source: finder), settings: PrivacySettings())
        else {
            Issue.record("expected capture")
            return
        }
        #expect(file.contentHash != text.contentHash)
    }

    @Test func respectsMarkersAndPolicies() {
        #expect(capture(["/a.pdf"], types: ["public.file-url", PrivacyGate.concealedType]) == .drop(reason: "concealed pasteboard marker"))
        var settings = PrivacySettings()
        settings.appPolicies = ["com.apple.finder": .neverCapture]
        #expect(capture(["/a.pdf"], settings: settings) == .drop(reason: "app policy: never capture"))
    }

    @Test func dropsEmptyAndUnrepresentablePaths() {
        #expect(capture([]) == .drop(reason: "empty"))
        #expect(capture(["/a\nb.pdf"]) == .drop(reason: "empty"))
        #expect(capture(Array(repeating: "/a.pdf", count: CopiedFiles.maxCount + 1)) == .drop(reason: "empty"))
    }
}

struct FileActionTests {
    let ranker = ActionRanker()

    func item(_ paths: [String]) -> ClipItem {
        let content = paths.joined(separator: "\n")
        return ClipItem(createdAt: Date(), content: content, contentHash: ContentHash.sha256(content), contentType: .file,
                        source: .unknown, sensitivity: .normal, retention: .normal, externalAllowed: false,
                        expiresAt: nil, reasons: [])
    }

    @Test func actionsFollowFileKind() {
        #expect(ranker.rank(item(["/Users/me/Projects/"]), stats: nil) == [.openFile, .openInTerminal, .copyPath])
        #expect(ranker.rank(item(["/Users/me/notes.md"]), stats: nil) == [.copyContents, .openFile, .revealInFinder])
        #expect(ranker.rank(item(["/Users/me/deploy.command"]), stats: nil) == [.copyContents, .revealInFinder, .copyPath])
        #expect(ranker.rank(item(["/Applications/Safari.app/"]), stats: nil) == [.openFile, .revealInFinder, .copyPath])
        #expect(ranker.rank(item(["/Users/me/a.pdf"]), stats: nil) == [.openFile, .revealInFinder, .copyPath])
        // 複数のファイルの中身はまとめてコピーしない
        #expect(ranker.rank(item(["/a.md", "/b.md"]), stats: nil) == [.openFile, .revealInFinder, .copyPath])
        #expect(ranker.rank(item(["/a/", "/b/"]), stats: nil) == [.openFile, .revealInFinder, .copyPath])
    }

    // 貼り付けはメニューの先頭に常にあるので、Smart Action の枠に入れない
    @Test func pasteDoesNotTakeASlot() {
        #expect(!ranker.rank(item(["/a.pdf"]), stats: nil).contains(.copy))
    }

    @Test func confirmsBeforeLaunchingCodeOrOpeningMany() {
        #expect(SmartAction.openFile.needsConfirmation(for: "/Applications/Safari.app/"))
        #expect(SmartAction.openFile.needsConfirmation(for: "/Users/me/a.pdf\n/Users/me/deploy.command"))
        #expect(!SmartAction.openFile.needsConfirmation(for: "/Users/me/a.pdf"))
        #expect(!SmartAction.openFile.needsConfirmation(for: "/Users/me/Projects/"))
        let many = (0...FileKind.maxOpenWithoutConfirmation).map { "/Users/me/\($0).pdf" }.joined(separator: "\n")
        #expect(SmartAction.openFile.needsConfirmation(for: many))
        #expect(!SmartAction.revealInFinder.needsConfirmation(for: "/Applications/Safari.app/"))
    }

    @Test func rowShowsFileNames() {
        let detector = SecretDetector()
        #expect(item(["/Users/me/Projects/"]).rowText(detector: detector) == "Projects")
        #expect(item(["/Users/me/a.pdf", "/Users/me/b.pdf", "/Users/me/c.pdf"]).rowText(detector: detector) == "a.pdf ほか 2 件")
    }

    @Test func fileItemsAreNotExported() {
        #expect(!ExportFile.canExport(item(["/Users/me/a.pdf"])))
    }

    @Test func nonFileItemsHaveNoPaths() {
        let text = ClipItem(createdAt: Date(), content: "/Users/me/a.pdf", contentHash: "h", contentType: .text,
                            source: .unknown, sensitivity: .normal, retention: .normal, externalAllowed: true,
                            expiresAt: nil, reasons: [])
        #expect(text.filePaths.isEmpty)
        #expect(text.fileKind == nil)
    }
}
