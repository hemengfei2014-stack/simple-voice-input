import Foundation

enum GeminiError: LocalizedError {
    case invalidAPIKey
    case requestFailed(Int, String)
    case invalidResponse(String)
    case requestTimedOut(TimeInterval)
    case audioFileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid Gemini API Key"
        case .requestFailed(let statusCode, let details):
            return "Gemini API request failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            return "Invalid Gemini response: \(details)"
        case .requestTimedOut(let seconds):
            return "Request timed out after \(Int(seconds))s"
        case .audioFileNotFound:
            return "Audio file not found"
        }
    }
}

struct GeminiResult {
    let transcript: String
    let promptUsed: String
}

final class GeminiService {
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    private let model = "gemini-3-flash-preview"
    private let timeoutSeconds: TimeInterval = 30

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 验证 API Key
    static func validateAPIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmed)"
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // 处理音频文件：同时完成 ASR 和后处理
    func processAudio(fileURL: URL, systemPrompt: String) async throws -> GeminiResult {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GeminiError.audioFileNotFound
        }

        // 读取音频文件
        let audioData = try Data(contentsOf: fileURL)
        let base64Audio = audioData.base64EncodedString()

        // 使用超时控制
        return try await withThrowingTaskGroup(of: GeminiResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw GeminiError.invalidResponse("Service deallocated")
                }
                return try await self.process(audioBase64: base64Audio, systemPrompt: systemPrompt)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                throw GeminiError.requestTimedOut(self.timeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw GeminiError.invalidResponse("No result from Gemini")
            }
            group.cancelAll()
            return result
        }
    }

    private func process(audioBase64: String, systemPrompt: String) async throws -> GeminiResult {
        let urlString = "\(baseURL)/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        // 构建请求负载
        let userPrompt = """
Please transcribe the audio recording and apply the post-processing instructions from the system prompt.
Return ONLY the final processed text, nothing else.
If the audio is empty or silent, return exactly: EMPTY
"""

        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": systemPrompt],
                    ["text": userPrompt],
                    [
                        "inline_data": [
                            "mime_type": "audio/wav",
                            "data": audioBase64
                        ] as [String: Any]
                    ] as [String: Any]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 8192
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        // 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.requestFailed(0, "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.requestFailed(httpResponse.statusCode, responseBody)
        }

        // 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw GeminiError.invalidResponse("Missing candidates[0].content.parts[0].text")
        }

        // 清理响应文本
        let cleanedText = sanitizeResponse(text)

        // 构建用于显示的 prompt
        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userPrompt)

[Audio Data]
\(audioBase64.count) bytes (base64 encoded)
"""

        return GeminiResult(
            transcript: cleanedText,
            promptUsed: promptForDisplay
        )
    }

    private func sanitizeResponse(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // 去除外层引号
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 处理 EMPTY 标记
        if result == "EMPTY" {
            return ""
        }

        // 去除可能的 markdown 代码块标记
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: .newlines)
            if lines.count > 1 {
                // 去掉第一行和最后一行的 ```
                var newLines = lines
                newLines.removeFirst()
                if newLines.last?.hasPrefix("```") == true {
                    newLines.removeLast()
                }
                result = newLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}
