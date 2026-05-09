import Foundation
import PDFKit
import CoreGraphics

/// Walks a PDF page's resource graph looking for spot colour declarations
/// (Separation and DeviceN colour spaces), recursing one level into placed
/// Form XObjects so spot colours buried in placed artwork — cutter
/// templates, brand-logo PDFs — are caught alongside page-level ones.
///
/// The implementation drops down to the `CGPDFPage` / `CGPDFDictionary` /
/// `CGPDFArray` C-level API because PDFKit's higher-level types don't
/// expose colour-space resources at all. Verbose, but the alternative is
/// content-stream parsing, which is much more code for marginal gains.
enum SpotColourExtractor {

    /// Names that appear in colorant lists but aren't real spot inks:
    /// the four CMYK process colorants, plus the `/All` and `/None`
    /// special separations used for crop marks and the like. Filtered
    /// out so the report only shows what production cares about.
    private static let nonSpotNames: Set<String> = [
        "Cyan", "Magenta", "Yellow", "Black",
        "All", "None"
    ]

    /// Spot colour names declared on this page (and in any Form XObjects
    /// it references), reported verbatim from the PDF, deduplicated and
    /// alphabetised so equal sets compare equal in the CSV.
    static func spotColours(in page: PDFPage) -> [String] {
        guard let cgPage = page.pageRef else { return [] }
        guard let pageDict = cgPage.dictionary else { return [] }

        let collector = SpotCollector()
        collectFromDict(pageDict, into: collector, depth: 0)
        return collector.names
            .filter { !nonSpotNames.contains($0) }
            .sorted()
    }

    // MARK: - Walking state

    /// Reference type so we can pass it through the C-callback
    /// `CGPDFDictionaryApplyFunction` via an unmanaged opaque pointer.
    private final class SpotCollector {
        var names: Set<String> = []
        /// Form XObjects we've already descended into. We hash the stream's
        /// raw address (via `unsafeBitCast`) because `CGPDFStreamRef`'s
        /// concrete Swift type isn't directly hashable across SDK versions.
        var visitedXObjects: Set<UnsafeRawPointer> = []
        /// Hard cap on recursion. One level catches the practical
        /// "placed cutter PDF" case; deeper nesting is rare and we'd
        /// rather miss it than risk spending unbounded time on a malformed
        /// document.
        let maxDepth = 4
    }

    private final class KeyCollector { var keys: [String] = [] }

    // MARK: - Resource walk

    private static func collectFromDict(
        _ dict: CGPDFDictionaryRef,
        into collector: SpotCollector,
        depth: Int
    ) {
        guard depth <= collector.maxDepth else { return }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return }

        // 1. Direct colour-space declarations on this page / form XObject.
        var csDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(res, "ColorSpace", &csDict),
           let cs = csDict {
            iterateColorSpaces(cs, collector: collector)
        }

        // 2. Recurse into Form XObjects to catch spots declared inside
        // placed artwork (the cutter / placed-logo case).
        var xoDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(res, "XObject", &xoDict),
           let xo = xoDict {
            recurseXObjects(xo, collector: collector, depth: depth + 1)
        }
    }

    // MARK: - ColorSpace dictionary

    private static func iterateColorSpaces(
        _ csDict: CGPDFDictionaryRef,
        collector: SpotCollector
    ) {
        // The C apply function calls our @convention(c) closure for every
        // (key, value) pair; we route the value through `inspectColorSpace`
        // via the unmanaged collector pointer.
        let info = Unmanaged.passUnretained(collector).toOpaque()
        CGPDFDictionaryApplyFunction(csDict, { _, object, info in
            guard let info else { return }
            let coll = Unmanaged<SpotCollector>.fromOpaque(info).takeUnretainedValue()
            // Fully-qualify the static call so the @convention(c) closure
            // doesn't pick up implicit Self/context.
            SpotColourExtractor.inspectColorSpace(object, collector: coll)
        }, info)
    }

    /// A ColorSpace entry is typically an array; could also be a name (e.g.
    /// `/DeviceRGB`) which we ignore — those aren't spot colours. Two array
    /// shapes produce spot names:
    ///   `[/Separation /Name /AlternateSpace /TintTransform]`
    ///   `[/DeviceN [/Name1 /Name2 …] /AlternateSpace /TintTransform …]`
    private static func inspectColorSpace(
        _ object: CGPDFObjectRef,
        collector: SpotCollector
    ) {
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array),
              let arr = array,
              CGPDFArrayGetCount(arr) >= 2 else { return }

        var typePtr: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(arr, 0, &typePtr),
              let tp = typePtr else { return }

        switch String(cString: tp) {
        case "Separation":
            var namePtr: UnsafePointer<CChar>?
            if CGPDFArrayGetName(arr, 1, &namePtr), let np = namePtr {
                collector.names.insert(String(cString: np))
            }
        case "DeviceN":
            var namesArr: CGPDFArrayRef?
            if CGPDFArrayGetArray(arr, 1, &namesArr), let na = namesArr {
                for i in 0..<CGPDFArrayGetCount(na) {
                    var n: UnsafePointer<CChar>?
                    if CGPDFArrayGetName(na, i, &n), let nn = n {
                        collector.names.insert(String(cString: nn))
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: - XObject recursion

    private static func recurseXObjects(
        _ xoDict: CGPDFDictionaryRef,
        collector: SpotCollector,
        depth: Int
    ) {
        // Two-pass to escape the C callback: first gather the keys, then
        // process them in a Swift loop where we have full closure access.
        for key in dictionaryKeys(xoDict) {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xoDict, key, &stream),
                  let s = stream else { continue }

            let streamKey = unsafeBitCast(s, to: UnsafeRawPointer.self)
            if collector.visitedXObjects.contains(streamKey) { continue }
            collector.visitedXObjects.insert(streamKey)

            guard let streamDict = CGPDFStreamGetDictionary(s) else { continue }

            // Image XObjects don't have nested /Resources, only Form
            // XObjects do. Skip non-Form to avoid wasted lookups.
            var subtypePtr: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypePtr),
                  let sp = subtypePtr,
                  String(cString: sp) == "Form" else { continue }

            collectFromDict(streamDict, into: collector, depth: depth)
        }
    }

    private static func dictionaryKeys(_ dict: CGPDFDictionaryRef) -> [String] {
        let collector = KeyCollector()
        let info = Unmanaged.passUnretained(collector).toOpaque()
        CGPDFDictionaryApplyFunction(dict, { keyPtr, _, info in
            guard let info else { return }
            let coll = Unmanaged<KeyCollector>.fromOpaque(info).takeUnretainedValue()
            coll.keys.append(String(cString: keyPtr))
        }, info)
        return collector.keys
    }
}
