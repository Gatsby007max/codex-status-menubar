import AppKit
import Foundation

enum CodexRunStatus: String {
    case thinking = "Thinking"
    case running = "Running"
    case waiting = "Waiting"
    case idle = "Idle"
    case failed = "Failed"
    case noData = "No Data"
}

struct StatusSnapshot {
    let status: CodexRunStatus
    let threadTitle: String
    let model: String
    let tokens: String
    let rateLimitRemaining: String
    let rateLimitReset: String
    let primaryRateRemainingPercent: Double?
    let secondaryRateRemainingPercent: Double?
    let lastActivity: String
    let sourceFile: String
    let reason: String

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "status": status.rawValue,
            "threadTitle": threadTitle,
            "model": model,
            "tokens": Int(tokens) ?? tokens,
            "rateLimitRemaining": rateLimitRemaining,
            "rateLimitReset": rateLimitReset,
            "lastActivity": lastActivity,
            "sourceFile": sourceFile,
        ]
        object["primaryRateRemainingPercent"] = primaryRateRemainingPercent ?? "Unknown"
        object["secondaryRateRemainingPercent"] = secondaryRateRemainingPercent ?? "Unknown"
        return object
    }
}

struct SessionCandidate {
    let url: URL
    let threadID: String?
    let title: String?
    let modificationDate: Date?
}

struct FieldValue {
    let path: String
    let key: String
    let stringValue: String?
    let numberValue: Double?
}

enum EventKind {
    case taskStart
    case taskComplete
    case assistantActivity
    case tokenCount
    case waiting
    case error
}

struct RecognizedEvent {
    let kind: EventKind
    let index: Int
    let date: Date?
    let summary: String
}

struct RateLimitSnapshot {
    let remaining: String
    let resets: String
    let primaryRemainingPercent: Double?
    let secondaryRemainingPercent: Double?
}

struct ParsedSession {
    let validLineCount: Int
    let totalLineCount: Int
    let endedWithNewline: Bool
    let recognizedEvents: [RecognizedEvent]
    let latestDate: Date?
    let title: String?
    let model: String?
    let tokens: String?
    let rateLimits: RateLimitSnapshot?
}

struct FileSignature: Equatable {
    let path: String
    let modificationDate: Date?
    let fileSize: Int?
}

struct DetectionResult {
    let status: CodexRunStatus
    let lastActivityDate: Date?
    let reason: String
}

final class StatusCollector {
    private let fileManager = FileManager.default
    private let codexHome: URL
    private let debugEnabled: Bool
    private let isoParserWithFractional = ISO8601DateFormatter()
    private let isoParser = ISO8601DateFormatter()
    private let isoOutput = ISO8601DateFormatter()
    private var parsedCache: [String: (signature: FileSignature, parsed: ParsedSession)] = [:]

    init(debugEnabled: Bool = false) {
        self.debugEnabled = debugEnabled
        let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envHome, !envHome.isEmpty {
            codexHome = URL(fileURLWithPath: NSString(string: envHome).expandingTildeInPath)
        } else {
            codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        }
        isoParserWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoParser.formatOptions = [.withInternetDateTime]
        isoOutput.formatOptions = [.withInternetDateTime]
        isoOutput.timeZone = .current
    }

    func collect() -> (StatusSnapshot, [String]) {
        var debug: [String] = ["CODEX_HOME=\(codexHome.path)"]
        guard fileManager.fileExists(atPath: codexHome.path) else {
            return (emptySnapshot(reason: "Codex home does not exist"), debug)
        }

        let titleIndex = sessionIndex(debug: &debug)
        let candidates = sessionCandidates(titleIndex: titleIndex, debug: &debug)
        guard !candidates.isEmpty else {
            return (emptySnapshot(reason: "No session candidates found"), debug)
        }

        for candidate in candidates.prefix(50) {
            let parsed = cachedParse(candidate.url, debug: &debug)
            guard parsed.validLineCount > 0 else {
                continue
            }

            debug.append("Selected session: \(candidate.url.path) [mtime_first]")
            let detection = StatusDetector.detect(events: parsed.recognizedEvents, latestDate: parsed.latestDate)
            debug.append("Status reason: \(detection.reason)")
            let lastActivity = detection.lastActivityDate ?? parsed.latestDate ?? candidate.modificationDate

            return (StatusSnapshot(
                status: detection.status,
                threadTitle: candidate.title ?? parsed.title ?? "Unknown",
                model: parsed.model ?? "Unknown",
                tokens: parsed.tokens ?? "Unknown",
                rateLimitRemaining: parsed.rateLimits?.remaining ?? "Unknown",
                rateLimitReset: parsed.rateLimits?.resets ?? "Unknown",
                primaryRateRemainingPercent: parsed.rateLimits?.primaryRemainingPercent,
                secondaryRateRemainingPercent: parsed.rateLimits?.secondaryRemainingPercent,
                lastActivity: formatDate(lastActivity),
                sourceFile: candidate.url.path,
                reason: detection.reason
            ), debug)
        }

        return (emptySnapshot(reason: "No valid session JSONL found"), debug)
    }

