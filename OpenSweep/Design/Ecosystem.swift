// SPDX-License-Identifier: MIT
//
// Languages and tools, shown with their own logos. The logos are Simple Icons
// (CC0, simpleicons.org), pinned in docs/THIRD-PARTY.md; the names are the
// projects' trademarks, used only to say which tool a folder belongs to.

import SwiftUI
import AgentEngine

struct Ecosystem: Hashable, Identifiable {
    let id: String
    let name: String
    /// Asset name of the logo, or nil for an SF Symbol fallback.
    let logo: String?
    let color: Color
    var symbol: String = "shippingbox"

    /// Rule ids (engine/rules/*.toml) to their language.
    static func of(rule: String) -> Ecosystem { byRule[rule] ?? Ecosystem(id: rule, name: rule.capitalized, logo: nil, color: Brand.muted) }

    private static let byRule: [String: Ecosystem] = [
        "node": .init(id: "node", name: "Node.js", logo: "logo-nodedotjs", color: Color(logo: 0x5FA04E)),
        "rust": .init(id: "rust", name: "Rust", logo: "logo-rust", color: Color(logo: 0xDEA584)),
        "python": .init(id: "python", name: "Python", logo: "logo-python", color: Color(logo: 0x4B8BBE)),
        "go": .init(id: "go", name: "Go", logo: "logo-go", color: Color(logo: 0x00ADD8)),
        "swiftpm": .init(id: "swiftpm", name: "Swift", logo: "logo-swift", color: Color(logo: 0xF05138)),
        "xcode": .init(id: "xcode", name: "Xcode", logo: "logo-xcode", color: Color(logo: 0x147EFB)),
        "flutter": .init(id: "flutter", name: "Flutter", logo: "logo-flutter", color: Color(logo: 0x47C5FB)),
        "php": .init(id: "php", name: "PHP", logo: "logo-php", color: Color(logo: 0x8892BF)),
        "java": .init(id: "java", name: "Java and Kotlin", logo: "logo-openjdk", color: Color(logo: 0xE76F00)),
        "android": .init(id: "android", name: "Android", logo: "logo-android", color: Color(logo: 0x34A853)),
        "dotnet": .init(id: "dotnet", name: ".NET", logo: "logo-dotnet", color: Color(logo: 0x8B6CEF)),
    ]

    /// Global caches (`opensweep caches`) by id.
    static func of(cache id: String) -> Ecosystem {
        let logo: (String, UInt32)? = switch id {
        case "npm": ("logo-npm", 0xCB3837)
        case "pnpm": ("logo-pnpm", 0xF69220)
        case "yarn": ("logo-yarn", 0x2C8EBB)
        case "bun": ("logo-bun", 0xFBF0DF)
        case "pip": ("logo-pypi", 0x4B8BBE)
        case "uv": ("logo-uv", 0xDE5FE9)
        case "go-mod", "go-build": ("logo-go", 0x00ADD8)
        case "deno": ("logo-deno", 0x70FFAF)
        case "composer": ("logo-composer", 0xC48B4A)
        case "cocoapods": ("logo-cocoapods", 0xEE3322)
        case "gradle": ("logo-gradle", 0x5BBFAD)
        case "xcode-derived-data", "xcode-archives", "simulator-devices", "simulator-caches", "xcode-previews", "xcode-cache": ("logo-xcode", 0x147EFB)
        case "cargo-registry": ("logo-rust", 0xDEA584)
        case "homebrew-downloads": ("logo-homebrew", 0xFBB040)
        case "docker-desktop": ("logo-docker", 0x2496ED)
        case "huggingface": ("logo-huggingface", 0xFFD21E)
        case "ollama-models": ("logo-ollama", 0xE6E9EE)
        case "cypress-binaries": ("logo-cypress", 0x69D3A7)
        case "jetbrains": ("logo-jetbrains", 0xE6E9EE)
        case "torch-hub": ("logo-pytorch", 0xEE4C2C)
        default: nil
        }
        // No Simple Icons logo: a system symbol in the tool's colour.
        let symbol: (String, UInt32)? = switch id {
        case "vscode-cache", "vscode-cached-data", "vscode-extension-downloads": ("chevron.left.forwardslash.chevron.right", 0x3B9EE8)
        case "cursor-cache", "cursor-cached-data": ("cursorarrow.rays", 0xE6E9EE)
        case "playwright-browsers": ("theatermasks.fill", 0x45BA4B)
        case "lmstudio-models": ("cpu", 0x8B6CEF)
        default: nil
        }
        if let symbol {
            return Ecosystem(id: id, name: id, logo: nil, color: Color(logo: symbol.1), symbol: symbol.0)
        }
        return Ecosystem(id: id, name: id, logo: logo?.0, color: logo.map { Color(logo: $0.1) } ?? Brand.muted)
    }

