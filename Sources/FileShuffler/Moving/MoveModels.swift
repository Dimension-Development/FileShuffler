import Foundation

/// One completed move, kept in the in-memory journal so Undo can reverse it
/// exactly. We capture both URLs because the source filename can differ from
/// the destination filename only by whitespace/case under the matcher's
/// normalisation rules — we don't want Undo to second-guess the original.
struct Move: Hashable, Sendable {
    let src: URL
    let dst: URL
}

/// What to do when the destination already exists. The "ask" case kicks the
/// decision up to the user; the "all" cases are sticky once chosen, applied
/// to every subsequent collision in the same apply pass.
enum CollisionPolicy: Equatable, Sendable {
    case ask
    case skipAll
    case replaceAll
}

/// User's answer to a single collision prompt.
enum CollisionDecision: Equatable, Sendable {
    case skip(forAll: Bool)
    case replace(forAll: Bool)
    case cancel
}

/// Snapshot of progress emitted as each match is processed. We send these on
/// the main actor so SwiftUI can bind directly without bouncing threads.
struct MoveProgress: Equatable, Sendable {
    let total: Int
    let done: Int
    let current: String        // relative path of the in-flight item
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// Outcome of a single apply pass. The journal is `moved` — Undo iterates it
/// in reverse to put each file back. `skipped` and `errors` are surfaced in
/// the summary so the operator can spot anything they need to follow up.
struct MoveResult: Sendable {
    var moved: [Move]
    var skipped: [Match]
    var errors: [MoveError]
    var stoppedEarly: Bool

    var hasIssues: Bool { !skipped.isEmpty || !errors.isEmpty || stoppedEarly }
}

struct MoveError: Sendable {
    let match: Match
    let message: String        // pre-formatted; raw NSError details are not Sendable
}

/// Outcome of an Undo pass. We always try every recorded move so that one
/// failure doesn't block the rest.
struct UndoResult: Sendable {
    var reverted: [Move]
    var errors: [String]
    var hasIssues: Bool { !errors.isEmpty }
}
