import Foundation

/// Turns whatever an operator pastes from a works order into a tidy
/// `/Volumes/...` URL plus a classification of *where* the path points.
/// Works orders arrive in a long tail of formats — Windows UNC, smb URLs
/// with hostname or IP, already-mounted `/Volumes/` paths, and bare
/// share-relative strings — sometimes wrapped in straight or curly
/// quotes, sometimes percent-encoded.
///
/// The base parser (`parse(_:)`) is pure and role-neutral: it returns the
/// URL plus a `Classification` (DimensionHub / other share / local). The
/// role-specific helpers `parseSource(_:)` and `parseDestination(_:)`
/// then apply the policy each input role demands — sources only accept
/// DimensionHub or local, destinations accept anywhere.
///
/// Keeping the parser pure means the rules stay easy to lock down with
/// table-driven tests against real intake samples.
enum PathNormaliser {

    /// Canonical share name. The only network share sources may live on.
    static let canonicalShare = "DimensionHub"

    /// Server URL used for auto-mount when `/Volumes/DimensionHub` is
    /// absent. Hostname rather than IP so a DHCP reshuffle doesn't break
    /// the mount; Keychain handles credentials from the operator's first
    /// Finder connection.
    static let canonicalServerURL = URL(string: "smb://dim-svr/DimensionHub")!

    /// Where a parsed path actually points. The role-specific helpers
    /// translate this into accept/refuse per the source vs destination
    /// policy.
    enum Classification: Equatable {
        /// Path is rooted under `/Volumes/DimensionHub/`. URL may not yet
        /// exist on disk if the share isn't mounted.
        case dimensionHub
        /// Path is under `/Volumes/<other>/`, where `<other>` is captured.
        /// Sources refuse this; destinations accept it.
        case otherShare(String)
        /// Anywhere not under `/Volumes/` — e.g. `~/Desktop/...`, an
        /// external drive, or `/Users/<name>/...`. Both roles accept it.
        case local
    }

    struct Parsed: Equatable {
        let url: URL
        let classification: Classification
    }

    enum Outcome: Equatable {
        case parsed(Parsed)
        /// Couldn't make sense of the input.
        case unrecognised
    }

    /// Pure parse — no IO, no policy. Returns the URL the input most
    /// likely refers to, plus a classification of where on the filesystem
    /// it falls. Callers apply role-specific accept/refuse rules.
    static func parse(_ raw: String) -> Outcome {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripWrappingQuotes(s)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .unrecognised }

        // Percent-decode if it looks encoded. Browser-copied links and a
        // few internal tools emit `%20` for spaces.
        if s.contains("%"), let decoded = s.removingPercentEncoding {
            s = decoded
        }

        // Backslashes → forward slashes. Real DimensionHub path components
        // never contain a literal `\`, so this is safe and collapses both
        // Windows UNC and a handful of half-converted links to one shape.
        s = s.replacingOccurrences(of: "\\", with: "/")

        s = stripSchemeAndHost(s)

        if s.hasPrefix("~") {
            s = (s as NSString).expandingTildeInPath
        }

        if s.hasPrefix("/Volumes/") {
            return classifyShareRelative(String(s.dropFirst("/Volumes/".count)))
        }
        if s.hasPrefix("/") {
            return .parsed(Parsed(
                url: URL(fileURLWithPath: s).standardizedFileURL,
                classification: .local
            ))
        }
        return classifyShareRelative(s)
    }

    // MARK: - Role-specific helpers

    /// Result of evaluating a paste as a *source* folder. Sources must be
    /// on DimensionHub or fully local — anything on another share is
    /// refused with the share name surfaced for the error message.
    enum SourceResult: Equatable {
        case onShare(URL)
        case local(URL)
        case wrongShare(String)
        case unrecognised
    }

    static func parseSource(_ raw: String) -> SourceResult {
        switch parse(raw) {
        case .unrecognised:
            return .unrecognised
        case .parsed(let p):
            switch p.classification {
            case .dimensionHub: return .onShare(p.url)
            case .local: return .local(p.url)
            case .otherShare(let name): return .wrongShare(name)
            }
        }
    }

    /// Result of evaluating a paste as a *destination* folder. Any
    /// classification is acceptable — the operator may consolidate
    /// outputs to local disk, another share, or back into DimensionHub.
    enum DestinationResult: Equatable {
        case ok(URL)
        case unrecognised
    }

    static func parseDestination(_ raw: String) -> DestinationResult {
        switch parse(raw) {
        case .unrecognised: return .unrecognised
        case .parsed(let p): return .ok(p.url)
        }
    }

    // MARK: - Internals

    /// Whatever follows the share name should be the actual job path.
    /// Returns DimensionHub when the first segment matches the canonical
    /// share, otherwise reports the share name verbatim so the caller
    /// can decide whether to accept or refuse it.
    private static func classifyShareRelative(_ raw: String) -> Outcome {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return .unrecognised }
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let share = comps.first else { return .unrecognised }
        let path = "/Volumes/" + comps.joined(separator: "/")
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if share == canonicalShare {
            return .parsed(Parsed(url: url, classification: .dimensionHub))
        }
        return .parsed(Parsed(url: url, classification: .otherShare(share)))
    }

    /// Drop a known URL scheme and the host segment that follows it.
    /// After step `s = s.replacingOccurrences(of: "\\", with: "/")` a
    /// Windows UNC path also begins `//host/share/...`, so the same
    /// "drop two segments" rule covers both.
    private static func stripSchemeAndHost(_ s: String) -> String {
        let lowered = s.lowercased()
        for scheme in ["smb://", "afp://", "cifs://", "file://"] {
            if lowered.hasPrefix(scheme) {
                let afterScheme = String(s.dropFirst(scheme.count))
                // Empty host (`file:///path`) — keep the leading slash;
                // there is no host segment to drop.
                if afterScheme.hasPrefix("/") { return afterScheme }
                return dropFirstSegment(afterScheme)
            }
        }
        if s.hasPrefix("//") {
            return dropFirstSegment(String(s.dropFirst(2)))
        }
        return s
    }

    private static func dropFirstSegment(_ s: String) -> String {
        guard let slash = s.firstIndex(of: "/") else { return "" }
        return String(s[s.index(after: slash)...])
    }

    /// Strip a single matched pair of wrapping quotes — straight `"`/`'`
    /// or the curly variants Word/Outlook insert when a path is pasted
    /// inside a sentence. Mismatched quotes are left alone so an
    /// accidental leading `'` becomes an `.unrecognised`, not a silently
    /// mangled path.
    private static func stripWrappingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}"),
        ]
        for (open, close) in pairs where s.first == open && s.last == close {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
