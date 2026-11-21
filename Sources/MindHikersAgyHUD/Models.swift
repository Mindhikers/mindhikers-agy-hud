import Foundation
import SwiftUI

struct HudPayload: Codable, Equatable {
    let status: String
    let message: String?
    let conversationId: String?
    let title: String?
    let fingerprint: String?
    let updatedAtMs: Int64?
    let model: String?
    let modelId: String?
    let usedTokens: Int?
    let limitTokens: Int?
    let usedPct: Double?
    let freeTokens: Int?
    let requestBudgetTokens: Int?
    let budgetPct: Double?
    let overBudget: Bool?
    let hasBreakdown: Bool?
    let compacted: Bool?
    let checkpointCount: Int?
    let checkpointBuffer: Int?
    let checkpointActiveText: String?
    let userTurns: Int?
    let totalSteps: Int?
    let isRunning: Bool?
    let sessionTotals: SessionTotals?
    let categories: [CategoryItem]?
    let recentConversations: [RecentConversation]?
    let textReport: String?

    enum CodingKeys: String, CodingKey {
        case status, message, title, fingerprint, model, compacted, categories
        case conversationId = "conversation_id"
        case updatedAtMs = "updated_at_ms"
        case modelId = "model_id"
        case usedTokens = "used_tokens"
        case limitTokens = "limit_tokens"
        case usedPct = "used_pct"
        case freeTokens = "free_tokens"
        case requestBudgetTokens = "request_budget_tokens"
        case budgetPct = "budget_pct"
        case overBudget = "over_budget"
        case hasBreakdown = "has_breakdown"
        case checkpointCount = "checkpoint_count"
        case checkpointBuffer = "checkpoint_buffer"
        case checkpointActiveText = "checkpoint_active_text"
        case userTurns = "user_turns"
        case totalSteps = "total_steps"
        case isRunning = "is_running"
        case sessionTotals = "session_totals"
        case recentConversations = "recent_conversations"
        case textReport = "text_report"
    }
}

struct SessionTotals: Codable, Equatable {
    let generations: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let cacheWriteTokens: Int
    let totalTokens: Int
    let cacheHitPct: Double

    enum CodingKeys: String, CodingKey {
        case generations
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case totalTokens = "total_tokens"
        case cacheHitPct = "cache_hit_pct"
    }
}

struct CategoryItem: Codable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let nameZh: String
    let tokens: Int
    let pct: Double

    enum CodingKeys: String, CodingKey {
        case key, name, tokens, pct
        case nameZh = "name_zh"
    }
}

struct RecentConversation: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAtMs = "updated_at_ms"
    }
}

enum HudLevel {
    case normal
    case warning
    case critical

    var swiftUIColor: Color {
        switch self {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return .systemBlue
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

enum HudFormat {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.2fB", Double(n) / 1_000_000_000.0)
        }
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000.0
            return v >= 10 ? String(format: "%.1fM", v) : String(format: "%.2fM", v)
        }
        if n >= 1_000 {
            let v = Double(n) / 1_000.0
            return v >= 100 ? String(format: "%.0fk", v) : String(format: "%.1fk", v)
        }
        return "\(n)"
    }

    static func shortModel(_ full: String) -> String {
        var s = full
            .replacingOccurrences(of: "Gemini ", with: "G")
            .replacingOccurrences(of: "Claude ", with: "C")
            .replacingOccurrences(of: " (High)", with: " H")
            .replacingOccurrences(of: " (Medium)", with: " M")
            .replacingOccurrences(of: " (Low)", with: " L")
        if s.count > 14 {
            s = String(s.prefix(13)) + "…"
        }
        return s
    }

    static func level(usedPct: Double, budgetPct: Double, overBudget: Bool) -> HudLevel {
        if usedPct >= 70.0 || (overBudget && usedPct >= 50.0) {
            return .critical
        }
        if overBudget || budgetPct >= 80.0 || usedPct >= 45.0 {
            return .warning
        }
        return .normal
    }

    static func categoryColor(_ key: String) -> Color {
        switch key {
        case "user": return Color(nsColor: .systemTeal)
        case "agent": return Color(nsColor: .systemBlue)
        case "tool": return Color(nsColor: .systemOrange)
        case "system_prompt", "system_tools", "system_overhead": return Color(nsColor: .secondaryLabelColor)
        case "system_messages": return Color(nsColor: .systemPink)
        default: return Color(nsColor: .systemPurple)
        }
    }
}
