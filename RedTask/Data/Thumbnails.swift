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

/// Запись миниатюры в zip: смещение локального заголовка, сжатый и исходный размер, метод (0 или 8).
struct ZipEntry: Equatable, Sendable {
    var name: String
    var localOffset: Int
    var compressedSize: Int
    var method: Int
    var rawSize = 0
}

/// Миниатюры внутри документа по порядку предпочтения: ODF, затем OOXML. wmf/emf не показываем.
private let thumbnailNames = ["Thumbnails/thumbnail.png", "docProps/thumbnail.jpeg", "docProps/thumbnail.jpg", "docProps/thumbnail.png"]

/// Запись миниатюры по хвосту файла размера size (набор zip_tail): центральный каталог должен целиком лежать в хвосте.
/// Zip читается по центральному каталогу: при записи потоком (data descriptor) размеры в локальном заголовке нулевые.
/// ponytail: zip64 не поддержан.
func zipTailEntry(size: Int, tail: Data) -> ZipEntry? {
    let b = [UInt8](tail), base = size - b.count
    func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : -1 }
    func u32(_ o: Int) -> Int { o >= 0 && o + 4 <= b.count ? u16(o) | u16(o + 2) << 16 : -1 }
    // конец центрального каталога: с конца, комментарий архива до 64 КБ
    guard base >= 0, b.count >= 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 22 - 65535), by: -1)
        .first(where: { u32($0) == 0x06054b50 }) else { return nil }
    var found: [String: ZipEntry] = [:]
    var p = u32(eocd + 16) - base
    guard p >= 0 else { return nil }
    for _ in 0..<max(0, u16(eocd + 10)) {
        guard u32(p) == 0x02014b50, p + 46 <= b.count else { return nil }
        let n = u16(p + 28), name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + n)], as: UTF8.self)
        if thumbnailNames.contains(name) {
            found[name] = ZipEntry(name: name, localOffset: u32(p + 42), compressedSize: u32(p + 20), method: u16(p + 10), rawSize: u32(p + 24))
        }
        p += 46 + n + u16(p + 30) + u16(p + 32)
    }
    return thumbnailNames.lazy.compactMap { found[$0] }.first
}

/// Данные записи из байтов, начинающихся с её локального заголовка (второй Range или весь файл).
func zipEntryData(_ e: ZipEntry, local: Data) -> Data? {
    let b = [UInt8](local)
    func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : -1 }
    guard b.count >= 30, b[0] == 0x50, b[1] == 0x4b, b[2] == 3, b[3] == 4, e.rawSize > 0, e.rawSize < 32 << 20 else { return nil }
    let start = 30 + u16(26) + u16(28)
    guard e.compressedSize > 0, start + e.compressedSize <= b.count else { return nil }
    let packed = b[start..<(start + e.compressedSize)]
    switch e.method {
    case 0: return e.compressedSize == e.rawSize ? Data(packed) : nil
    case 8:
        #if canImport(Compression)
        var out = [UInt8](repeating: 0, count: e.rawSize)
        let n = Array(packed).withUnsafeBufferPointer { src in
            compression_decode_buffer(&out, e.rawSize, src.baseAddress!, e.compressedSize, nil, COMPRESSION_ZLIB)
        }
        return n == e.rawSize ? Data(out) : nil
        #else
        return nil
        #endif
    default: return nil
    }
}

/// Встроенная миниатюра документа (набор `embedded_thumbnail`): ODF — Thumbnails/thumbnail.png,
/// OOXML — docProps/thumbnail.jpeg|.jpg|.png. Методы 0 и 8.
func embeddedThumbnail(_ data: Data) -> Data? {
    guard let e = zipTailEntry(size: data.count, tail: data), e.localOffset >= 0, e.localOffset < data.count else { return nil }
    return zipEntryData(e, local: data.subdata(in: e.localOffset..<data.count))
}