    /// Dev Stack items whose name starts with a known tool.
    static func of(tool name: String) -> Ecosystem? {
        let n = name.lowercased()
        let table: [(String, String, UInt32)] = [
            ("node", "logo-nodedotjs", 0x5FA04E), ("python", "logo-python", 0x4B8BBE), ("rust", "logo-rust", 0xDEA584),
            ("go", "logo-go", 0x00ADD8), ("flutter", "logo-flutter", 0x47C5FB), ("dart", "logo-dart", 0x40C4FF),
            ("openjdk", "logo-openjdk", 0xE76F00), ("java", "logo-openjdk", 0xE76F00), ("kotlin", "logo-kotlin", 0x9D7BFF),
            ("php", "logo-php", 0x8892BF), ("composer", "logo-composer", 0xC48B4A), ("swift", "logo-swift", 0xF05138),
            ("xcode", "logo-xcode", 0x147EFB), ("npm", "logo-npm", 0xCB3837), ("pnpm", "logo-pnpm", 0xF69220),
            ("yarn", "logo-yarn", 0x2C8EBB), ("bun", "logo-bun", 0xFBF0DF), ("deno", "logo-deno", 0x70FFAF),
            ("gradle", "logo-gradle", 0x5BBFAD), ("maven", "logo-apachemaven", 0xE0405A), ("uv", "logo-uv", 0xDE5FE9),
            ("cocoapods", "logo-cocoapods", 0xEE3322), ("dotnet", "logo-dotnet", 0x8B6CEF),
        ]
        guard let hit = table.first(where: { n == $0.0 || n.hasPrefix($0.0 + " ") || n.hasPrefix($0.0 + "@") || n.hasPrefix($0.0 + "-") }) else { return nil }
        return Ecosystem(id: hit.0, name: name, logo: hit.1, color: Color(logo: hit.2))
    }
}

extension Project {
    /// The languages in this project, biggest first.
    var ecosystems: [Ecosystem] {
        var bytes: [String: UInt64] = [:]
        for i in items { bytes[i.rule, default: 0] += i.bytes ?? 0 }
        return bytes.sorted { $0.value > $1.value }.map { Ecosystem.of(rule: $0.key) }
    }
}

/// A logo on a soft tile of its own colour.
struct EcosystemBadge: View {
    let ecosystem: Ecosystem
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(ecosystem.color.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(ecosystem.color.opacity(0.28), lineWidth: 1)
            if let logo = ecosystem.logo {
                Image(logo).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(ecosystem.color)
                    .padding(size * 0.2)
            } else {
                Image(systemName: ecosystem.symbol).font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(ecosystem.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .help(ecosystem.name)
    }
}

/// Up to two overlapping badges for a project's languages; one slot width so
/// names line up down a list.
struct EcosystemStack: View {
    let ecosystems: [Ecosystem]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(ecosystems.prefix(2)) { e in
                EcosystemBadge(ecosystem: e, size: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Brand.surface))
            }
        }
        .frame(width: size * 1.7, alignment: .leading)
    }
}
