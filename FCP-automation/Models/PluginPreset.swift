import Foundation

struct PluginPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var plugins: [PluginEntry]
    var isDefault: Bool

    // Motionテンプレート連携
    var titleTemplateName: String?      // テロップ用テンプレート表示名
    var titleTemplateUID: String?       // テロップ用FCPXML uid
    var effectTemplates: [MotionTemplateRef]  // エフェクトテンプレート群

    init(name: String, plugins: [PluginEntry] = [], isDefault: Bool = false,
         titleTemplateName: String? = nil, titleTemplateUID: String? = nil,
         effectTemplates: [MotionTemplateRef] = []) {
        self.id = UUID()
        self.name = name
        self.plugins = plugins
        self.isDefault = isDefault
        self.titleTemplateName = titleTemplateName
        self.titleTemplateUID = titleTemplateUID
        self.effectTemplates = effectTemplates
    }

    /// テロップテンプレートが設定されているか
    var hasCustomTitle: Bool {
        titleTemplateUID != nil && !(titleTemplateUID?.isEmpty ?? true)
    }
}

struct PluginEntry: Identifiable, Codable {
    let id: UUID
    var effectID: String
    var effectName: String
    var effectUID: String
    var category: PluginCategory
    var parameters: [PluginParameter]

    init(effectID: String, effectName: String, effectUID: String = "", category: PluginCategory, parameters: [PluginParameter] = []) {
        self.id = UUID()
        self.effectID = effectID
        self.effectName = effectName
        self.effectUID = effectUID
        self.category = category
        self.parameters = parameters
    }

    enum PluginCategory: String, Codable, CaseIterable {
        case videoFilter = "ビデオフィルタ"
        case audioFilter = "オーディオフィルタ"
        case transition = "トランジション"
        case title = "タイトル"
        case generator = "ジェネレータ"
    }
}

struct PluginParameter: Identifiable, Codable {
    let id: UUID
    var key: String
    var value: String

    init(key: String, value: String) {
        self.id = UUID()
        self.key = key
        self.value = value
    }
}
