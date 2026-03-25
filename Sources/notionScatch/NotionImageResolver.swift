import Foundation
import AppKit
import SQLite3
import CommonCrypto
import Security

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum NotionImageResolver {

    // MARK: - Main entry point

    static func resolve(clipboardHTML: String?, clipboardText: String?) async -> NSImage? {
        guard let attachment = parseAttachmentSource(html: clipboardHTML, text: clipboardText) else {
            return nil
        }

        guard let block = findBlock(fileId: attachment.fileId, fallbackSource: attachment.source) else {
            return nil
        }

        guard let cookies = decryptCookies() else {
            return nil
        }

        guard let signedURL = await fetchSignedURL(
            source: block.source,
            blockId: block.blockId,
            tokenV2: cookies.tokenV2,
            fileToken: cookies.fileToken
        ) else {
            return nil
        }

        return await downloadImage(from: signedURL)
    }

    // MARK: - Parse attachment from clipboard

    private static func parseAttachmentSource(html: String?, text: String?) -> (fileId: String, source: String)? {
        let pattern = #"attachment:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([^\s"')]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        for candidate in [html, text].compactMap({ $0 }) {
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let fullRange = Range(match.range(at: 0), in: candidate),
                  let fileIdRange = Range(match.range(at: 1), in: candidate) else {
                continue
            }

            let source = String(candidate[fullRange])
            let fileId = String(candidate[fileIdRange])
            return (fileId: fileId, source: source)
        }

        return nil
    }

    // MARK: - Query notion.db

    private static func findBlock(fileId: String, fallbackSource: String) -> (blockId: String, spaceId: String, source: String)? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notion/notion.db")
            .path

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, space_id, properties FROM block WHERE type='image' AND file_ids LIKE ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let searchTerm = "%\(fileId)%"
        sqlite3_bind_text(stmt, 1, searchTerm, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let idPtr = sqlite3_column_text(stmt, 0),
              let spacePtr = sqlite3_column_text(stmt, 1) else {
            return nil
        }

        let blockId = String(cString: idPtr)
        let spaceId = String(cString: spacePtr)

        // Extract source from properties JSON
        if let propsPtr = sqlite3_column_text(stmt, 2),
           let data = String(cString: propsPtr).data(using: .utf8),
           let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sourceArray = props["source"] as? [[Any]],
           let dbSource = sourceArray.first?.first as? String {
            return (blockId: blockId, spaceId: spaceId, source: dbSource)
        }

        return (blockId: blockId, spaceId: spaceId, source: fallbackSource)
    }

    // MARK: - Decrypt Notion Chromium cookies

    private static func decryptCookies() -> (tokenV2: String, fileToken: String)? {
        guard let keyData = keychainPassword(service: "Notion Safe Storage") else {
            return nil
        }

        let derivedKey = pbkdf2SHA1(password: keyData, salt: "saltysalt", iterations: 1003, keyLength: 16)

        let cookiePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notion/Partitions/notion/Cookies")
            .path

        var db: OpaquePointer?
        guard sqlite3_open_v2(cookiePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        guard let tokenV2 = decryptCookie(db: db, name: "token_v2", key: derivedKey),
              let fileToken = decryptCookie(db: db, name: "file_token", key: derivedKey) else {
            return nil
        }

        return (tokenV2: tokenV2, fileToken: fileToken)
    }

    private static func keychainPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func pbkdf2SHA1(password: Data, salt: String, iterations: UInt32, keyLength: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = Array(salt.utf8)
        _ = password.withUnsafeBytes { rawBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                password.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                iterations,
                &derived,
                keyLength
            )
        }
        return derived
    }

    private static func decryptCookie(db: OpaquePointer?, name: String, key: [UInt8]) -> String? {
        let sql = "SELECT encrypted_value FROM cookies WHERE name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let length = Int(sqlite3_column_bytes(stmt, 0))
        guard length > 3, let blob = sqlite3_column_blob(stmt, 0) else { return nil }

        let encrypted = Data(bytes: blob, count: length)

        // Chromium v10: "v10" (3 bytes) + AES-128-CBC ciphertext
        guard encrypted.prefix(3) == Data("v10".utf8) else { return nil }

        let ciphertext = Array(encrypted.dropFirst(3))
        let iv: [UInt8] = Array(repeating: 0x20, count: 16) // 16 spaces

        var decrypted = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            0,
            key, key.count,
            iv,
            ciphertext, ciphertext.count,
            &decrypted, decrypted.count,
            &decryptedLength
        )

        guard status == CCCryptorStatus(kCCSuccess), decryptedLength > 0 else { return nil }

        // Remove PKCS7 padding
        let padByte = Int(decrypted[decryptedLength - 1])
        if padByte >= 1 && padByte <= 16 {
            decryptedLength -= padByte
        }

        // Decode as latin1 (first CBC block may contain non-UTF-8 bytes)
        let rawString = String(bytes: decrypted[0..<decryptedLength], encoding: .isoLatin1) ?? ""

        // Find token start (skip garbled first CBC block)
        guard let tokenStart = rawString.range(of: "v0") else { return nil }

        let encoded = String(rawString[tokenStart.lowerBound...])
        return encoded.removingPercentEncoding ?? encoded
    }

    // MARK: - Notion API

    private static func fetchSignedURL(source: String, blockId: String, tokenV2: String, fileToken: String) async -> URL? {
        guard let endpoint = URL(string: "https://www.notion.so/api/v3/getSignedFileUrls") else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token_v2=\(tokenV2); file_token=\(fileToken)", forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "urls": [[
                "url": source,
                "permissionRecord": [
                    "table": "block",
                    "id": blockId
                ]
            ]]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signedUrls = json["signedUrls"] as? [String],
              let first = signedUrls.first else {
            return nil
        }

        return URL(string: first)
    }

    // MARK: - Download

    private static func downloadImage(from url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return NSImage(data: data)
    }
}