    private func emptySnapshot(reason: String) -> StatusSnapshot {
        return StatusSnapshot(
            status: .noData,
            threadTitle: "Unknown",
            model: "Unknown",
            tokens: "Unknown",
            rateLimitRemaining: "Unknown",
            rateLimitReset: "Unknown",
            primaryRateRemainingPercent: nil,
            secondaryRateRemainingPercent: nil,
            lastActivity: "Unknown",
            sourceFile: "Unknown",
            reason: reason
        )
    }

    private func sessionIndex(debug: inout [String]) -> [String: String] {
        let indexURL = codexHome.appendingPathComponent("session_index.jsonl")
        guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else {
            debug.append("session_index.jsonl missing or unreadable; title lookup unavailable.")
            return [:]
        }

        var titles: [String: String] = [:]
        var validCount = 0
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String
            else {
                continue
            }
            validCount += 1
            if let title = object["thread_name"] as? String ?? object["title"] as? String {
                titles[id] = title
            }
        }
        debug.append("Valid session_index records: \(validCount)")
        return titles
    }

    private func sessionCandidates(titleIndex: [String: String], debug: inout [String]) -> [SessionCandidate] {
        let sessionsURL = codexHome.appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [SessionCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let id = extractThreadID(from: url)
            candidates.append(SessionCandidate(url: url, threadID: id, title: id.flatMap { titleIndex[$0] }, modificationDate: values?.contentModificationDate))
        }
        debug.append("Session files found: \(candidates.count)")
        return candidates.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
    }

    private func cachedParse(_ url: URL, debug: inout [String]) -> ParsedSession {
        let signature = fileSignature(for: url)
        if let cached = parsedCache[url.path], cached.signature == signature {
            debug.append("Using cached parse for \(url.path)")
            return cached.parsed
        }
        if let cached = parsedCache[url.path],
           let oldSize = cached.signature.fileSize,
           let newSize = signature.fileSize,
           newSize > oldSize,
           cached.parsed.endedWithNewline {
            debug.append("Using incremental parse for \(url.path), appended bytes: \(newSize - oldSize)")
            let appended = parseSession(url, fromOffset: UInt64(oldSize), baseLineIndex: cached.parsed.totalLineCount, debug: &debug)
            let merged = mergeParsedSession(cached.parsed, appended: appended)
            parsedCache[url.path] = (signature, merged)
            return merged
        }
        let parsed = parseSession(url, debug: &debug)
        parsedCache[url.path] = (signature, parsed)
        return parsed
    }

    private func fileSignature(for url: URL) -> FileSignature {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileSignature(path: url.path, modificationDate: values?.contentModificationDate, fileSize: values?.fileSize)
    }

    private func parseSession(_ url: URL, fromOffset offset: UInt64 = 0, baseLineIndex: Int = 0, debug: inout [String]) -> ParsedSession {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            debug.append("Unreadable session file: \(url.path)")
            return ParsedSession(validLineCount: 0, totalLineCount: 0, endedWithNewline: true, recognizedEvents: [], latestDate: nil, title: nil, model: nil, tokens: nil, rateLimits: nil)
        }
        defer { try? handle.close() }
        if offset > 0 {
            try? handle.seek(toOffset: offset)
        }

        var validLineCount = 0
        var recognized: [RecognizedEvent] = []
        var latestDate: Date?
        var title: String?
        var model: String?
        var tokens: String?
        var rateLimits: RateLimitSnapshot?
        var latestRateLimitLine: Int?
        var buffer = Data()
        let newline = Data([0x0A])
        var lineIndex = baseLineIndex
        var sawAnyData = false
        var endedWithNewline = true

        func processLine(_ lineData: Data, index: Int) {
            guard let line = String(data: lineData, encoding: .utf8),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }

            validLineCount += 1
            var fields: [FieldValue] = []
            collectFields(from: object, path: "", into: &fields)

            let eventDate = eventDate(from: object, fields: fields)
            if let eventDate, latestDate == nil || eventDate > latestDate! {
                latestDate = eventDate
            }

            title = title ?? stringField(fields, keys: ["thread_name", "title"])
            model = model ?? stringField(fields, keys: ["model"])
            if let latestTokens = latestTokenCount(fields: fields) {
                tokens = latestTokens
            }
            if let latestRateLimits = extractRateLimits(from: object) {
                rateLimits = latestRateLimits
                latestRateLimitLine = index
            }

            for kind in recognizeKinds(fields: fields) {
                recognized.append(RecognizedEvent(kind: kind, index: index, date: eventDate, summary: summarize(kind: kind, fields: fields, index: index, date: eventDate)))
            }
        }

        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            sawAnyData = true
            endedWithNewline = chunk.last == 0x0A
            buffer.append(chunk)
            while let range = buffer.firstRange(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                processLine(lineData, index: lineIndex)
                lineIndex += 1
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            }
        }
        if !buffer.isEmpty {
            processLine(buffer, index: lineIndex)
            lineIndex += 1
        }
        if !sawAnyData {
            endedWithNewline = true
        }

        if debugEnabled {
            for event in recognized.suffix(30) {
                debug.append("Recognized \(event.kind) at line \(event.index): \(event.summary)")
            }
            if let rateLimits, let latestRateLimitLine {
                debug.append("Rate limits from line \(latestRateLimitLine): remaining \(rateLimits.remaining); resets \(rateLimits.resets)")
            }
        }

        return ParsedSession(validLineCount: validLineCount, totalLineCount: lineIndex - baseLineIndex, endedWithNewline: endedWithNewline, recognizedEvents: recognized, latestDate: latestDate, title: title, model: model, tokens: tokens, rateLimits: rateLimits)
    }

    private func mergeParsedSession(_ existing: ParsedSession, appended: ParsedSession) -> ParsedSession {
        let latestDate: Date?
        if let existingDate = existing.latestDate, let appendedDate = appended.latestDate {
            latestDate = max(existingDate, appendedDate)
        } else {
            latestDate = appended.latestDate ?? existing.latestDate
        }
        return ParsedSession(
            validLineCount: existing.validLineCount + appended.validLineCount,
            totalLineCount: existing.totalLineCount + appended.totalLineCount,
            endedWithNewline: appended.endedWithNewline,
            recognizedEvents: existing.recognizedEvents + appended.recognizedEvents,
            latestDate: latestDate,
            title: appended.title ?? existing.title,
            model: appended.model ?? existing.model,
            tokens: appended.tokens ?? existing.tokens,
            rateLimits: appended.rateLimits ?? existing.rateLimits
        )
    }

    private func collectFields(from value: Any, path: String, into fields: inout [FieldValue]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                collectFields(from: child, path: path.isEmpty ? key : "\(path).\(key)", into: &fields)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectFields(from: child, path: "\(path).\(index)", into: &fields)
            }
        } else {
            let key = path.split(separator: ".").last.map(String.init) ?? path
            if let string = value as? String {
                fields.append(FieldValue(path: path, key: key, stringValue: string, numberValue: nil))
            } else if let number = value as? NSNumber {
                fields.append(FieldValue(path: path, key: key, stringValue: "\(number)", numberValue: number.doubleValue))
            }
        }
    }

    private func recognizeKinds(fields: [FieldValue]) -> [EventKind] {
        var kinds = Set<String>()
        func add(_ kind: EventKind) { kinds.insert(String(describing: kind)) }

        if hasStructuredValue(fields, markers: StatusDetector.startMarkers) { add(.taskStart) }
        if hasCompletionMarker(fields) { add(.taskComplete) }
        if hasStructuredValue(fields, markers: StatusDetector.waitingMarkers) || hasWaitingPath(fields) { add(.waiting) }
        if hasStructuredValue(fields, markers: StatusDetector.errorMarkers) || hasExplicitErrorField(fields) { add(.error) }
        if hasStructuredValue(fields, markers: ["agent_message", "assistant_message", "assistant_delta"]) || hasRole(fields, role: "assistant") { add(.assistantActivity) }
        if hasStructuredValue(fields, markers: ["token_count"]) || hasTokenField(fields) { add(.tokenCount) }

        return kinds.compactMap { name in
            switch name {
            case "taskStart": return .taskStart
            case "taskComplete": return .taskComplete
            case "assistantActivity": return .assistantActivity
            case "tokenCount": return .tokenCount
            case "waiting": return .waiting
            case "error": return .error
            default: return nil
            }
        }
    }

    private func hasStructuredValue(_ fields: [FieldValue], markers: Set<String>) -> Bool {
        let structuredKeys = Set(["type", "event", "name", "status", "kind", "role", "level"])
        for field in fields where structuredKeys.contains(field.key.lowercased()) {
            if markers.contains(normalize(field.stringValue ?? "")) {
                return true
            }
        }
        return false
    }

    private func hasStructuredValue(_ fields: [FieldValue], markers: [String]) -> Bool {
        return hasStructuredValue(fields, markers: Set(markers.map(normalize)))
    }

    private func hasCompletionMarker(_ fields: [FieldValue]) -> Bool {
        let exactKeys = Set(["type", "event", "name", "kind"])
        for field in fields {
            let key = field.key.lowercased()
            let normalized = normalize(field.stringValue ?? "")
            if exactKeys.contains(key), StatusDetector.completionMarkers.contains(normalized) {
                return true
            }
            if key == "status", StatusDetector.genericCompletionStatusMarkers.contains(normalized) {
                let path = normalize(field.path)
                if path.contains("task") || path.contains("turn") || path.contains("run") || path.contains("generation") {
                    return true
                }
            }
        }
        return false
    }

    private func hasRole(_ fields: [FieldValue], role: String) -> Bool {
        return fields.contains { $0.key.lowercased() == "role" && normalize($0.stringValue ?? "") == role }
    }

    private func hasTokenField(_ fields: [FieldValue]) -> Bool {
        for field in fields {
            let key = field.key.lowercased()
            if key == "token_count" || key == "total_tokens" || key == "output_tokens" || key == "reasoning_output_tokens" {
                return (field.numberValue ?? 0) > 0 || key == "token_count"
            }
        }
        return false
    }

    private func hasWaitingPath(_ fields: [FieldValue]) -> Bool {
        return fields.contains { field in
            let path = normalize(field.path)
            return path.contains("approval_request") || path.contains("permission_request") || path.contains("user_input") || path.contains("requires_action")
        }
    }

    private func hasExplicitErrorField(_ fields: [FieldValue]) -> Bool {
        for field in fields {
            let key = field.key.lowercased()
            let value = field.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if ["error", "last_error", "exception"].contains(key), !value.isEmpty, normalize(value) != "null" {
                return true
            }
        }
        return false
    }

    private func summarize(kind: EventKind, fields: [FieldValue], index: Int, date: Date?) -> String {
        let structured = fields
            .filter { ["type", "event", "name", "status", "kind", "role"].contains($0.key.lowercased()) }
            .compactMap { field -> String? in
                guard let value = field.stringValue, !value.isEmpty else { return nil }
                return "\(field.path)=\(value)"
            }
            .prefix(4)
            .joined(separator: ", ")
        return "\(kind), \(date.map(formatDate) ?? "no-date"), \(structured)"
    }

    private func eventDate(from object: [String: Any], fields: [FieldValue]) -> Date? {
        for key in ["timestamp", "created_at", "updated_at", "time"] {
            if let value = object[key] as? String, let date = parseDate(value) { return date }
        }
        for field in fields where ["timestamp", "created_at", "updated_at", "time"].contains(field.key.lowercased()) {
            if let date = parseDate(field.stringValue) { return date }
        }
        return nil
    }

    private func stringField(_ fields: [FieldValue], keys: [String]) -> String? {
        for field in fields where keys.contains(field.key.lowercased()) {
            if let value = field.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private func latestTokenCount(fields: [FieldValue]) -> String? {
        for field in fields.reversed() where field.key.lowercased() == "total_tokens" {
            if let number = field.numberValue, number > 0 { return "\(Int(number))" }
        }
        return nil
    }

    private func extractRateLimits(from object: [String: Any]) -> RateLimitSnapshot? {
        guard let payload = object["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }
        let primary = rateLimitPart(label: "5h", value: rateLimits["primary"])
        let secondary = rateLimitPart(label: "7D", value: rateLimits["secondary"])
        let remainingParts = [primary.remaining, secondary.remaining].compactMap { $0 }
        let resetParts = [primary.reset, secondary.reset].compactMap { $0 }
        guard !remainingParts.isEmpty || !resetParts.isEmpty else { return nil }
        return RateLimitSnapshot(
            remaining: remainingParts.isEmpty ? "Unknown" : remainingParts.joined(separator: " / "),
            resets: resetParts.isEmpty ? "Unknown" : resetParts.joined(separator: " / "),
            primaryRemainingPercent: primary.remainingPercent,
            secondaryRemainingPercent: secondary.remainingPercent
        )
    }

    private func rateLimitPart(label fallbackLabel: String, value: Any?) -> (remaining: String?, reset: String?, remainingPercent: Double?) {
        guard let dictionary = value as? [String: Any] else { return (nil, nil, nil) }
        let label = rateWindowLabel(minutes: intValue(dictionary["window_minutes"])) ?? fallbackLabel
        var remaining: String?
        var remainingPercent: Double?
        if let used = doubleValue(dictionary["used_percent"]) {
            remainingPercent = min(100, max(0, 100 - used))
            remaining = "\(label): \(formatPercent(remainingPercent ?? 0)) left"
        }
        var reset: String?
        if let resetEpoch = doubleValue(dictionary["resets_at"]) {
            reset = "\(label): \(formatDate(Date(timeIntervalSince1970: resetEpoch)))"
        }
        return (remaining, reset, remainingPercent)
    }

    private func rateWindowLabel(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes % 1440 == 0 { return "\(minutes / 1440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoParserWithFractional.date(from: value) ?? isoParser.date(from: value)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return isoOutput.string(from: date)
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value { return "\(Int(value))%" }
        return String(format: "%.1f%%", value)
    }

    private func extractThreadID(from url: URL) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range), let swiftRange = Range(match.range, in: name) else { return nil }
        return String(name[swiftRange])
    }

    private func normalize(_ value: String) -> String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: " ", with: "_")
    }
}

