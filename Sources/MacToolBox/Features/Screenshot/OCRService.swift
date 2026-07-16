import AppKit
@preconcurrency import Vision

/// 本地 OCR 文字识别（Apple Vision，无需联网）。
/// 借鉴 capcap 的 OCRService，去掉其内部 DiagnosticLog 依赖，保留中英文识别与阅读顺序排序。
/// Vision 的 VNRecognizeTextRequest / VNImageRequestHandler 非 Sendable，故本服务固定在 MainActor 上，
/// 把 Vision 对象限制在 @Sendable 闭包内部创建与使用，避免跨并发域传递。
@MainActor enum OCRService {
    /// 纯常量，标记为 nonisolated 以便后台 @Sendable 闭包安全读取。
    nonisolated private static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// 识别图片文字，返回按阅读顺序排列、换行连接的纯文本。
    static func recognize(image: NSImage, completion: @escaping @Sendable (String) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion("")
            return
        }

        // 后台执行 Vision：request/handler 都在 @Sendable 闭包内创建与使用，不逃逸；
        // completion 已是 @Sendable，可安全在后台/主线程闭包中捕获。结果（String）天然 Sendable。
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = preferredLanguages
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var result = ""
            do {
                try handler.perform([request])
                let observations = request.results ?? []
                result = Self.assemble(observations)
            } catch {
                result = ""
            }
            let text = result
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 识别并返回 行文本数组（按阅读顺序），供「逐行复制」使用。
    static func recognizeLines(image: NSImage, completion: @escaping @Sendable ([String]) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion([])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = preferredLanguages
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var result: [String] = []
            do {
                try handler.perform([request])
                let observations = request.results ?? []
                result = observations.compactMap { obs -> String? in
                    guard let cand = obs.topCandidates(1).first else { return nil }
                    let t = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
            } catch {
                result = []
            }
            let lines = result
            DispatchQueue.main.async { completion(lines) }
        }
    }

    /// 将 observation 按阅读顺序（上→下、左→右）组装为文本。纯计算，标记为 nonisolated。
    nonisolated private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let sorted = observations.sorted { a, b in
            // Vision boundingBox 原点左下、y 向上；midY 越大越靠上
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.012 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines = sorted.compactMap { obs -> String? in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let t = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return lines.joined(separator: "\n")
    }
}
