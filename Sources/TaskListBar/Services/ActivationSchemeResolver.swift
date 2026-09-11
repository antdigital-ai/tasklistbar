import Foundation

/// Extracts and ranks URL schemes that are safe enough to use as an app-activation fallback.
/// Kept independent from AppKit so the selection rules can be unit tested.
enum ActivationSchemeResolver {
    private static let genericSchemes: Set<String> = [
        "http", "https", "file", "mailto", "ftp", "tel", "sms", "webcal", "afp", "smb", "cifs",
        "ssh", "vnc", "itms", "itms-apps", "facetime", "facetime-audio", "maps", "x-man-page"
    ]
    private static let rejectedFragments = [
        "oauth", "callback", "uninstall", "helper"
    ]
    private static let rejectedTokens: Set<String> = [
        "license", "update", "auth", "prefs", "feed"
    ]
    private static let weakTokens: Set<String> = [
        "com", "org", "net", "mac", "app", "apps", "ios", "osx", "www", "desktop", "exclusive", "work",
        "inc", "corp", "corporation", "company", "software", "technologies"
    ]

    static func candidates(
        infoDictionary: [String: Any],
        bundleIdentifier: String?,
        localizedName: String?
    ) -> [String] {
        guard let types = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] else { return [] }

        let preferredIdentityValues = [
            localizedName,
            infoDictionary["CFBundleDisplayName"] as? String,
            infoDictionary["CFBundleName"] as? String
        ].compactMap { $0 }
        let identityValues = preferredIdentityValues + [
            bundleIdentifier,
            infoDictionary["CFBundleExecutable"] as? String
        ].compactMap { $0 }
        let preferredIdentityTokens = tokens(in: preferredIdentityValues)
        let preferredIdentityCompacts = Set(preferredIdentityValues.map(compact).filter { $0.count >= 4 })
        let identityTokens = tokens(in: identityValues)
        let identityCompacts = Set(identityValues.map(compact).filter { $0.count >= 4 })

        var seen = Set<String>()
        var ranked: [(scheme: String, score: Int, order: Int)] = []
        var order = 0

        for type in types {
            let descriptor = [
                type["CFBundleURLName"] as? String,
                type["CFBundleTypeRole"] as? String
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            let descriptorIsRejected = isRejectedPurpose(descriptor)

            for rawScheme in type["CFBundleURLSchemes"] as? [String] ?? [] {
                defer { order += 1 }
                let scheme = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !descriptorIsRejected,
                      isValid(scheme),
                      !genericSchemes.contains(scheme),
                      !isRejectedPurpose(scheme),
                      seen.insert(scheme).inserted
                else { continue }

                ranked.append((
                    scheme,
                    score(
                        scheme: scheme,
                        preferredIdentityTokens: preferredIdentityTokens,
                        preferredIdentityCompacts: preferredIdentityCompacts,
                        identityTokens: identityTokens,
                        identityCompacts: identityCompacts
                    ),
                    order
                ))
            }
        }

        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }.map(\.scheme)
    }

    private static func isValid(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return !scheme.isEmpty && scheme.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isRejectedPurpose(_ value: String) -> Bool {
        let lower = value.lowercased()
        if rejectedFragments.contains(where: { lower.contains($0) }) { return true }
        let pieces = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !pieces.isDisjoint(with: rejectedTokens)
    }

    private static func score(
        scheme: String,
        preferredIdentityTokens: Set<String>,
        preferredIdentityCompacts: Set<String>,
        identityTokens: Set<String>,
        identityCompacts: Set<String>
    ) -> Int {
        let schemeCompact = compact(scheme)
        let schemeTokens = tokens(in: [scheme])

        if preferredIdentityCompacts.contains(schemeCompact) || preferredIdentityTokens.contains(scheme) {
            return 120
        }
        if !schemeTokens.isDisjoint(with: preferredIdentityTokens) {
            return 110
        }
        if identityCompacts.contains(schemeCompact) || identityTokens.contains(scheme) {
            return 100
        }
        if !schemeTokens.isDisjoint(with: identityTokens) {
            return 90
        }
        if identityCompacts.contains(where: { value in
            value.count >= 4 && (value.contains(schemeCompact) || schemeCompact.contains(value))
        }) {
            return 75
        }
        if identityTokens.contains(where: { token in
            token.count >= 4 && (schemeCompact.contains(token) || token.contains(schemeCompact))
        }) {
            return 70
        }
        // A bundle explicitly owns every declared scheme. Preserve declaration order
        // for uncommon products whose protocol name does not resemble the app name.
        return 10
    }

    private static func tokens(in values: [String]) -> Set<String> {
        var result = Set<String>()
        for value in values {
            for piece in value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = String(piece)
                guard token.count >= 2, !weakTokens.contains(token) else { continue }
                result.insert(token)
            }
        }
        return result
    }

    private static func compact(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
