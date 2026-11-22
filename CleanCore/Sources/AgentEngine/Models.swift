// SPDX-License-Identifier: MIT
//
// Swift mirrors of the engine's JSON output, schema version 1.
// The contract is docs/CLI-JSON.md; the tests decode the engine's own
// snapshot files, so a change on either side breaks a test.

import Foundation

public enum Verdict: String, Codable, Sendable {
    case active, idle, dormant
}

public enum FolderClass: String, Codable, Sendable {
    case safe, caution
}

/// One folder the rules offer in a project (`scan`, `plan`).
public struct Item: Codable, Sendable, Hashable {
    /// Relative to the project root.
    public let path: String
    public let rule: String
    public let kind: FolderClass
    /// Allocated bytes, when the guard allows the folder.
    public let bytes: UInt64?
    /// Why the guard refuses it, when it does.
    public let refused: String?
    /// Shares space with files elsewhere (pnpm or Bun store, hard links):
    /// `bytes` is an upper estimate. Older engines leave it out.
    public var shared: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case path, rule, kind = "class", bytes, refused, shared
    }
}

public struct Project: Codable, Sendable, Hashable {
    public let root: String
    public let verdict: Verdict
    public let pinned: Bool
    public let reason: String
    public let items: [Item]
}

public struct Bucket: Codable, Sendable, Hashable {
    public let folders: Int
    public let bytes: UInt64
}

public struct ScanSummary: Codable, Sendable, Hashable {
    public let projects: Int
    /// What `clean` takes with no flags.
    public let ready: Bucket
    /// What `--include-caution` adds.
    public let caution: Bucket
    /// What is held in active projects.
    public let active: Bucket
}

public enum SkipReason: String, Codable, Sendable {
    case unreadable
    /// Refused by macOS privacy protection; Full Disk Access fixes it.
    case protected
    case otherVolume = "other_volume"
    case depthLimit = "depth_limit"
    case entryLimit = "entry_limit"
    case excluded
    case installed
}

/// One line of `scan --json`.
public enum ScanEvent: Sendable, Hashable {
    case project(Project)
    case skipped(path: String, reason: SkipReason, detail: String)
    case summary(ScanSummary)
}

extension ScanEvent: Decodable {
    private enum Keys: String, CodingKey {
        case type, path, reason, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "project":
            self = .project(try Project(from: decoder))
        case "skipped":
            self = .skipped(
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(SkipReason.self, forKey: .reason),
                detail: try c.decode(String.self, forKey: .detail)
            )
        case "summary":
            self = .summary(try ScanSummary(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown scan line type \(other)")
        }
    }
}

public struct PlanOutput: Codable, Sendable, Hashable {
    public let project: Project
}

public enum CleanAction: String, Codable, Sendable {
    case move, keep
}

public struct CleanItem: Codable, Sendable, Hashable {
    public let path: String
    public let rule: String
    public let kind: FolderClass
    public let action: CleanAction
    public let bytes: UInt64?
    /// Why it stays, when it does.
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case path, rule, kind = "class", action, bytes, reason
    }
}

public struct CleanProject: Codable, Sendable, Hashable {
    public let root: String
    public let verdict: Verdict
    public let pinned: Bool
    public let reason: String
    public let items: [CleanItem]
}

public struct CleanOutput: Codable, Sendable, Hashable {
    public let execute: Bool
    public let projects: [CleanProject]
    public let folders: Int
    public let bytes: UInt64
    public let heldCaution: Int
    /// The run, after `execute`.
    public let run: Run?
}

public enum EntryState: String, Codable, Sendable {
    case pending, moved, skipped, failed, restored, purged
}

public struct RunEntry: Codable, Sendable, Hashable {
    public let original: String
    public let projectRoot: String
    public let stored: String
    public let ruleId: String
    public let kind: FolderClass
    public let bytes: UInt64
    public let state: EntryState
    /// The quarantine on another drive holding the item, if not the main one.
    public let volume: String?
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case original, projectRoot, stored, ruleId, kind = "class", bytes, state, volume, note
    }
}

public struct Run: Codable, Sendable, Hashable, Identifiable {
    public let runId: String
    public let format: Int
    public let createdUnix: UInt64
    public let entries: [RunEntry]

    public var id: String { runId }
    public var created: Date { Date(timeIntervalSince1970: TimeInterval(createdUnix)) }
    /// Bytes still held in quarantine.
    public var bytesHeld: UInt64 {
        entries.filter { $0.state == .moved }.reduce(0) { $0 + $1.bytes }
    }
}

public struct HistoryOutput: Codable, Sendable, Hashable {
    public let runs: [Run]
}

public struct RestoreOutput: Codable, Sendable, Hashable {
    public let run: Run
}

public struct PurgeOutput: Codable, Sendable, Hashable {
    public let execute: Bool
    public let bytes: UInt64
    public let freed: UInt64
    public let runs: [Run]
}

public struct PinsOutput: Codable, Sendable, Hashable {
    public let pinned: [String]
}

public struct ConfigOutput: Codable, Sendable, Hashable {
    public let path: String
    public let idleDays: Int
    public let dormantDays: Int
    public let pinned: [String]
    public let exclude: [String]
    /// Pin end times (Unix seconds) by path.
    public let pinnedUntil: [String: UInt64]?
    /// Repositories pinned wherever they are cloned (`host/owner/repo`).
    public let pinnedRemotes: [String]?
}

/// A global tool cache (ADR 0006). `command` is empty when the cache is
/// measured only.
public struct ToolCache: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let tool: String
    public let name: String
    public let path: String
    public let bytes: UInt64
    public let command: [String]?
    public let installed: Bool
    public let note: String
    /// After `clean-cache --execute`: exit code (nil if stopped or it could
    /// not start), what is left, freed, and why it could not start.
    public let status: Int?
    public let bytesAfter: UInt64?
    public let freed: UInt64?
    public let stderr: String?
    public let error: String?

    /// Can be cleared from the app: has a command and the tool is installed.
    public var clearable: Bool { installed && !(command ?? []).isEmpty }
}

struct CachesOutput: Decodable {
    let caches: [ToolCache]
}

public struct CleanCacheOutput: Decodable, Sendable {
    public let execute: Bool
    public let caches: [ToolCache]
}

struct ErrorOutput: Decodable {
    let error: String
}
