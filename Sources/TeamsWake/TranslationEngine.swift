import Foundation

public enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case microsoft = "microsoft"
    case google = "google"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .microsoft: return "Microsoft (Edge)"
        case .google: return "Google Translate"
        }
    }
}

public actor TranslationEngine {
    public static let shared = TranslationEngine()

    private var cache: [String: String] = [:]
    private let maxCacheSize = 200

    /// Dedicated ephemeral session: no disk caching/cookies, strict fast-fail timeouts for seamless failover
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Determines whether the text should be primarily treated as Chinese based on weighted character density
    /// Chinese ideographs have roughly 2.8x higher semantic density than Latin letters
    public static func isChineseDominant(_ text: String) -> Bool {
        var hanCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            // CJK Unified Ideographs (0x4E00...0x9FFF) and Extension A (0x3400...0x4DBF)
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                hanCount += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latinCount += 1
            }
        }

        // No Chinese at all -> English/Foreign dominant
        guard hanCount > 0 else { return false }
        // Has Chinese and no Latin -> pure Chinese
        guard latinCount > 0 else { return true }

        // An average English word contains ~5 characters.
        // 1 Chinese character roughly corresponds to 2.5-3 Latin characters in semantic weight.
        return Double(hanCount) * 2.8 >= Double(latinCount)
    }

    public func containsChinese(_ text: String) -> Bool {
        return TranslationEngine.isChineseDominant(text)
    }

    /// Main translation entry point with automatic fallback and bidirectional Chinese-English translation
    public func translate(
        text: String,
        provider: TranslationProvider = .microsoft,
        forcedDirection: String? = nil
    ) async throws -> (result: String, direction: String, actualProvider: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "ZH ➔ EN", provider.displayName) }

        let isZh: Bool
        if let forced = forcedDirection {
            isZh = (forced == "ZH ➔ EN")
        } else {
            isZh = TranslationEngine.isChineseDominant(trimmed)
        }
        let fromLang = isZh ? "zh-Hans" : "en"
        let toLang = isZh ? "en" : "zh-Hans"
        let directionLabel = isZh ? "ZH ➔ EN" : "EN ➔ ZH"

        let cacheKey = "\(fromLang):\(toLang):\(trimmed)"
        if let cached = cache[cacheKey] {
            return (cached, directionLabel, provider.displayName)
        }

        var translatedText = ""
        var usedProvider = provider.displayName

        if provider == .microsoft {
            do {
                translatedText = try await translateViaMicrosoftEdge(text: trimmed, from: fromLang, to: toLang)
            } catch {
                // Fallback to Google if Microsoft fails
                translatedText = try await translateViaGoogle(text: trimmed, from: isZh ? "zh-CN" : "en", to: isZh ? "en" : "zh-CN")
                usedProvider = "Google (Fallback)"
            }
        } else {
            do {
                translatedText = try await translateViaGoogle(text: trimmed, from: isZh ? "zh-CN" : "en", to: isZh ? "en" : "zh-CN")
            } catch {
                translatedText = try await translateViaMicrosoftEdge(text: trimmed, from: fromLang, to: toLang)
                usedProvider = "Microsoft (Fallback)"
            }
        }

        if cache.count >= maxCacheSize, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }
        cache[cacheKey] = translatedText

        return (translatedText, directionLabel, usedProvider)
    }

    // MARK: - Microsoft Edge Translation (Fast API without Key)
    private func translateViaMicrosoftEdge(text: String, from: String, to: String) async throws -> String {
        guard let url = URL(string: "https://edge.microsoft.com/translate/translatetext?from=\(from)&to=\(to)&isEnterpriseClient=false") else {
            throw NSError(domain: "TranslationEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://edge.microsoft.com", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [text])

        let (data, response) = try await session.data(for: req)
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
            throw NSError(domain: "TranslationEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microsoft Edge HTTP status not 200"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let translations = first["translations"] as? [[String: Any]],
              let result = translations.first?["text"] as? String else {
            throw NSError(domain: "TranslationEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Microsoft response"])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Google Chrome Extension Translate (Fallback API)
    private func translateViaGoogle(text: String, from: String, to: String) async throws -> String {
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=\(from)&tl=\(to)&q=\(encodedText)") else {
            throw NSError(domain: "TranslationEngine", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid Google URL"])
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
            throw NSError(domain: "TranslationEngine", code: -5, userInfo: [NSLocalizedDescriptionKey: "Google HTTP status not 200"])
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] {
            var combined = ""
            for item in list {
                if let str = item as? String {
                    combined += str
                } else if let subList = item as? [Any], let firstStr = subList.first as? String {
                    combined += firstStr
                }
            }
            if !combined.isEmpty {
                return combined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw NSError(domain: "TranslationEngine", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Google response"])
    }
}
