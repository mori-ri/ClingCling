import SwiftUI

// 設定ページの部品。grouped な `Form` はセクションの半透明の塗りを変えられず、
// ガラスの背景の上で文字のコントラストが落ちるので、カードを自前で組む。

/// `SettingsSection` を縦に並べるスクロール領域
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }
}

/// 見出しと説明が付いたカード
struct SettingsSection<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            // 各行は上端に区切り線を引く。1pt 上へずらして先頭の線だけをカードの外へ隠す
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// カードの中の 1 行
struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Theme.separator.frame(height: 1).padding(.leading, 14)
            }
    }
}

/// 左にラベル、右に操作部品
struct LabeledRow<Control: View>: View {
    let title: Text
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.init(Text(title), control: control)
    }

    init(_ title: Text, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        SettingsRow {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 12)
                control
            }
        }
    }
}

struct ToggleRow: View {
    let title: Text
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = Text(title)
        self._isOn = isOn
    }

    var body: some View {
        LabeledRow(title) {
            Toggle(isOn: $isOn) { title }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct PickerRow<Selection: Hashable, Options: View>: View {
    let title: Text
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.init(verbatim: Text(title), selection: selection, options: options)
    }

    /// アプリ名など、翻訳しない文字列をラベルにする
    @_disfavoredOverload
    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.init(verbatim: Text(verbatim: title), selection: selection, options: options)
    }

    private init(verbatim title: Text, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledRow(title) {
            Picker(selection: $selection) {
                options
            } label: {
                title
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// カードの中の小さな補足
struct NoteRow: View {
    let text: Text
    var color: Color? = nil

    init(_ text: LocalizedStringKey, color: Color? = nil) {
        self.text = Text(text)
        self.color = color
    }

    /// エラーの文面など、翻訳済みの文字列を出す
    @_disfavoredOverload
    init(_ text: String, color: Color? = nil) {
        self.text = Text(verbatim: text)
        self.color = color
    }

    var body: some View {
        SettingsRow {
            text
                .font(.caption)
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 折りたたんだ編集欄の中の 1 項目
struct EditorField<Control: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
