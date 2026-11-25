import Foundation
import CommonCrypto

public struct BarkConfig: Sendable {
    public var serverURL: String
    public var deviceKey: String
    /// 32-character AES-256 key; leave empty to send in plaintext.
    public var encryptionKey: String

    public var isEncrypted: Bool { !encryptionKey.isEmpty }

    public func validate() -> String? {
        if deviceKey.isEmpty { return "Bark device key is empty" }
        if URL(string: serverURL)?.host == nil { return "Bark server URL is invalid" }
        if isEncrypted {
            if encryptionKey.utf8.count != 32 { return "AES key must be 32 characters (AES-256)" }
        }
        return nil
    }
}

public enum BarkPushError: LocalizedError {
    case invalidConfig(String)
    case encryptionFailed
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let msg): return msg
        case .encryptionFailed: return "AES encryption failed"
        case .http(let code, let body): return "Bark HTTP \(code): \(body)"
        }
    }
}

/// Sends notifications through Bark (https://github.com/Finb/Bark), optionally AES-256-CBC encrypted.
public enum BarkPushProvider {
    /// - Parameter app: Source app name, used to look up the notification icon in `PushIcons`.
    public static func send(title: String, body: String, app: String, config: BarkConfig) async throws {
        if let error = config.validate() { throw BarkPushError.invalidConfig(error) }

        var payload: [String: String] = [
            "title": title,
            "body": body,
            "group": "Teams",
            "url": "msteams://"
        ]
        if let icon = PushIcons.url(for: app) { payload["icon"] = icon }
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var request = URLRequest(url: URL(string: "\(base)/\(config.deviceKey)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        if config.isEncrypted {
            let json = try JSONSerialization.data(withJSONObject: payload)
            // Bark takes the IV with each request, so a fresh random one is used per push.
            let iv = randomIV()
            guard let cipher = aes256CBC(json, key: config.encryptionKey, iv: iv) else {
                throw BarkPushError.encryptionFailed
            }
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "ciphertext", value: cipher.base64EncodedString()),
                URLQueryItem(name: "iv", value: iv)
            ]
            // URLComponents leaves "+" unescaped, which form decoding would turn into a space.
            let encoded = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(encoded.utf8)
        } else {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw BarkPushError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func randomIV() -> String {
        randomAlphanumeric(count: kCCBlockSizeAES128)
    }

    /// Generates a 32-character key for AES-256, typeable in the Bark iOS app.
    public static func generateEncryptionKey() -> String {
        randomAlphanumeric(count: kCCKeySizeAES256)
    }

    // randomElement() uses SystemRandomNumberGenerator, which is cryptographically secure on Apple platforms.
    private static func randomAlphanumeric(count: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { _ in chars.randomElement()! })
    }

    static func aes256CBC(_ data: Data, key: String, iv: String) -> Data? {
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        guard keyData.count == kCCKeySizeAES256, ivData.count == kCCBlockSizeAES128 else { return nil }

        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outCapacity, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }
}
