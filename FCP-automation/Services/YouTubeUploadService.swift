import Foundation
import AppKit

/// YouTube Data API v3 を使用した動画アップロード（Resumable Upload）
class YouTubeUploadService {

    enum UploadError: LocalizedError {
        case notAuthenticated
        case initiateFailed(String)
        case uploadFailed(String)
        case thumbnailFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "YouTube認証が必要です。設定画面で認証してください。"
            case .initiateFailed(let reason): return "アップロード開始失敗: \(reason)"
            case .uploadFailed(let reason): return "アップロード失敗: \(reason)"
            case .thumbnailFailed(let reason): return "サムネイルアップロード失敗: \(reason)"
            }
        }
    }

    private let oauth = GoogleOAuthService()
    private let chunkSize = 5 * 1024 * 1024  // 5MB chunks

    /// 動画をYouTubeにアップロード
    /// - Returns: アップロードされた動画のVideo ID
    func uploadVideo(
        fileURL: URL,
        metadata: YouTubeUploadMetadata,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let accessToken = try await oauth.getValidAccessToken()

        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            throw UploadError.uploadFailed("ファイルサイズが0です")
        }

        // Step 1: Resumable Upload を開始
        print("[YouTubeUpload] アップロード開始: \(fileURL.lastPathComponent) (\(fileSize / 1024 / 1024)MB)")
        let uploadURI = try await initiateResumableUpload(
            metadata: metadata,
            fileSize: fileSize,
            accessToken: accessToken
        )

        // Step 2: チャンク転送
        let videoId = try await uploadFileInChunks(
            fileURL: fileURL,
            uploadURI: uploadURI,
            fileSize: fileSize,
            progressCallback: progressCallback
        )

        print("[YouTubeUpload] アップロード完了: videoId=\(videoId)")
        return videoId
    }

    /// サムネイルをアップロード
    func uploadThumbnail(videoId: String, image: NSImage) async throws {
        let accessToken = try await oauth.getValidAccessToken()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw UploadError.thumbnailFailed("画像データの変換に失敗")
        }

        guard let encodedId = videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=\(encodedId)") else {
            throw UploadError.thumbnailFailed("無効なVideo ID")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("\(pngData.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = pngData

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UploadError.thumbnailFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        print("[YouTubeUpload] サムネイルアップロード完了")
    }

    // MARK: - Resumable Upload

    private func initiateResumableUpload(metadata: YouTubeUploadMetadata, fileSize: Int64, accessToken: String) async throws -> URL {
        guard let url = URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status") else {
            throw UploadError.initiateFailed("URLの構築に失敗")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")

        let body = metadata.apiJSON()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.initiateFailed("レスポンスなし")
        }

        guard (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw UploadError.initiateFailed("HTTP \(http.statusCode): \(String(errBody.prefix(300)))")
        }

        guard let locationStr = http.value(forHTTPHeaderField: "Location"),
              let uploadURI = URL(string: locationStr) else {
            throw UploadError.initiateFailed("Upload URIが見つかりません")
        }

        return uploadURI
    }

    private func uploadFileInChunks(
        fileURL: URL,
        uploadURI: URL,
        fileSize: Int64,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset: Int64 = 0

        while offset < fileSize {
            let currentChunkSize = min(Int64(chunkSize), fileSize - offset)

            fileHandle.seek(toFileOffset: UInt64(offset))
            let chunkData = fileHandle.readData(ofLength: Int(currentChunkSize))

            let endByte = offset + Int64(chunkData.count) - 1

            var request = URLRequest(url: uploadURI)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(endByte)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            request.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")
            request.httpBody = chunkData
            request.timeoutInterval = 300

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.uploadFailed("レスポンスなし")
            }

            if http.statusCode == 308 {
                // Resume Incomplete — 次のチャンクへ
                if let rangeHeader = http.value(forHTTPHeaderField: "Range"),
                   let lastByte = rangeHeader.split(separator: "-").last,
                   let lastByteNum = Int64(lastByte) {
                    offset = lastByteNum + 1
                } else {
                    offset += Int64(chunkData.count)
                }
            } else if (200...201).contains(http.statusCode) {
                // アップロード完了
                offset = fileSize

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let videoId = json["id"] as? String {
                    await MainActor.run { progressCallback(1.0) }
                    return videoId
                }
                throw UploadError.uploadFailed("Video IDが見つかりません")
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? "unknown"
                throw UploadError.uploadFailed("HTTP \(http.statusCode): \(String(errBody.prefix(300)))")
            }

            await MainActor.run {
                progressCallback(Double(offset) / Double(fileSize))
            }
        }

        throw UploadError.uploadFailed("アップロードが正常に完了しませんでした")
    }
}
