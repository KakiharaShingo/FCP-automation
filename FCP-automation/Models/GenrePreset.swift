import Foundation

struct GenrePreset: Identifiable, Codable, Hashable {
    let id: String  // "talk", "vlog", "product", "action", "tutorial"
    let name: String
    let icon: String
    let description: String

    // 編集パラメータ
    let silencePadding: TimeInterval      // カット点周辺に残す無音の余白(秒)
    let minSectionDuration: TimeInterval  // これより短いセクションは結合対象
    let maxSectionDuration: TimeInterval  // これより長いセクションは分割検討
    let cutAggressiveness: Double         // 0.0(全残し) - 1.0(積極カット)
    let keepAtmosphericShots: Bool        // 雰囲気ショットを残すか

    // AI指示用
    let editingGuidance: String           // ストーリー分析プロンプトに渡すジャンル固有指示

    // MARK: - Built-in Presets

    static let talk = GenrePreset(
        id: "talk",
        name: "トーク・解説",
        icon: "person.wave.2",
        description: "トーク動画、解説、ポッドキャスト",
        silencePadding: 0.1,
        minSectionDuration: 3.0,
        maxSectionDuration: 180.0,
        cutAggressiveness: 0.8,
        keepAtmosphericShots: false,
        editingGuidance: """
        トーク・解説動画の編集ルール:
        - 無音・フィラー・言い淀みは積極的にカット（テンポ重視）
        - リテイク（言い直し）は古い方を必ずカット
        - 脱線トークは30秒以上続く場合のみカット（短い脱線は味になる）
        - 話の要点が伝わる最小限の長さに編集する
        - 間（ま）は0.3秒以上あれば詰める
        """
    )

    static let vlog = GenrePreset(
        id: "vlog",
        name: "VLOG",
        icon: "video.badge.waveform",
        description: "日常VLOG、旅行、お出かけ",
        silencePadding: 0.3,
        minSectionDuration: 2.0,
        maxSectionDuration: 120.0,
        cutAggressiveness: 0.5,
        keepAtmosphericShots: true,
        editingGuidance: """
        VLOG編集ルール:
        - 雰囲気を伝えるショット（景色、食事、移動中）は短くても残す
        - テキストがなくても映像として良いシーンは残す
        - 無言の間も1-2秒程度なら雰囲気として残す（全カットしない）
        - 時系列の流れを維持する（並べ替えは最小限に）
        - 繰り返しの移動シーンや準備シーンはカット
        - 冒頭は印象的なシーンから始める（フック）
        """
    )

    static let productReview = GenrePreset(
        id: "product",
        name: "商品紹介・レビュー",
        icon: "shippingbox",
        description: "開封、商品レビュー、比較",
        silencePadding: 0.2,
        minSectionDuration: 5.0,
        maxSectionDuration: 240.0,
        cutAggressiveness: 0.4,
        keepAtmosphericShots: false,
        editingGuidance: """
        商品紹介・レビュー編集ルール:
        - 商品の説明・スペック・使用感は絶対に残す
        - 開封シーンは短縮してもカットはしない
        - 比較部分は全て残す（視聴者が最も求める情報）
        - 脱線は短くカット（商品と無関係な話題）
        - 結論・おすすめポイントは必ず残す
        - 構成: 導入→開封/外観→機能説明→使用感→メリデメ→結論の流れを維持
        """
    )

    static let action = GenrePreset(
        id: "action",
        name: "アクション・スポーツ",
        icon: "figure.run",
        description: "レース、スポーツ、アウトドア",
        silencePadding: 0.05,
        minSectionDuration: 1.0,
        maxSectionDuration: 60.0,
        cutAggressiveness: 0.6,
        keepAtmosphericShots: true,
        editingGuidance: """
        アクション・スポーツ動画編集ルール:
        - テキスト（発言）より映像の動きと音が重要
        - 発言がない区間でもアクションがあれば残す
        - ハイライト（盛り上がり）部分を優先的に残す
        - 準備・待機シーンは大幅にカット
        - テンポは速め、1シーン最大30-60秒
        - 解説・実況がある場合はそのセクションは残す
        - 同じアングルの繰り返しは最良のテイクだけ残す
        """
    )

    static let tutorial = GenrePreset(
        id: "tutorial",
        name: "チュートリアル・How-to",
        icon: "book",
        description: "手順説明、教育、ハウツー",
        silencePadding: 0.2,
        minSectionDuration: 5.0,
        maxSectionDuration: 300.0,
        cutAggressiveness: 0.3,
        keepAtmosphericShots: false,
        editingGuidance: """
        チュートリアル編集ルール:
        - 手順の説明は一切カットしない（情報の欠落は致命的）
        - ミステイクや言い直しのみカット
        - 長い沈黙（作業中の無言）は短縮するが完全除去しない
        - ステップの順序は絶対に変えない
        - 補足説明や豆知識は残す
        - 構成: 完成形プレビュー→材料/準備→手順1→手順2→...→完成→まとめ
        """
    )

    /// 全ビルトインプリセット
    static let allPresets: [GenrePreset] = [.talk, .vlog, .productReview, .action, .tutorial]
}
