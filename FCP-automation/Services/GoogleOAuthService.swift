import Foundation
import Network
import AppKit
import CryptoKit

/// Google OAuth 2.0 PKCE フロー（macOSデスクトップアプリ用、ループバックリダイレクト）
class GoogleOAuthService {

    enum OAuthError: LocalizedError {
        case noClientID
        case authorizationFailed(String)
        case tokenExchangeFailed(String)
        case refreshFailed(String)
        case serverStartFailed
        case timeout

        var errorDescription: String? {
            switch self {
            case .noClientID: return "Google OAuth Client IDが設定されていません。設定画面で入力してください。"
            case .authorizationFailed(let reason): return "認証失敗: \(reason)"
            case .tokenExchangeFailed(let reason): return "トークン取得失敗: \(reason)"
            case .refreshFailed(let reason): return "トークン更新失敗: \(reason)"
            case .serverStartFailed: return "ローカルサーバーの起動に失敗しました"
            case .timeout: return "認証がタイムアウトしました（5分以内にブラウザで認証を完了してください）"
            }
        }
    }

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube"

    /// OAuth認証フローを開始（ブラウザで認証→ローカルサーバーでコールバック受信）
    func authorize() async throws {
        guard let clientID = GoogleOAuthConfig.loadClientID() else {
            throw OAuthError.noClientID
        }

        // PKCE生成
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // ローカルHTTPサーバー起動
        let (port, authCode) = try await startLocalServerAndWaitForCallback()

        let redirectURI = "http://127.0.0.1:\(port)/callback"

        // 認証URLをブラウザで開く
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else {
            throw OAuthError.authorizationFailed("URLの構築に失敗")
        }

        await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // コールバック待ち
        let code = try await authCode()

        // トークン交換
        try await exchangeCodeForTokens(code: code, redirectURI: redirectURI, codeVerifier: codeVerifier, clientID: clientID)

        print("[GoogleOAuth] 認証成功")
    }

    /// アクセストークンを取得（必要なら自動リフレッシュ）
    func getValidAccessToken() async throws -> String {
        if let token = GoogleOAuthConfig.loadAccessToken(), !GoogleOAuthConfig.isTokenExpired() {
            return token
        }

        // リフレッシュ
        try await refreshAccessToken()

        guard let token = GoogleOAuthConfig.loadAccessToken() else {
            throw OAuthError.refreshFailed("トークンの取得に失敗。再認証してください。")
        }
        return token
    }

    /// トークンリフレッシュ
    func refreshAccessToken() async throws {
        guard let clientID = GoogleOAuthConfig.loadClientID() else {
            throw OAuthError.noClientID
        }
        guard let refreshToken = GoogleOAuthConfig.loadRefreshToken() else {
            throw OAuthError.refreshFailed("リフレッシュトークンがありません。再認証してください。")
        }

        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.refreshFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(errBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw OAuthError.refreshFailed("レスポンスパース失敗")
        }

        GoogleOAuthConfig.saveTokens(accessToken: accessToken, refreshToken: nil, expiresIn: expiresIn)
        print("[GoogleOAuth] トークンリフレッシュ成功")
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Local Server

    private func startLocalServerAndWaitForCallback() async throws -> (port: UInt16, authCode: () async throws -> String) {
        let listener = try NWListener(using: .tcp, on: .any)

        return try await withCheckedThrowingContinuation { (serverCont: CheckedContinuation<(port: UInt16, authCode: () async throws -> String), Error>) in
            var serverResumed = false

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !serverResumed, let port = listener.port?.rawValue else { return }
                    serverResumed = true

                    let authCodeFunc: () async throws -> String = {
                        try await withCheckedThrowingContinuation { (codeCont: CheckedContinuation<String, Error>) in
                            let resumeLock = NSLock()
                            var codeResumed = false

                            func safeResume(with result: Result<String, Error>) {
                                resumeLock.lock()
                                defer { resumeLock.unlock() }
                                guard !codeResumed else { return }
                                codeResumed = true
                                listener.cancel()
                                codeCont.resume(with: result)
                            }

                            listener.newConnectionHandler = { connection in
                                connection.start(queue: .global())
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                                    guard let data = data, let requestStr = String(data: data, encoding: .utf8) else { return }

                                    if let codeRange = requestStr.range(of: "code="),
                                       let endRange = requestStr[codeRange.upperBound...].rangeOfCharacter(from: CharacterSet(charactersIn: "& ")) {
                                        let code = String(requestStr[codeRange.upperBound..<endRange.lowerBound])

                                        let html = "<html><body><h2>認証成功</h2><p>このタブを閉じてアプリに戻ってください。</p></body></html>"
                                        let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                                        connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                                            connection.cancel()
                                        })

                                        safeResume(with: .success(code))
                                    }
                                }
                            }

                            // タイムアウト（5分）
                            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                                safeResume(with: .failure(OAuthError.timeout))
                            }
                        }
                    }

                    serverCont.resume(returning: (port: port, authCode: authCodeFunc))

                case .failed(let error):
                    if !serverResumed {
                        serverResumed = true
                        serverCont.resume(throwing: OAuthError.authorizationFailed("サーバー失敗: \(error)"))
                    }
                default:
                    break
                }
            }

            listener.start(queue: .global())
        }
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, redirectURI: String, codeVerifier: String, clientID: String) async throws {
        let body = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\(percentEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(errBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw OAuthError.tokenExchangeFailed("レスポンスパース失敗")
        }

        let refreshToken = json["refresh_token"] as? String
        GoogleOAuthConfig.saveTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
    }

    private func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
