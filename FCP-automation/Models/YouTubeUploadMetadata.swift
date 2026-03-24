import Foundation
import AppKit

struct YouTubeUploadMetadata {
    var title: String
    var description: String
    var tags: [String]
    var categoryId: String = "22"  // 22 = People & Blogs
    var privacyStatus: PrivacyStatus = .private

    var thumbnailImage: NSImage?

    enum PrivacyStatus: String, CaseIterable {
        case `public` = "public"
        case unlisted = "unlisted"
        case `private` = "private"

        var displayName: String {
            switch self {
            case .public: return "公開"
            case .unlisted: return "限定公開"
            case .private: return "非公開"
            }
        }

        var icon: String {
            switch self {
            case .public: return "globe"
            case .unlisted: return "link"
            case .private: return "lock"
            }
        }
    }

    static let categoryOptions: [(id: String, name: String)] = [
        ("1", "映画とアニメ"),
        ("2", "自動車と乗り物"),
        ("10", "音楽"),
        ("15", "ペットと動物"),
        ("17", "スポーツ"),
        ("20", "ゲーム"),
        ("22", "ブログ"),
        ("23", "コメディ"),
        ("24", "エンターテインメント"),
        ("25", "ニュースと政治"),
        ("26", "ハウツーとスタイル"),
        ("27", "教育"),
        ("28", "科学と技術"),
    ]

    /// YouTubeMetadataから変換
    init(from metadata: YouTubeMetadata, privacyStatus: PrivacyStatus = .private, categoryId: String = "22") {
        self.title = metadata.title
        // チャプター付き概要欄テキスト
        self.description = metadata.fullDescriptionText
        self.tags = metadata.tags
        self.categoryId = categoryId
        self.privacyStatus = privacyStatus
    }

    init(title: String, description: String, tags: [String] = []) {
        self.title = title
        self.description = description
        self.tags = tags
    }

    /// YouTube API用のJSON body
    func apiJSON() -> [String: Any] {
        [
            "snippet": [
                "title": title,
                "description": description,
                "tags": tags,
                "categoryId": categoryId
            ],
            "status": [
                "privacyStatus": privacyStatus.rawValue
            ]
        ]
    }
}
