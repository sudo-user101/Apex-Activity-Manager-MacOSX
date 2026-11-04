import Foundation
import Network
import Security

/// One HTTPS request to Apex Server Edition over the Network framework, with
/// the server's own certificate checked by its pin (the certificate's
/// SHA-256, or its key's, which stays the same through renewals).
/// URLSession can't be used for this: App Transport Security refuses a
/// server's own certificate on public and cloud addresses even when the
/// app checks it itself. Here the pin is the whole check, as it should be.
enum PinnedHTTP {
    struct Response: Sendable { let status: Int; let body: Data; let fingerprint: String; let key: String? }

    enum Failure: Error, Equatable {
        case wrongCertificate, refused, unreachable, hostUnknown, badAnswer, other(String)
    }

    /// Blocking. `expected` nil: any certificate (pairing), noted in the response.
    static func send(host: String, port: Int, method: String = "GET", path: String, headers: [String: String] = [:],
                     body: Data? = nil, expected: String?, expectedKey: String? = nil, timeout: TimeInterval = 30) -> Result<Response, Failure> {
        let box = Box()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first else { done(false); return }
            let fp = ServerEdition.fingerprint(SecCertificateCopyData(leaf) as Data)
            let key = ServerEdition.keyFingerprint(leaf)
            box.set(fp: fp, key: key)
            done(expected == nil || expected == fp || (expectedKey != nil && expectedKey == key))
        }, .global(qos: .userInitiated))
        let params = NWParameters(tls: tls)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .any
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !h.isEmpty else { return .failure(.other("That address doesn’t look right.")) }
        let conn = NWConnection(host: NWEndpoint.Host(h), port: p, using: params)
        let done = DispatchSemaphore(value: 0)
        var received = Data()
        var failure: Failure?

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, complete, e in
                if let d { received.append(d) }
                if received.count > 64 << 20 { failure = .badAnswer; conn.cancel(); return }
                if complete || e != nil { conn.cancel() } else { receive() }
            }
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                conn.send(content: request(host: h, port: port, method: method, path: path, headers: headers, body: body), completion: .contentProcessed { e in
                    if let e { failure = failure ?? map(e, box: box, expected: expected); conn.cancel() }
                })
                receive()
            case .waiting(let e), .failed(let e):
                failure = failure ?? map(e, box: box, expected: expected)
                conn.cancel()
            case .cancelled:
                done.signal()
            default: break
            }
        }
        let q = DispatchQueue(label: "apex.pinned-http")
        conn.start(queue: q)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            conn.cancel()
            _ = done.wait(timeout: .now() + 2)
            return .failure(failure ?? .unreachable)
        }
        if let failure, received.isEmpty { return .failure(failure) }
        guard let r = parse(received), let fp = box.fp else { return .failure(failure ?? .badAnswer) }
        return .success(Response(status: r.status, body: r.body, fingerprint: fp, key: box.key))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var fp: String?
        private(set) var key: String?
        func set(fp: String, key: String?) { lock.lock(); self.fp = fp; self.key = key; lock.unlock() }
    }

    private static func map(_ e: NWError, box: Box, expected: String?) -> Failure {
        switch e {
        case .tls:
            return box.fp != nil && expected != nil ? .wrongCertificate : .other("The secure connection to the server failed (\(e.localizedDescription)).")
        case .posix(let c) where c == .ECONNREFUSED: return .refused
        case .posix(let c) where [.ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN].contains(c): return .unreachable
        case .dns: return .hostUnknown
        default: return .other(e.localizedDescription)
        }
    }

    /// The request's bytes. Pure: tested.
    static func request(host: String, port: Int, method: String, path: String, headers: [String: String], body: Data?) -> Data {
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(hostHeader)", "Connection: close", "Accept: application/json", "User-Agent: Apex"]
        // A line break in a header would start another one ("\r\n" is one Character, so look at the scalars).
        let breaks = { (t: String) in t.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) where !breaks(k) && !breaks(v) { lines.append("\(k): \(v)") }
        if let body { lines.append("Content-Length: \(body.count)") }
        var d = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { d.append(body) }
        return d
    }

    /// Status and body of an HTTP/1.1 answer (plain or chunked). Pure: tested.
    static func parse(_ d: Data) -> (status: Int, body: Data)? {
        guard let split = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = head.first, first.hasPrefix("HTTP/"), let status = Int(first.split(separator: " ").dropFirst().first ?? "") else { return nil }
        var body = Data(d[split.upperBound...])
        let chunked = head.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked {
            var out = Data(), i = body.startIndex
            while let lineEnd = body[i...].range(of: Data("\r\n".utf8)) {
                let sizeText = String(decoding: body[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let n = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), n >= 0 else { return nil }
                if n == 0 { break }
                let start = lineEnd.upperBound
                guard body.distance(from: start, to: body.endIndex) >= n else { return nil }
                let end = body.index(start, offsetBy: n)
                out.append(body[start..<end])
                i = body.index(end, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
            }
            body = out
        } else if let len = head.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }),
                  len >= 0, body.count > len {
            body = body.prefix(len)
        }
        return (status, body)
    }
}
