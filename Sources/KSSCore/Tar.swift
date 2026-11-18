import Foundation

/// Minimal reader for the tar archives `renderPage` returns (ustar + pax headers).
public enum Tar {
    public struct Entry: Sendable {
        public var name: String
        public var data: Data
    }

    public enum TarError: Error { case truncated }

    public static func entries(_ blob: Data) throws -> [Entry] {
        let bytes = [UInt8](blob)
        var out: [Entry] = []
        var offset = 0
        var paxName: String?
        var longName: String?
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) { break }
            let size = octal(header[124..<136])
            let type = header[156]
            var name = cString(header[0..<100])
            let prefix = cString(header[345..<500])
            if !prefix.isEmpty, String(decoding: header[257..<262], as: UTF8.self) == "ustar" {
                name = prefix + "/" + name
            }
            let start = offset + 512
            guard start + size <= bytes.count else { throw TarError.truncated }
            let body = Data(bytes[start..<start + size])
            switch type {
            case UInt8(ascii: "x"):  // pax extended header for the next entry
                paxName = parsePax(body)["path"]
            case UInt8(ascii: "g"):  // global pax header
                break
            case UInt8(ascii: "L"):  // GNU long name
                longName = String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case UInt8(ascii: "0"), 0:
                out.append(Entry(name: paxName ?? longName ?? name, data: body))
                paxName = nil; longName = nil
            default:
                paxName = nil; longName = nil
            }
            offset = start + ((size + 511) / 512) * 512
        }
        return out
    }

    /// PNGs inside the archive, in natural page order.
    public static func pngs(_ blob: Data) throws -> [Data] {
        if blob.starts(with: pngMagic) { return [blob] }
        let found = try entries(blob).compactMap { entry -> (String, Data)? in
            guard entry.name.lowercased().hasSuffix(".png"), !entry.name.contains("PaxHeaders") else { return nil }
            guard let range = entry.data.range(of: Data(pngMagic), in: 0..<min(entry.data.count, 1032)) else { return nil }
            return (entry.name, entry.data.subdata(in: range.lowerBound..<entry.data.count))
        }
        return found.sorted { naturalLess($0.0, $1.0) }.map { $0.1 }
    }

    static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func octal(_ field: ArraySlice<UInt8>) -> Int {
        let s = String(decoding: field.prefix { $0 != 0 && $0 != 32 }, as: UTF8.self)
        return Int(s.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
    }

    private static func cString(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func parsePax(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let kv = line[line.index(after: space)...]
            if let eq = kv.firstIndex(of: "=") {
                result[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        return result
    }

    /// "page2.png" < "page10.png"
    public static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric]) == .orderedAscending
    }
}