enum StatusDetector {
    static let startMarkers: Set<String> = ["task_started", "task_start", "turn_started", "turn_start", "run_started", "run_start", "response_started", "generation_started"]
    static let completionMarkers: Set<String> = ["task_complete", "task_completed", "turn_complete", "turn_completed", "run_complete", "run_completed", "response_complete", "response_completed", "task_success", "task_succeeded", "turn_success", "run_success", "run_succeeded"]
    static let genericCompletionStatusMarkers: Set<String> = ["complete", "completed", "success", "succeeded", "done"]
    static let errorMarkers: Set<String> = ["tool_error", "task_failed", "turn_failed", "run_failed", "failed", "failure", "exception", "error", "fatal"]
    static let waitingMarkers: Set<String> = ["waiting", "input_required", "requires_input", "requires_action", "requires_user_input", "approval_request", "approval_requested", "permission_request", "user_input_required", "elicitation", "mcp_elicitation"]

    static func detect(events: [RecognizedEvent], latestDate: Date?) -> DetectionResult {
        guard !events.isEmpty else {
            return DetectionResult(status: .idle, lastActivityDate: latestDate, reason: "Valid session found, but no recognized events were present.")
        }
        let sorted = events.sorted { $0.index < $1.index }
        let lastStart = sorted.last { $0.kind == .taskStart }
        let lastComplete = sorted.last { $0.kind == .taskComplete }
        let lastError = sorted.last { $0.kind == .error }
        let lastWaiting = sorted.last { $0.kind == .waiting }
        let lastAssistantOrToken = sorted.last { $0.kind == .assistantActivity || $0.kind == .tokenCount }
        let lastRecognizedDate = sorted.compactMap(\.date).max() ?? latestDate
        let lastStartIndex = lastStart?.index ?? -1
        let lastCompleteIndex = lastComplete?.index ?? -1
        let activeRun = lastStartIndex > lastCompleteIndex

        if let lastError,
           lastError.index > lastCompleteIndex,
           isRecent(lastError.date, fallbackIsRecent: lastError.index >= (sorted.last?.index ?? 0) - 25, withinSeconds: 600) {
            return DetectionResult(status: .failed, lastActivityDate: lastError.date ?? lastRecognizedDate, reason: "Recent explicit error marker at line \(lastError.index), with no later completion marker.")
        }
        if activeRun {
            if let lastAssistantOrToken,
               lastAssistantOrToken.index > lastStartIndex,
               isRecent(lastAssistantOrToken.date, fallbackIsRecent: true, withinSeconds: 45) {
                return DetectionResult(status: .thinking, lastActivityDate: lastAssistantOrToken.date ?? lastRecognizedDate, reason: "Active run after line \(lastStartIndex), with recent assistant/token activity at line \(lastAssistantOrToken.index).")
            }
            return DetectionResult(status: .running, lastActivityDate: lastStart?.date ?? lastRecognizedDate, reason: "Active run after line \(lastStartIndex), but no very recent assistant/token activity.")
        }
        if let lastWaiting,
           lastWaiting.index > lastCompleteIndex,
           isRecent(lastWaiting.date, fallbackIsRecent: lastWaiting.index >= (sorted.last?.index ?? 0) - 25, withinSeconds: 1800) {
            return DetectionResult(status: .waiting, lastActivityDate: lastWaiting.date ?? lastRecognizedDate, reason: "Latest inactive state appears to be waiting for user input or approval at line \(lastWaiting.index).")
        }
        return DetectionResult(status: .idle, lastActivityDate: lastComplete?.date ?? lastRecognizedDate, reason: "No active run, recent failure, or clear waiting marker detected.")
    }

