import Testing
import Foundation
@testable import FileShuffler

/// All nine of these inputs are real — pasted from a works order during
/// the spec discussion for the paste-link feature. They span Windows UNC,
/// SMB URLs (hostname *and* IP), `/Volumes/` paths, bare share-relative
/// strings, and a mix of straight/curly/no quotes. Each must collapse to
/// the same canonical `/Volumes/DimensionHub/...` URL.
@Suite("PathNormaliser — source role")
struct PathNormaliserSourceTests {

    // MARK: - Real intake samples

    @Test("UNC path with backslashes from Windows works order")
    func uncFromWindows() {
        let input = #"\\DIM-SVR\DimensionHub\Projects - Loreal\LDB Brands - Vichy, LRP, Cerave\Cerave\260662 LDB Boots Expert RR June Cerave\In-House Print\2D Supplied PRDN Artwork\Top Shelf"#
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects - Loreal/LDB Brands - Vichy, LRP, Cerave/Cerave/260662 LDB Boots Expert RR June Cerave/In-House Print/2D Supplied PRDN Artwork/Top Shelf"
        )))
    }

    @Test("smb:// URL with IP host")
    func smbWithIPHost() {
        let input = "smb://192.168.3.254/DimensionHub/Projects - Shopper Marketing/2026/261039 Skin Tint FSDU/Artwork/In-House Print/2D Supplied PROTO Artwork/P12 Pro Artist Skin Tint FSDU - PROTOTYPE ARTWORK"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects - Shopper Marketing/2026/261039 Skin Tint FSDU/Artwork/In-House Print/2D Supplied PROTO Artwork/P12 Pro Artist Skin Tint FSDU - PROTOTYPE ARTWORK"
        )))
    }

    @Test("UNC path wrapped in straight double quotes")
    func uncWrappedInDoubleQuotes() {
        let input = #""\\DIM-SVR\DimensionHub\Projects - Shopper Marketing\2026\260550 P11\Artwork\In-House Print\2D Supplied PRDN Artwork\P11 SM PRODUCTION ARTWORK""#
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects - Shopper Marketing/2026/260550 P11/Artwork/In-House Print/2D Supplied PRDN Artwork/P11 SM PRODUCTION ARTWORK"
        )))
    }

    @Test("smb:// URL with hostname")
    func smbWithHostname() {
        let input = "smb://dim-svr/DimensionHub/Projects/Pierre Fabre/261224 Avene P11a FSDU Header/In-House Print/2D Supplied PRDN Artwork/261224 Avene P11a FSDU Header_Folder"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects/Pierre Fabre/261224 Avene P11a FSDU Header/In-House Print/2D Supplied PRDN Artwork/261224 Avene P11a FSDU Header_Folder"
        )))
    }

    @Test("/Volumes/ path wrapped in single quotes")
    func volumesWrappedInSingleQuotes() {
        let input = "'/Volumes/DimensionHub/Projects/Better You/260993 Better You Bristol BOS/In-House Print/2D Supplied PROTO Artwork'"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects/Better You/260993 Better You Bristol BOS/In-House Print/2D Supplied PROTO Artwork"
        )))
    }

    @Test("Bare share-relative path that points at a PDF file")
    func bareShareRelativeFile() {
        let input = "DimensionHub/Projects/Dimension/Branding & Marketing/2023/Projects/New Starter Packs/New Starter Pack - PRINT_V3/Artwork Pack (REF PDF)/Dimension - New Starter Pack_AP (REF ONLY).pdf"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects/Dimension/Branding & Marketing/2023/Projects/New Starter Packs/New Starter Pack - PRINT_V3/Artwork Pack (REF PDF)/Dimension - New Starter Pack_AP (REF ONLY).pdf"
        )))
    }

    @Test("Plain /Volumes/ path with no quotes, ampersand in component")
    func plainVolumesAmpersand() {
        let input = "/Volumes/DimensionHub/Projects/Soap & Glory/258311 Walgreens S&G End Cap - Feb 25/In-House Print/2D Supplied PROTO Artwork"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects/Soap & Glory/258311 Walgreens S&G End Cap - Feb 25/In-House Print/2D Supplied PROTO Artwork"
        )))
    }

    @Test("Bare share-relative path, folder destination")
    func bareShareRelativeFolder() {
        let input = "DimensionHub/Projects - Shopper Marketing/2024/258192 P6/Artwork/In-House Print/2D Supplied PROTO Artwork/P6 Semi-Perm FSDU Tester Plates PROTO V2"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects - Shopper Marketing/2024/258192 P6/Artwork/In-House Print/2D Supplied PROTO Artwork/P6 Semi-Perm FSDU Tester Plates PROTO V2"
        )))
    }

    @Test("/Volumes/ path single-quoted, ampersand and apostrophe-like component")
    func volumesQuotedAmpersand() {
        let input = "'/Volumes/DimensionHub/Projects - VM/No7/2026/259950 P11 Diamond/Artwork/Print/In-House Print/2D Supplied PROTO Artwork/A&I Box Graphics'"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL(
            "Projects - VM/No7/2026/259950 P11 Diamond/Artwork/Print/In-House Print/2D Supplied PROTO Artwork/A&I Box Graphics"
        )))
    }

    // MARK: - Edge cases

    @Test("Curly smart quotes from Word/Outlook are stripped")
    func curlySmartQuotesStripped() {
        let input = "\u{201C}/Volumes/DimensionHub/Projects/Foo\u{201D}"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL("Projects/Foo")))
    }

    @Test("Percent-encoded spaces decode")
    func percentEncodedSpaces() {
        let input = "smb://dim-svr/DimensionHub/Projects%20-%20Loreal/Cerave"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL("Projects - Loreal/Cerave")))
    }

    @Test("file:/// URL with empty host resolves correctly")
    func fileUrlWithEmptyHost() {
        let input = "file:///Volumes/DimensionHub/Projects/Foo"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL("Projects/Foo")))
    }

    @Test("Wrong share via /Volumes/ is refused")
    func wrongShareUnderVolumes() {
        let input = "/Volumes/SomeOtherShare/Projects/foo"
        #expect(PathNormaliser.parseSource(input) == .wrongShare("SomeOtherShare"))
    }

    @Test("Wrong share via smb:// URL is refused")
    func wrongShareViaSmb() {
        let input = "smb://other-server/DifferentShare/Projects"
        #expect(PathNormaliser.parseSource(input) == .wrongShare("DifferentShare"))
    }

    @Test("Local path in user home is accepted as .local")
    func localUserHomePath() {
        let input = "/Users/luke/Desktop/job"
        #expect(PathNormaliser.parseSource(input) == .local(URL(fileURLWithPath: "/Users/luke/Desktop/job").standardizedFileURL))
    }

    @Test("Tilde-prefixed path is expanded and accepted as .local")
    func tildeExpansion() {
        guard case .local(let url) = PathNormaliser.parseSource("~/Desktop/job") else {
            Issue.record("expected .local for ~/Desktop/job")
            return
        }
        #expect(url.path.hasSuffix("/Desktop/job"))
        #expect(!url.path.contains("~"))
    }

    @Test("Empty / whitespace / lone-quote inputs are unrecognised")
    func emptyAndJunk() {
        #expect(PathNormaliser.parseSource("") == .unrecognised)
        #expect(PathNormaliser.parseSource("   ") == .unrecognised)
        #expect(PathNormaliser.parseSource("''") == .unrecognised)
        #expect(PathNormaliser.parseSource("\"\"") == .unrecognised)
    }

    @Test("Surrounding whitespace is tolerated")
    func surroundingWhitespace() {
        let input = "   /Volumes/DimensionHub/Projects/foo  "
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL("Projects/foo")))
    }

    @Test("Bare path with unknown first segment reports wrongShare")
    func bareUnknownSegmentReportsWrongShare() {
        // No scheme, no /Volumes/. Treat the first segment as a share name
        // so the operator gets a useful "share X is not DimensionHub"
        // message rather than a generic unrecognised error.
        #expect(PathNormaliser.parseSource("SomeFolder/inside") == .wrongShare("SomeFolder"))
    }

    @Test("Trailing slash is tolerated and stripped")
    func trailingSlash() {
        let input = "/Volumes/DimensionHub/Projects/Foo/"
        #expect(PathNormaliser.parseSource(input) == .onShare(volumeURL("Projects/Foo")))
    }

    private func volumeURL(_ rest: String) -> URL {
        URL(fileURLWithPath: "/Volumes/DimensionHub/" + rest).standardizedFileURL
    }
}

