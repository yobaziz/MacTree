import Darwin

// Darwin exposes fsobj_type_t / VDIR / VREG / VLNK as the C enum `vtype`.
// Swift 6 no longer accepts UInt32(vtype) through the generic integer initializer,
// so provide the exact conversion used by FastScanner.
extension UInt32 {
    init(_ value: vtype) {
        self = UInt32(truncatingIfNeeded: value.rawValue)
    }
}
