import Foundation

// ByteCountFormatter is configured once and then only used for read-only formatting
// in MacTree. Marking the Foundation formatter as unchecked Sendable keeps Swift 6
// strict-concurrency diagnostics from rejecting the shared immutable formatter.
extension ByteCountFormatter: @unchecked @retroactive Sendable {}