    private static func isRecent(_ date: Date?, fallbackIsRecent: Bool, withinSeconds seconds: TimeInterval) -> Bool {
        guard let date else { return fallbackIsRecent }
        return Date().timeIntervalSince(date) <= seconds
    }
}

final class MiniBarView: NSView {
    let label: String
    let percent: Double

    init(label: String, percent: Double) {
        self.label = label
        self.percent = min(100, max(0, percent))
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let textAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        label.draw(in: NSRect(x: 16, y: 4, width: 34, height: 16), withAttributes: textAttrs)
        let value = percent.rounded() == percent ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
        value.draw(in: NSRect(x: bounds.width - 58, y: 4, width: 44, height: 16), withAttributes: textAttrs)
        let track = NSRect(x: 56, y: 8, width: bounds.width - 124, height: 8)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(percent / 100), height: track.height), xRadius: 4, yRadius: 4).fill()
    }
}

final class DesktopWidgetView: NSView {
    private var snapshot: StatusSnapshot

    init(snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 168))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func update(snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        border.lineWidth = 1
        border.stroke()

        drawText("Codex", x: 18, y: 15, width: 90, size: 16, weight: .bold, alpha: 1)
        drawStatus()
        drawText(snapshot.threadTitle, x: 18, y: 43, width: bounds.width - 36, size: 12, weight: .regular, alpha: 0.72)
        drawBar(label: "5h", percent: snapshot.primaryRateRemainingPercent, y: 78)
        drawBar(label: "7D", percent: snapshot.secondaryRateRemainingPercent, y: 110)
        drawText("Updated \(snapshot.lastActivity)", x: 18, y: 143, width: bounds.width - 36, size: 11, weight: .regular, alpha: 0.58, monospaced: true)
    }

    private func drawStatus() {
        let rect = NSRect(x: bounds.width - 126, y: 14, width: 108, height: 24)
        statusColor().withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        statusColor().setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: 8, height: 8)).fill()
        drawText(snapshot.status.rawValue, x: rect.minX + 24, y: rect.minY + 4, width: rect.width - 30, size: 12, weight: .semibold, alpha: 1)
    }

    private func drawBar(label: String, percent: Double?, y: CGFloat) {
        drawText(label, x: 18, y: y - 3, width: 34, size: 12, weight: .semibold, alpha: 0.86)
        let track = NSRect(x: 55, y: y + 3, width: bounds.width - 122, height: 10)
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        guard let percent else {
            drawText("Unknown", x: bounds.width - 82, y: y - 3, width: 64, size: 12, weight: .regular, alpha: 0.70, monospaced: true)
            return
        }
        let clamped = min(100, max(0, percent))
        barColor(for: clamped).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(clamped / 100), height: track.height), xRadius: 5, yRadius: 5).fill()
        let value = clamped.rounded() == clamped ? "\(Int(clamped))%" : String(format: "%.1f%%", clamped)
        drawText(value, x: bounds.width - 60, y: y - 3, width: 42, size: 12, weight: .regular, alpha: 0.70, monospaced: true)
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, monospaced: Bool = false) {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha), .font: font]
        text.draw(in: NSRect(x: x, y: y, width: width, height: size + 6), withAttributes: attrs)
    }

    private func statusColor() -> NSColor {
        switch snapshot.status {
        case .thinking: return .systemBlue
        case .running: return .systemGreen
        case .waiting: return .systemOrange
        case .idle: return .systemGray
        case .failed: return .systemRed
        case .noData: return .secondaryLabelColor
        }
    }

    private func barColor(for percent: Double) -> NSColor {
        if percent <= 15 { return .systemRed }
        if percent <= 35 { return .systemOrange }
        return .systemGreen
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let desktopWidgetEnabledDefaultsKey = "DesktopWidgetEnabled"
    private let collector: StatusCollector
    private let debugEnabled: Bool
    private let pollInterval: TimeInterval
    private let collectorQueue = DispatchQueue(label: "local.codex-status-menubar.collector", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var pollingTimer: DispatchSourceTimer?
    private var isRefreshInFlight = false
    private var pendingRefreshAfterCurrent = false
    private var lastSnapshot: StatusSnapshot?
    private var lastDisplayedStopKey: String?
    private var petBubbleWindow: NSPanel?
    private var petBubbleDismissWorkItem: DispatchWorkItem?
    private var desktopWidgetWindow: NSPanel?
    private var desktopWidgetView: DesktopWidgetView?
    private var isDesktopWidgetVisible = true

    init(debugEnabled: Bool) {
        self.debugEnabled = debugEnabled
        self.pollInterval = AppDelegate.pollIntervalFromEnvironment()
        self.collector = StatusCollector(debugEnabled: debugEnabled)
        self.isDesktopWidgetVisible = AppDelegate.desktopWidgetEnabledFromDefaults()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem.button?.title = "Codex: Loading"
        refresh()
        startPolling()
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.scheduleRefresh(queueIfBusy: false) }
        timer.resume()
        pollingTimer = timer
    }

    private static func pollIntervalFromEnvironment() -> TimeInterval {
        guard let value = Double(ProcessInfo.processInfo.environment["CODEX_STATUS_POLL_INTERVAL"] ?? ""), value.isFinite else { return 3.0 }
        return min(30.0, max(1.5, value))
    }

    private static func desktopWidgetEnabledFromDefaults() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: desktopWidgetEnabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: desktopWidgetEnabledDefaultsKey)
    }

    @objc private func refresh() {
        scheduleRefresh(queueIfBusy: true)
    }

    private func scheduleRefresh(queueIfBusy: Bool) {
        guard !isRefreshInFlight else {
            if queueIfBusy {
                pendingRefreshAfterCurrent = true
            }
            return
        }

        isRefreshInFlight = true
        collectorQueue.async { [weak self] in
            guard let self else { return }
            let (snapshot, debugLines) = self.collector.collect()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshInFlight = false
                self.apply(snapshot: snapshot, debugLines: debugLines)
                if self.pendingRefreshAfterCurrent {
                    self.pendingRefreshAfterCurrent = false
                    self.scheduleRefresh(queueIfBusy: false)
                }
            }
        }
    }

    private func apply(snapshot: StatusSnapshot, debugLines: [String]) {
        let previousSnapshot = lastSnapshot
        if debugEnabled { writeDebug(debugLines) }
        configureStatusButton(for: snapshot)
        statusItem.menu = menu(for: snapshot)
        updateDesktopWidget(with: snapshot)
        showPetTextIfWorkStopped(from: previousSnapshot, to: snapshot)
        lastSnapshot = snapshot
    }

    private func updateDesktopWidget(with snapshot: StatusSnapshot) {
        guard isDesktopWidgetVisible else { return }
        if desktopWidgetWindow == nil {
            showDesktopWidget(with: snapshot)
        } else {
            desktopWidgetView?.update(snapshot: snapshot)
        }
    }

    private func showDesktopWidget(with snapshot: StatusSnapshot) {
        let size = NSSize(width: 320, height: 168)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let view = DesktopWidgetView(snapshot: snapshot)
        panel.contentView = view
        panel.setFrameOrigin(defaultWidgetOrigin(size: size))
        panel.orderFrontRegardless()
        desktopWidgetWindow = panel
        desktopWidgetView = view
    }

    private func hideDesktopWidget() {
        desktopWidgetWindow?.close()
        desktopWidgetWindow = nil
        desktopWidgetView = nil
    }

    private func defaultWidgetOrigin(size: NSSize) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - size.width - 22, y: screen.maxY - size.height - 52)
    }

    private func showPetTextIfWorkStopped(from previous: StatusSnapshot?, to current: StatusSnapshot) {
        guard let previous, isActiveStatus(previous.status), isStoppedStatus(current.status), current.rateLimitRemaining != "Unknown" else { return }
        let key = "\(current.lastActivity)|\(current.rateLimitRemaining)|\(current.status.rawValue)"
        guard lastDisplayedStopKey != key else { return }
        lastDisplayedStopKey = key
        let phrase: String
        switch current.status {
        case .failed: phrase = "作業が止まりました。エラーを検出しています。"
        case .waiting: phrase = "作業が止まりました。入力または承認待ちです。"
        default: phrase = "作業が止まりました。"
        }
        showPetBubble("\(phrase)\nRate remaining: \(compactRateLimit(current.rateLimitRemaining))")
    }

    private func showPetBubble(_ message: String) {
        petBubbleDismissWorkItem?.cancel()
        petBubbleWindow?.close()
        let size = NSSize(width: 390, height: 86)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let view = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 18, y: 14, width: size.width - 36, height: size.height - 28)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        view.addSubview(label)

        panel.contentView = view
        panel.setFrameOrigin(petBubbleOrigin(size: size))
        panel.orderFrontRegardless()
        petBubbleWindow = panel
        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            panel?.close()
            if self?.petBubbleWindow === panel { self?.petBubbleWindow = nil }
        }
        petBubbleDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismiss)
    }

    private func petBubbleOrigin(size: NSSize) -> NSPoint {
        let frame = statusItem.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let button = statusItem.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            return NSPoint(x: min(max(anchor.midX - size.width / 2, frame.minX + 12), frame.maxX - size.width - 12), y: max(frame.minY + 12, anchor.minY - size.height - 10))
        }
        return NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16)
    }

    private func configureStatusButton(for snapshot: StatusSnapshot) {
        guard let button = statusItem.button else { return }
        if let badge = menuBarRateBadge(snapshot.rateLimitRemaining) {
            button.title = "\(badge) | Codex: \(snapshot.status.rawValue)"
        } else {
            button.title = "Codex: \(snapshot.status.rawValue)"
        }
        button.toolTip = "Rate remaining: \(snapshot.rateLimitRemaining)\nRate reset: \(snapshot.rateLimitReset)\nCodex: \(snapshot.status.rawValue)\nTokens: \(displayTokenCount(snapshot.tokens))\nLast activity: \(snapshot.lastActivity)"
        button.needsDisplay = true
        if #available(macOS 11.0, *) {
            let symbol: String
            switch snapshot.status {
            case .thinking: symbol = "brain.head.profile"
            case .running: symbol = "play.fill"
            case .waiting: symbol = "hourglass"
            case .idle: symbol = "checkmark.circle"
            case .failed: symbol = "exclamationmark.triangle"
            case .noData: symbol = "questionmark.circle"
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: snapshot.status.rawValue)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
    }

    private func menu(for snapshot: StatusSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addRateLimitItems(snapshot, to: menu)
        addInfoItem("Rate reset", snapshot.rateLimitReset, to: menu)
        menu.addItem(.separator())
        addInfoItem("Status", snapshot.status.rawValue, to: menu, emphasized: true)
        addInfoItem("Thread title", snapshot.threadTitle, to: menu)
        addInfoItem("Model", snapshot.model, to: menu)
        addInfoItem("Token count", displayTokenCount(snapshot.tokens), to: menu)
        addInfoItem("Last activity time", snapshot.lastActivity, to: menu)
        addInfoItem("Pet text", "On stop", to: menu)
        addInfoItem("Source file", snapshot.sourceFile, to: menu)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshMenuAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let widget = NSMenuItem(title: isDesktopWidgetVisible ? "Stop Desktop Widget" : "Start Desktop Widget", action: #selector(toggleDesktopWidget), keyEquivalent: "w")
        widget.target = self
        menu.addItem(widget)
        let open = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func addRateLimitItems(_ snapshot: StatusSnapshot, to menu: NSMenu) {
        addInfoItem("Rate remaining", snapshot.rateLimitRemaining, to: menu, emphasized: true)
        if let primary = snapshot.primaryRateRemainingPercent { addBar(label: "5h", percent: primary, to: menu) }
        if let secondary = snapshot.secondaryRateRemainingPercent { addBar(label: "7D", percent: secondary, to: menu) }
    }

    private func addBar(label: String, percent: Double, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = MiniBarView(label: label, percent: percent)
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfoItem(_ label: String, _ value: String, to menu: NSMenu, emphasized: Bool = false) {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: "\(label): \(value)", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: emphasized ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ])
        item.isEnabled = true
        menu.addItem(item)
    }

    private func isActiveStatus(_ status: CodexRunStatus) -> Bool { status == .thinking || status == .running }
    private func isStoppedStatus(_ status: CodexRunStatus) -> Bool { status == .idle || status == .waiting || status == .failed }
    private func compactRateLimit(_ value: String) -> String { value.replacingOccurrences(of: ": ", with: " ").replacingOccurrences(of: " left", with: "") }

    private func displayTokenCount(_ raw: String) -> String {
        guard let int = Int(raw) else { return raw }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: int)) ?? raw
    }

    private func menuBarRateBadge(_ value: String) -> String? {
        guard value != "Unknown" else { return nil }
        let parts = value.split(separator: "/").map { String($0).replacingOccurrences(of: ": ", with: " ").replacingOccurrences(of: " left", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    @objc private func refreshMenuAction() { refresh() }

    @objc private func toggleDesktopWidget() {
        isDesktopWidgetVisible.toggle()
        UserDefaults.standard.set(isDesktopWidgetVisible, forKey: AppDelegate.desktopWidgetEnabledDefaultsKey)
        if isDesktopWidgetVisible {
            if let lastSnapshot { showDesktopWidget(with: lastSnapshot) } else { refresh() }
        } else {
            hideDesktopWidget()
        }
        if let lastSnapshot { statusItem.menu = menu(for: lastSnapshot) }
    }

    @objc private func openCodex() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
    }

    @objc private func quit() {
        petBubbleDismissWorkItem?.cancel()
        petBubbleWindow?.close()
        hideDesktopWidget()
        pollingTimer?.cancel()
        NSApplication.shared.terminate(nil)
    }
}

func writeDebug(_ lines: [String]) {
    guard !lines.isEmpty else { return }
    FileHandle.standardError.write((lines.map { "[codex-status] \($0)" }.joined(separator: "\n") + "\n").data(using: .utf8)!)
}

func printJSON(_ snapshot: StatusSnapshot) {
    if let data = try? JSONSerialization.data(withJSONObject: snapshot.jsonObject(), options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print(#"{"status":"No Data","threadTitle":"Unknown","model":"Unknown","tokens":"Unknown","rateLimitRemaining":"Unknown","rateLimitReset":"Unknown","lastActivity":"Unknown","sourceFile":"Unknown"}"#)
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())
let debugEnabled = arguments.contains("--debug") || arguments.contains("--verbose")

if arguments.contains("--once") {
    let collector = StatusCollector(debugEnabled: debugEnabled)
    let (snapshot, debugLines) = collector.collect()
    if debugEnabled {
        writeDebug(debugLines + ["Final status: \(snapshot.status.rawValue)", "Final reason: \(snapshot.reason)"])
    }
    printJSON(snapshot)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(debugEnabled: debugEnabled)
    app.delegate = delegate
    app.run()
}
