import Foundation

struct ProjectSettings: Codable {
    var framerate: Double = 30.0
    var width: Int = 1920
    var height: Int = 1080

    // 無音検出設定
    var silenceThresholdDB: Float = -40.0
    var minimumSilenceDuration: TimeInterval = 0.5

    // フィラーワード設定
    var fillerWords: [String] = [
        "えー", "えーと", "えーっと",
        "あー", "あーっ", "あのー", "あの",
        "うーん", "うん", "うー",
        "まあ", "まぁ",
        "そのー", "その",
        "なんか", "こう",
        "ちょっと"
    ]
    var fillerWordPaddingMs: Int = 100

    // ユーザー辞書（AI校正用）
    // よく使う単語・固有名詞を登録しておくと、AI校正時に参照して正確に変換する
    var userDictionary: [String] = []

    // FCPXML設定
    var fcpxmlVersion: String = "1.11"
    var projectName: String = "FCP-automation Project"

    // 出力設定
    var outputDirectory: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

    static let `default` = ProjectSettings()
}
