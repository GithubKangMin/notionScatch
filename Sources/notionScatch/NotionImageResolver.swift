import Foundation
import AppKit
import SQLite3
import CommonCrypto
import Security

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum NotionImageResolver {

    // MARK: - Main entry point

    static func resolve(clipboardHTML: String?, clipboardText: String?) async -> NSImage? {
        await resolveWithDebug(clipboardHTML: clipboardHTML, clipboardText: clipboardText).0
    }

    static func resolveWithDebug(clipboardHTML: String?, clipboardText: String?) async -> (NSImage?, String) {
        var log = ""

        guard let attachment = parseAttachmentSource(html: clipboardHTML, text: clipboardText) else {
            log += "❌ attachment URL 파싱 실패 (HTML에 attachment:UUID:source 패턴 없음)\n"
            return (nil, log)
        }
        log += "✅ attachment 파싱 성공: fileId=\(attachment.fileId)\n"

        guard let block = findBlock(fileId: attachment.fileId, fallbackSource: attachment.source) else {
            log += "❌ notion.db에서 블록을 찾지 못함\n"
            return (nil, log)
        }
        log += "✅ DB 블록 찾음: blockId=\(block.blockId)\n"

        guard let cookies = decryptCookies() else {
            log += "❌ 쿠키 복호화 실패 (키체인 'Notion Safe Storage' 접근 불가)\n"
            return (nil, log)
        }
        log += "✅ 쿠키 복호화 성공\n"

        guard let signedURL = await fetchSignedURL(
            source: block.source,
            blockId: block.blockId,
            tokenV2: cookies.tokenV2,
            fileToken: cookies.fileToken
        ) else {
            log += "❌ signed URL 가져오기 실패 (API 오류 또는 인증 실패)\n"
            return (nil, log)
        }
        log += "✅ signed URL 획득\n"

        guard let image = await downloadImage(from: signedURL) else {
            log += "❌ 이미지 다운로드 실패\n"
            return (nil, log)
        }
        log += "✅ 이미지 다운로드 성공\n"
        return (image, log)
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

        nsLog("getSignedFileUrls 요청: source=\(source), blockId=\(blockId)")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            nsLog("getSignedFileUrls: 네트워크 오류")
            return nil
        }
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respBody = String(data: data, encoding: .utf8) ?? ""
        nsLog("getSignedFileUrls: HTTP \(httpCode) — \(respBody.prefix(300))")

        guard httpCode == 200,
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

    // MARK: - API-based image replacement (캡션 보존)

    struct CaptureContext {
        let blockId: String
        let spaceId: String
        let tokenV2: String
        let fileToken: String
    }

    static func buildCaptureContext(clipboardHTML: String?, clipboardText: String?) -> CaptureContext? {
        guard let attachment = parseAttachmentSource(html: clipboardHTML, text: clipboardText),
              let block = findBlock(fileId: attachment.fileId, fallbackSource: attachment.source),
              let cookies = decryptCookies() else { return nil }
        return CaptureContext(blockId: block.blockId, spaceId: block.spaceId,
                             tokenV2: cookies.tokenV2, fileToken: cookies.fileToken)
    }

    /// 새 이미지를 S3에 업로드하고 블록 소스만 교체 (캡션 등 다른 속성 유지)
    static func replaceBlockImage(context: CaptureContext, pngData: Data) async -> Bool {
        nsLog("Step 1: getUploadFileUrl 요청 중...")
        guard let upload = await requestUploadURL(context: context) else {
            nsLog("Step 1 실패: getUploadFileUrl")
            return false
        }
        nsLog("Step 1 성공: fileId=\(upload.fileId)")

        nsLog("Step 2: S3 업로드 중... \(pngData.count) bytes")
        guard await putToS3(url: upload.putURL, data: pngData) else {
            nsLog("Step 2 실패: S3 PUT")
            return false
        }
        nsLog("Step 2 성공: S3 업로드 완료")

        nsLog("Step 3: submitTransaction 요청 중...")
        let result = await submitSourceUpdate(context: context, newSource: upload.sourceURL, newFileId: upload.fileId)
        nsLog("Step 3 \(result ? "성공" : "실패")")
        return result
    }

    private static func requestUploadURL(context: CaptureContext) async -> (putURL: URL, sourceURL: String, fileId: String)? {
        guard let endpoint = URL(string: "https://www.notion.so/api/v3/getUploadFileUrl") else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(context), forHTTPHeaderField: "Cookie")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "bucket": "secure", "name": "edited.png", "contentType": "image/png",
            "record": ["table": "block", "id": context.blockId, "spaceId": context.spaceId]
        ] as [String: Any])

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            nsLog("getUploadFileUrl: 네트워크 오류")
            return nil
        }
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            nsLog("getUploadFileUrl: HTTP \(statusCode) — \(body)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let putStr = json["signedPutUrl"] as? String, let putURL = URL(string: putStr),
              let sourceURL = json["url"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? ""
            nsLog("getUploadFileUrl: JSON 파싱 실패 — \(body)")
            return nil
        }

        let comps = URL(string: sourceURL)?.pathComponents ?? []
        let fileId = comps.count >= 3 ? comps[comps.count - 2] : UUID().uuidString
        return (putURL, sourceURL, fileId)
    }

    private static func putToS3(url: URL, data: Data) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    private static func submitSourceUpdate(context: CaptureContext, newSource: String, newFileId: String) async -> Bool {
        guard let endpoint = URL(string: "https://www.notion.so/api/v3/submitTransaction") else { return false }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(context), forHTTPHeaderField: "Cookie")

        let pointer: [String: String] = ["table": "block", "id": context.blockId, "spaceId": context.spaceId]
        let body: [String: Any] = [
            "requestId": UUID().uuidString,
            "transactions": [[
                "id": UUID().uuidString,
                "spaceId": context.spaceId,
                "operations": [
                    ["pointer": pointer, "path": ["properties", "source"], "command": "set", "args": [[newSource]]] as [String: Any]
                ]
            ] as [String: Any]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            nsLog("submitTransaction: 네트워크 오류")
            return false
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            nsLog("submitTransaction: HTTP \(code) — \(body)")
            return false
        }
        return true
    }

    private static func cookieHeader(_ ctx: CaptureContext) -> String {
        "token_v2=\(ctx.tokenV2); file_token=\(ctx.fileToken)"
    }
}
