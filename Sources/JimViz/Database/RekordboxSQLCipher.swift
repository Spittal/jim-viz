import Foundation
import CryptoKit
import CommonCrypto

/// Decrypts Rekordbox 6/7's `master.db` (SQLCipher 4 page format) in-memory or to a temporary file,
/// replaying uncheckpointed WAL frames so newly played tracks are immediately visible.
enum RekordboxSQLCipher {
    /// The universal passphrase for Rekordbox 6 and 7 master.db.
    static let passphrase = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"
    static let pageSize = 4096
    static let reserve = 80 // 16-byte IV + 64-byte HMAC-SHA512
    static let saltLen = 16
    static let kdfIterations: UInt32 = 256_000
    static let hmacKdfIterations: UInt32 = 2
    static let sqliteHeader = "SQLite format 3\0".utf8

    enum DecryptError: LocalizedError {
        case fileNotFound(URL)
        case invalidSize(Int)
        case hmacMismatch(page: UInt32)
        case cipherFailure(status: Int32)
        case badWal

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let u): return "File not found: \(u.path)"
            case .invalidSize(let s): return "Database size \(s) is not a multiple of \(RekordboxSQLCipher.pageSize)"
            case .hmacMismatch(let p): return "HMAC mismatch on page \(p)"
            case .cipherFailure(let st): return "AES decryption failed with status \(st)"
            case .badWal: return "Malformed WAL header"
            }
        }
    }

    struct Keys {
        let key: [UInt8]
        let hmacKey: [UInt8]
    }

    static func deriveKeys(passphrase: String, salt: Data) -> Keys {
        var key = [UInt8](repeating: 0, count: 32)
        _ = salt.withUnsafeBytes { sPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, passphrase.utf8.count,
                sPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                kdfIterations,
                &key, 32
            )
        }

        let hmacSalt = salt.map { $0 ^ 0x3a }
        var hmacKey = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            key, 32,
            hmacSalt, hmacSalt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            hmacKdfIterations,
            &hmacKey, 32
        )

        return Keys(key: key, hmacKey: hmacKey)
    }

    /// Decrypts a single 4096-byte page. Page number is 1-based.
    static func decryptPage(keys: Keys, pageNo: UInt32, pageData: Data) throws -> Data {
        let isPage1 = pageNo == 1 && pageData.count == pageSize
        let dataStart = isPage1 ? saltLen : 0
        let dataEnd = pageSize - reserve
        let ciphertext = pageData.subdata(in: dataStart..<dataEnd)
        let iv = pageData.subdata(in: dataEnd..<dataEnd + 16)
        let mac = pageData.subdata(in: dataEnd + 16..<dataEnd + 80)

        var hmac = HMAC<SHA512>(key: SymmetricKey(data: keys.hmacKey))
        hmac.update(data: ciphertext)
        hmac.update(data: iv)
        var pageNoLE = pageNo.littleEndian
        withUnsafeBytes(of: &pageNoLE) { hmac.update(data: $0) }
        guard Data(hmac.finalize()) == mac else {
            throw DecryptError.hmacMismatch(page: pageNo)
        }

        var decrypted = [UInt8](repeating: 0, count: ciphertext.count)
        var numBytesDecrypted = 0
        let status = keys.key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { ivPtr in
                ciphertext.withUnsafeBytes { cPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), // No padding
                        kPtr.baseAddress!, 32,
                        ivPtr.baseAddress!,
                        cPtr.baseAddress!, ciphertext.count,
                        &decrypted, decrypted.count,
                        &numBytesDecrypted
                    )
                }
            }
        }
        guard status == 0 else {
            throw DecryptError.cipherFailure(status: status)
        }

        var out = isPage1 ? Data(sqliteHeader) : Data()
        out.append(contentsOf: decrypted)
        if out.count < pageSize {
            out.append(Data(repeating: 0, count: pageSize - out.count))
        }
        return out
    }

    /// Decrypts `master.db` and merges `master.db-wal` into a plaintext SQLite database at `destinationURL`.
    static func decrypt(dbURL: URL, walURL: URL?, destinationURL: URL) throws {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw DecryptError.fileNotFound(dbURL)
        }
        let dbData = try Data(contentsOf: dbURL)
        guard dbData.count >= pageSize, dbData.count % pageSize == 0 else {
            throw DecryptError.invalidSize(dbData.count)
        }

        let salt = dbData.prefix(saltLen)
        let keys = deriveKeys(passphrase: passphrase, salt: salt)

        let totalPages = dbData.count / pageSize
        var pages = [Data]()
        pages.reserveCapacity(totalPages)

        for p in 0..<totalPages {
            let slice = dbData.subdata(in: (p * pageSize)..<((p + 1) * pageSize))
            let dec = try decryptPage(keys: keys, pageNo: UInt32(p + 1), pageData: slice)
            pages.append(dec)
        }

        // Replay WAL frames if present
        if let walURL, FileManager.default.fileExists(atPath: walURL.path),
           let walData = try? Data(contentsOf: walURL), walData.count >= 32 {
            let magic = walData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            if magic == 0x377f0682 || magic == 0x377f0683 {
                let salt1 = walData.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let salt2 = walData.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                var off = 32
                let frameLen = 24 + pageSize
                var pending = [(UInt32, Data)]()

                while off + frameLen <= walData.count {
                    let fh = walData.subdata(in: off..<off + 24)
                    let fSalt1 = fh.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    let fSalt2 = fh.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    if fSalt1 != salt1 || fSalt2 != salt2 { break }

                    let pageNo = fh.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    let commitSize = fh.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    let framePage = walData.subdata(in: off + 24..<off + frameLen)

                    if let dec = try? decryptPage(keys: keys, pageNo: pageNo, pageData: framePage) {
                        pending.append((pageNo, dec))
                        if commitSize != 0 {
                            for (pNo, pData) in pending {
                                let idx = Int(pNo - 1)
                                if idx < pages.count {
                                    pages[idx] = pData
                                } else {
                                    while pages.count < idx { pages.append(Data(repeating: 0, count: pageSize)) }
                                    pages.append(pData)
                                }
                            }
                            pending.removeAll()
                        }
                    } else {
                        break
                    }
                    off += frameLen
                }
            }
        }

        // Fix database size in pages at offset 28..32 of page 1
        var countBE = UInt32(pages.count).bigEndian
        withUnsafeBytes(of: &countBE) { countBytes in
            pages[0].replaceSubrange(28..<32, with: countBytes)
        }

        var outputData = Data()
        outputData.reserveCapacity(pages.count * pageSize)
        for p in pages { outputData.append(p) }
        try outputData.write(to: destinationURL, options: .atomic)
    }
}
