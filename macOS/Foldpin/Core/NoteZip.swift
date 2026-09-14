import Foundation
import zlib

/// Streaming ZIP64 (stored entries). Media bytes are preserved and never loaded
/// all at once. Layout follows PKWARE APPNOTE 6.3.10, sections 4.3 and 4.5.3.
nonisolated enum NoteZip {
    private struct Record { let name: Data; let size: UInt64; let crc: UInt32; let offset: UInt64 }
    static func write(_ entries: [NoteExport.Entry], to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var records: [Record] = []
        for entry in entries {
            try Task.checkCancellation()
            let name = Data(entry.path.utf8)
            guard name.count <= Int(UInt16.max), !entry.path.hasPrefix("/"),
                  !entry.path.split(separator: "/").contains("..") else { throw CocoaError(.fileWriteInvalidFileName) }
            let input: FileHandle?
            let expected: UInt64
            if let source = entry.source {
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size >= 0 else { throw NoteExportError.unavailable }
                expected = UInt64(size); input = try FileHandle(forReadingFrom: source)
            } else { input = nil; expected = UInt64(entry.data?.count ?? 0) }
            defer { try? input?.close() }
            let offset = try output.offset()
            var local = Data()
            local.u32(0x04034b50); local.u16(45); local.u16(0x0808); local.u16(0)
            local.u16(0); local.u16(0x21); local.u32(0); local.u32(.max); local.u32(.max)
            local.u16(UInt16(name.count)); local.u16(20); local.append(name)
            local.u16(1); local.u16(16); local.u64(expected); local.u64(expected)
            try output.write(contentsOf: local)
            var crc: uLong = 0, count: UInt64 = 0
            func append(_ data: Data) throws {
                try Task.checkCancellation()
                count += UInt64(data.count)
                guard count <= expected else { throw NoteExportError.changedResource }
                crc = data.withUnsafeBytes { buffer in crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
                try output.write(contentsOf: data)
            }
            if let input {
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try append(chunk) }
            } else if let data = entry.data { try append(data) }
            guard count == expected else { throw NoteExportError.changedResource }
            var descriptor = Data(); descriptor.u32(0x08074b50); descriptor.u32(UInt32(crc)); descriptor.u64(count); descriptor.u64(count)
            try output.write(contentsOf: descriptor)
            records.append(Record(name: name, size: count, crc: UInt32(crc), offset: offset))
        }
        let centralOffset = try output.offset()
        for record in records {
            var central = Data()
            central.u32(0x02014b50); central.u16(45); central.u16(45); central.u16(0x0808); central.u16(0)
            central.u16(0); central.u16(0x21); central.u32(record.crc); central.u32(.max); central.u32(.max)
            central.u16(UInt16(record.name.count)); central.u16(28); central.u16(0); central.u16(0); central.u16(0); central.u32(0); central.u32(.max)
            central.append(record.name); central.u16(1); central.u16(24); central.u64(record.size); central.u64(record.size); central.u64(record.offset)
            try output.write(contentsOf: central)
        }
        let endOffset = try output.offset(), centralSize = endOffset - centralOffset, count = UInt64(records.count)
        var end = Data()
        end.u32(0x06064b50); end.u64(44); end.u16(45); end.u16(45); end.u32(0); end.u32(0)
        end.u64(count); end.u64(count); end.u64(centralSize); end.u64(centralOffset)
        end.u32(0x07064b50); end.u32(0); end.u64(endOffset); end.u32(1)
        end.u32(0x06054b50); end.u16(0); end.u16(0); end.u16(.max); end.u16(.max); end.u32(.max); end.u32(.max); end.u16(0)
        try output.write(contentsOf: end)
        try output.synchronize()
    }
}

nonisolated private extension Data {
    mutating func u16(_ value: UInt16) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
