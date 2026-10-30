import Foundation
#if canImport(Compression)
import Compression
#endif

/// Откуда миниатюра в строке вложения (spec 4.1, набор `thumbnail_source`).
enum ThumbnailSource: String, Sendable {
    /// attachments/thumbnail/{id}/200 — Redmine рендерит картинки и первую страницу PDF.
    case server
    /// Миниатюра внутри уже скачанного ODF/OOXML.
    case embedded
    case none
}

func thumbnailSource(filename: String, contentType: String?) -> ThumbnailSource {
    let ext = (filename as NSString).pathExtension.lowercased()
    let type = (contentType ?? "").lowercased()
    if type.hasPrefix("image/") || type == "application/pdf"
        || ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "pdf"].contains(ext) { return .server }
    if ["odt", "ods", "odp", "odg", "docx", "xlsx", "pptx"].contains(ext) { return .embedded }
    return .none
}

/// Встроенная миниатюра документа (набор `embedded_thumbnail`): ODF — Thumbnails/thumbnail.png,
/// OOXML — docProps/thumbnail.jpeg|.jpg|.png. Zip читается по центральному каталогу: при записи потоком
/// (data descriptor) размеры в локальном заголовке нулевые. Методы 0 и 8; zip64 не поддержан.
func embeddedThumbnail(_ data: Data) -> Data? {
    let b = [UInt8](data)
    func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : -1 }
    func u32(_ o: Int) -> Int { o + 4 <= b.count ? u16(o) | u16(o + 2) << 16 : -1 }
    // конец центрального каталога: с конца, комментарий архива до 64 КБ
    guard b.count >= 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 22 - 65535), by: -1)
        .first(where: { u32($0) == 0x06054b50 }) else { return nil }
    let names = ["Thumbnails/thumbnail.png", "docProps/thumbnail.jpeg", "docProps/thumbnail.jpg", "docProps/thumbnail.png"]
    var found: [String: (method: Int, size: Int, raw: Int, local: Int)] = [:]
    var p = u32(eocd + 16)
    for _ in 0..<max(0, u16(eocd + 10)) {
        guard u32(p) == 0x02014b50, p + 46 <= b.count else { return nil }
        let n = u16(p + 28), name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + n)], as: UTF8.self)
        if names.contains(name) { found[name] = (u16(p + 10), u32(p + 20), u32(p + 24), u32(p + 42)) }
        p += 46 + n + u16(p + 30) + u16(p + 32)
    }
    guard let e = names.lazy.compactMap({ found[$0] }).first, u32(e.local) == 0x04034b50,
          e.raw > 0, e.raw < 32 << 20 else { return nil }
    let start = e.local + 30 + u16(e.local + 26) + u16(e.local + 28)
    guard e.size > 0, start + e.size <= b.count else { return nil }
    let packed = b[start..<(start + e.size)]
    switch e.method {
    case 0: return e.size == e.raw ? Data(packed) : nil
    case 8:
        #if canImport(Compression)
        var out = [UInt8](repeating: 0, count: e.raw)
        let n = Array(packed).withUnsafeBufferPointer { src in
            compression_decode_buffer(&out, e.raw, src.baseAddress!, e.size, nil, COMPRESSION_ZLIB)
        }
        return n == e.raw ? Data(out) : nil
        #else
        return nil
        #endif
    default: return nil
    }
}
