import SwiftUI
import AppKit

struct SubtitleStyle {
    var fontName: String = "Hiragino Sans"
    var fontSize: CGFloat = 16
    var fontWeight: Font.Weight = .semibold
    var textColor: Color = .white
    var backgroundColor: Color = .black
    var backgroundOpacity: Double = 0.6
    var verticalPosition: SubtitlePosition = .bottom
    var horizontalPadding: CGFloat = 20
    var verticalPadding: CGFloat = 12

    // 縁取り（ストローク）設定
    var strokeEnabled: Bool = true
    var strokeColor: Color = .black
    var strokeWidth: CGFloat = 2.0

    enum SubtitlePosition: String, CaseIterable {
        case top = "上"
        case center = "中央"
        case bottom = "下"
    }

    /// システム + ユーザー + Adobe フォントを動的に取得
    static var availableFonts: [(name: String, display: String)] {
        let manager = NSFontManager.shared
        let allFamilies = manager.availableFontFamilies

        // 日本語で使いやすいフォントを優先表示
        let priorityFonts: [String] = [
            "Hiragino Sans", "Hiragino Mincho ProN", "Hiragino Maru Gothic ProN",
            "Noto Sans CJK JP", "Noto Serif CJK JP",
            "YuGothic", "YuMincho",
            "Bebas Neue", "Montserrat", "D-DIN",
            "Helvetica Neue", "SF Pro", "SF Pro Display", "SF Pro Rounded",
            "Menlo", "Courier New",
        ]

        var result: [(name: String, display: String)] = []

        // 優先フォントを先に追加
        for font in priorityFonts {
            if allFamilies.contains(font) {
                result.append((name: font, display: font))
            }
        }

        // 区切り
        let priorityNames = Set(priorityFonts)

        // 残りのフォントをアルファベット順で追加（日本語・ユーザーフォント含む）
        let others = allFamilies
            .filter { !priorityNames.contains($0) && !$0.hasPrefix(".") }
            .sorted()
        for font in others {
            result.append((name: font, display: font))
        }

        return result
    }

    /// FCPXML用のfontColorを生成（R G B A スペース区切り）
    var fcpxmlFontColor: String {
        let nsColor = NSColor(textColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.4f %.4f %.4f 1", r, g, b)
    }

    /// FCPXML用のフォントサイズ（FCP内のタイトルは大きめ）
    var fcpxmlFontSize: Int {
        Int(fontSize * 3)
    }

    /// FCPXML用のstrokeColorを生成（R G B A スペース区切り）
    var fcpxmlStrokeColor: String {
        let nsColor = NSColor(strokeColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.4f %.4f %.4f 1", r, g, b)
    }
}