/// Destinations are unrestricted by policy: an operator may consolidate
/// outputs to the DimensionHub share, a totally different share, or
/// somewhere on local disk. Only "couldn't make sense of the input"
/// produces a refusal here.
@Suite("PathNormaliser — destination role")
struct PathNormaliserDestinationTests {

    @Test("DimensionHub destination is accepted")
    func dimensionHubAccepted() {
        let input = "/Volumes/DimensionHub/Output/Job 261144"
        #expect(PathNormaliser.parseDestination(input) == .ok(
            URL(fileURLWithPath: "/Volumes/DimensionHub/Output/Job 261144").standardizedFileURL
        ))
    }

    @Test("Other shares are accepted as destination")
    func otherShareAccepted() {
        let input = "/Volumes/Production/Output"
        #expect(PathNormaliser.parseDestination(input) == .ok(
            URL(fileURLWithPath: "/Volumes/Production/Output").standardizedFileURL
        ))
    }

    @Test("smb:// to a non-DimensionHub share is accepted as destination")
    func smbOtherShareAccepted() {
        let input = "smb://someserver/Production/Output"
        #expect(PathNormaliser.parseDestination(input) == .ok(
            URL(fileURLWithPath: "/Volumes/Production/Output").standardizedFileURL
        ))
    }

    @Test("Local path is accepted as destination")
    func localAccepted() {
        let input = "/Users/luke/Desktop/output"
        #expect(PathNormaliser.parseDestination(input) == .ok(
            URL(fileURLWithPath: "/Users/luke/Desktop/output").standardizedFileURL
        ))
    }

    @Test("Empty input is unrecognised for destinations too")
    func emptyUnrecognised() {
        #expect(PathNormaliser.parseDestination("") == .unrecognised)
        #expect(PathNormaliser.parseDestination("   ") == .unrecognised)
    }
}
