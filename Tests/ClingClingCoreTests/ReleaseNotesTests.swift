import Foundation
import Testing

@testable import ClingClingCore

@Suite struct ReleaseNotesTests {
    @Test func keepsHeadingsParagraphsAndLists() {
        let body = """
            ファイルを履歴に残せるようになったリリースです。

            ## 新機能

            - **ファイル**: Finder でのコピーを残します
              - 種類のアイコンを出します
            1. 番号付き
            """
        #expect(
            ReleaseNotes.blocks(from: body) == [
                .paragraph("ファイルを履歴に残せるようになったリリースです。"),
                .heading("新機能"),
                .item(marker: "•", text: "**ファイル**: Finder でのコピーを残します", level: 0),
                .item(marker: "•", text: "種類のアイコンを出します", level: 1),
                .item(marker: "1.", text: "番号付き", level: 0),
            ])
    }

    @Test func dropsWhatOnlyBelongsOnTheReleasePage() {
        let body = """
            ## 修正

            - 直しました

            ## インストール

            1. 下の zip をダウンロードします

            ### 補足

            ```sh
            git clone https://github.com/
            ```

            **Full Changelog**: https://github.com/mori-ri/ClingCling/compare/v0.6.0...v0.7.0
            """
        #expect(ReleaseNotes.blocks(from: body) == [.heading("修正"), .item(marker: "•", text: "直しました", level: 0)])
    }

    @Test func aSkippedSectionEndsAtTheNextHeadingOfItsLevel() {
        let body = "## Installation\nstep\n## 変更\n- 変えました\n<!-- note -->\n---"
        #expect(ReleaseNotes.blocks(from: body) == [.heading("変更"), .item(marker: "•", text: "変えました", level: 0)])
    }

    @Test func joinsLinesOfAParagraphAndQuotes() {
        let body = "1 行目\r\n2 行目\n\n> 引用"
        #expect(ReleaseNotes.blocks(from: body) == [.paragraph("1 行目\n2 行目"), .paragraph("引用")])
    }

    @Test func onlyHTTPSLinksStayClickable() {
        let text = ReleaseNotes.inline("[サイト](https://example.com) と [ファイル](file:///etc/hosts) **太字**")
        let links = text.runs.compactMap { $0.link }
        #expect(links == [URL(string: "https://example.com")!])
        #expect(String(text.characters) == "サイト と ファイル 太字")
    }
}
