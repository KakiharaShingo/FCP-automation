import Foundation
import AppKit

// MARK: - Motion Template Model

struct MotionTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String               // "基本01_01"
    let packName: String           // "MP_テロップパック"
    let category: String           // "01_基本"
    let templateType: TemplateType
    let fcpxmlUID: String          // ".../Titles.localized/MP_テロップパック/01_基本/基本01_01/基本01_01.moti"
    let thumbnailPath: String?     // large.png の絶対パス
    let fileExtension: String      // "moti" or "moef"

    init(name: String, packName: String, category: String, templateType: TemplateType,
         fcpxmlUID: String, thumbnailPath: String? = nil, fileExtension: String = "moti") {
        self.id = UUID()
        self.name = name
        self.packName = packName
        self.category = category
        self.templateType = templateType
        self.fcpxmlUID = fcpxmlUID
        self.thumbnailPath = thumbnailPath
        self.fileExtension = fileExtension
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MotionTemplate, rhs: MotionTemplate) -> Bool {
        lhs.id == rhs.id
    }
}

enum TemplateType: String, Codable, CaseIterable {
    case title = "タイトル"
    case effect = "エフェクト"
}

/// テロップ/エフェクトへの参照（プリセット保存用）
struct MotionTemplateRef: Identifiable, Codable {
    let id: UUID
    var templateName: String
    var fcpxmlUID: String
    var templateType: TemplateType

    init(templateName: String, fcpxmlUID: String, templateType: TemplateType) {
        self.id = UUID()
        self.templateName = templateName
        self.fcpxmlUID = fcpxmlUID
        self.templateType = templateType
    }

    init(from template: MotionTemplate) {
        self.id = UUID()
        self.templateName = template.name
        self.fcpxmlUID = template.fcpxmlUID
        self.templateType = template.templateType
    }
}

// MARK: - Scanner

class MotionTemplateScanner {

    static let shared = MotionTemplateScanner()

    /// ~/Movies/Motion Templates.localized/
    private var motionTemplatesBase: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Movies/Motion Templates.localized")
    }

    /// MP_系パック名フィルタ（対象パック）
    private let targetPackPrefixes = ["MP_", "マップアニメーション"]

    // MARK: - Public API

    /// 全パック（Titles + Effects）をスキャン
    func scanAllPacks() -> [MotionTemplate] {
        var templates: [MotionTemplate] = []
        templates.append(contentsOf: scanTitlePacks())
        templates.append(contentsOf: scanEffectPacks())
        return templates
    }

    /// Titles.localized 内のMP_系パックをスキャン
    func scanTitlePacks() -> [MotionTemplate] {
        let titlesDir = motionTemplatesBase.appendingPathComponent("Titles.localized")
        return scanDirectory(titlesDir, templateType: .title)
    }

    /// Effects.localized 内のMP_系パックをスキャン
    func scanEffectPacks() -> [MotionTemplate] {
        let effectsDir = motionTemplatesBase.appendingPathComponent("Effects.localized")
        return scanDirectory(effectsDir, templateType: .effect)
    }

    /// パック名一覧を取得
    func availablePacks(type: TemplateType) -> [String] {
        let dir: URL
        switch type {
        case .title:
            dir = motionTemplatesBase.appendingPathComponent("Titles.localized")
        case .effect:
            dir = motionTemplatesBase.appendingPathComponent("Effects.localized")
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.hasDirectoryPath && isTargetPack($0.lastPathComponent) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// カテゴリ一覧を取得
    func categories(pack: String, type: TemplateType) -> [String] {
        let typeDir = (type == .title) ? "Titles.localized" : "Effects.localized"
        let packDir = motionTemplatesBase
            .appendingPathComponent(typeDir)
            .appendingPathComponent(pack)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: packDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// サムネイル画像を読み込み
    func loadThumbnail(for template: MotionTemplate) -> NSImage? {
        guard let path = template.thumbnailPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    // MARK: - Private

    private func isTargetPack(_ name: String) -> Bool {
        targetPackPrefixes.contains { name.hasPrefix($0) }
    }

    private func scanDirectory(_ baseDir: URL, templateType: TemplateType) -> [MotionTemplate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir.path) else { return [] }

        var templates: [MotionTemplate] = []

        // パック単位でスキャン
        guard let packs = try? fm.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        for packURL in packs where packURL.hasDirectoryPath && isTargetPack(packURL.lastPathComponent) {
            let packName = packURL.lastPathComponent

            // カテゴリ or 直下テンプレート
            guard let categories = try? fm.contentsOfDirectory(
                at: packURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for catURL in categories where catURL.hasDirectoryPath {
                let catName = catURL.lastPathComponent

                // カテゴリ内のテンプレートを探索
                guard let items = try? fm.contentsOfDirectory(
                    at: catURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }

                for itemURL in items where itemURL.hasDirectoryPath {
                    // テンプレートファイルを検索（.moti / .moef）
                    if let templateFile = findTemplateFile(in: itemURL) {
                        let thumbnail = findThumbnail(in: itemURL)
                        let uid = buildFCPXMLUID(
                            templateType: templateType,
                            packName: packName,
                            category: catName,
                            templateDir: itemURL.lastPathComponent,
                            fileName: templateFile.lastPathComponent
                        )
                        let template = MotionTemplate(
                            name: itemURL.lastPathComponent,
                            packName: packName,
                            category: catName,
                            templateType: templateType,
                            fcpxmlUID: uid,
                            thumbnailPath: thumbnail?.path,
                            fileExtension: templateFile.pathExtension
                        )
                        templates.append(template)
                    }
                }

                // カテゴリ自体がテンプレートフォルダの場合もチェック
                if let templateFile = findTemplateFile(in: catURL) {
                    let thumbnail = findThumbnail(in: catURL)
                    let uid = buildFCPXMLUID(
                        templateType: templateType,
                        packName: packName,
                        category: "",
                        templateDir: catName,
                        fileName: templateFile.lastPathComponent
                    )
                    let template = MotionTemplate(
                        name: catName,
                        packName: packName,
                        category: packName,
                        templateType: templateType,
                        fcpxmlUID: uid,
                        thumbnailPath: thumbnail?.path,
                        fileExtension: templateFile.pathExtension
                    )
                    templates.append(template)
                }
            }
        }

        return templates
    }

    private func findTemplateFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        return files.first { $0.pathExtension == "moti" || $0.pathExtension == "moef" }
    }

    private func findThumbnail(in directory: URL) -> URL? {
        let largePng = directory.appendingPathComponent("large.png")
        let smallPng = directory.appendingPathComponent("small.png")
        let fm = FileManager.default

        if fm.fileExists(atPath: largePng.path) { return largePng }
        if fm.fileExists(atPath: smallPng.path) { return smallPng }
        return nil
    }

    /// FCPXML uid を生成
    /// 形式: .../Titles.localized/パック名/カテゴリ/テンプレートフォルダ/テンプレート名.moti
    private func buildFCPXMLUID(
        templateType: TemplateType,
        packName: String,
        category: String,
        templateDir: String,
        fileName: String
    ) -> String {
        let typeDir = (templateType == .title) ? "Titles.localized" : "Effects.localized"
        if category.isEmpty {
            return ".../\(typeDir)/\(packName)/\(templateDir)/\(fileName)"
        }
        return ".../\(typeDir)/\(packName)/\(category)/\(templateDir)/\(fileName)"
    }
}
