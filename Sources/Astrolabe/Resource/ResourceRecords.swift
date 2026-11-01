import MachO

/// One `@Resource` type, as the macro writes it into the binary. `type` writes the type into the
/// `any Resource.Type` its argument points at.
///
/// Not API: only `@Resource` writes these, and only `ResourceRecords` reads them.
public typealias __ResourceRecord = (
    magic: UInt32,
    type: @convention(c) (UnsafeMutableRawPointer) -> Void
)

/// Finds every `@Resource` type linked into the process, so the engine can decode any record in
/// `records.json` at launch, whether or not `body` declares its type yet.
///
/// `@Resource` puts a `__ResourceRecord` in `__DATA_CONST,__astrolabe_res` and marks it `@used`,
/// so neither the optimizer nor the linker strips it. The linker gathers every record in an
/// image into the one section; this walks each loaded image's.
enum ResourceRecords {
    /// `ResourceMacro` writes these three as literals: keep them in sync.
    static let segment = "__DATA_CONST"
    static let section = "__astrolabe_res"
    /// Marks a record, so stray bytes in the section are never called.
    static let magic: UInt32 = 0x6173_7472  // "astr"

    /// Every `@Resource` type in the images loaded so far.
    static func linkedTypes() -> [any Resource.Type] {
        var types: [any Resource.Type] = []
        for image in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(image) else { continue }
            var size: UInt = 0
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            guard let start = getsectiondata(header64, segment, section, &size) else { continue }
            let bytes = UnsafeRawBufferPointer(start: start, count: Int(size))
            let stride = MemoryLayout<__ResourceRecord>.stride
            for offset in Swift.stride(from: 0, through: bytes.count - stride, by: stride) {
                let record = bytes.load(fromByteOffset: offset, as: __ResourceRecord.self)
                guard record.magic == magic else { continue }
                types.append(withUnsafeTemporaryAllocation(of: (any Resource.Type).self, capacity: 1) { slot in
                    record.type(slot.baseAddress!)
                    return slot.baseAddress!.move()
                })
            }
        }
        return types
    }
}
