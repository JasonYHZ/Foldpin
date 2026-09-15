import Foundation
import Darwin

nonisolated struct MCPHTTPResponse: Sendable {
    var status: Int
    var headers: [String:String] = [:]
    var body = Data()
    func encoded() -> Data {
        let labels=[200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",406:"Not Acceptable",413:"Payload Too Large",415:"Unsupported Media Type",429:"Too Many Requests",500:"Internal Server Error",503:"Service Unavailable"]
        var text="HTTP/1.1 \(status) \(labels[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (key,value) in headers { text += "\(key): \(value)\r\n" }
        text += "\r\n";var data=Data(text.utf8);data.append(body);return data
    }
}
nonisolated struct MCPHTTPRequest: Sendable {
    let method:String, headers:[String:String], body:Data
    static func parse(_ data:Data,port:Int) throws -> MCPHTTPRequest? {
        let delimiter=Data("\r\n\r\n".utf8)
        guard let split=data.range(of:delimiter) else { if data.count>16384{throw HTTPError(status:413)};return nil }
        guard split.lowerBound<=16384,let text=String(data:data[..<split.lowerBound],encoding:.utf8) else{throw HTTPError(status:400)}
        let lines=text.components(separatedBy:"\r\n"), start=lines[0].split(separator:" ")
        guard start.count==3,start[1]=="/mcp",start[2]=="HTTP/1.1" else{throw HTTPError(status:404)}
        var headers:[String:String]=[:]
        for line in lines.dropFirst(){
            guard let colon=line.firstIndex(of:":"),line.first != " ",line.first != "\t" else{throw HTTPError(status:400)}
            let key=String(line[..<colon]).lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !key.isEmpty,headers[key]==nil,!value.contains("\0") else{throw HTTPError(status:400)};headers[key]=value
        }
        let hosts=["127.0.0.1:\(port)","[::1]:\(port)","localhost:\(port)"]
        guard let host=headers["host"],hosts.contains(host) else{throw HTTPError(status:403)}
        if let origin=headers["origin"] { guard hosts.map({"http://"+$0}).contains(origin) else{throw HTTPError(status:403)} }
        guard headers["transfer-encoding"]==nil else{throw HTTPError(status:400)}
        let length:Int
        if let s=headers["content-length"] {guard !s.isEmpty,s.allSatisfy(\.isNumber),let n=Int(s),n>=0 else{throw HTTPError(status:400)};length=n}
        else {guard start[0] != "POST" else{throw HTTPError(status:400)};length=0}
        guard length<=2_097_152 else{throw HTTPError(status:413)}
        let received=data.count-split.upperBound
        guard received>=length else{return nil}
        guard received==length else{throw HTTPError(status:400)}
        return MCPHTTPRequest(method:String(start[0]),headers:headers,body:Data(data[split.upperBound...]))
    }
    struct HTTPError:Error{let status:Int}
}
@MainActor
final class MCPHTTPServer {
    var handle: (@MainActor (MCPHTTPRequest) async -> MCPHTTPResponse)?
    var failed: ((String) -> Void)?
    private struct Listener { let fd: Int32; let source: DispatchSourceRead }
    private final class Connection {
        let fd: Int32
        let reader: DispatchSourceRead
        var writer: DispatchSourceWrite?
        var incoming = Data()
        var outgoing = Data()
        var sent = 0
        var handling = false
        init(fd: Int32, reader: DispatchSourceRead) { self.fd = fd; self.reader = reader }
    }
    private var listeners: [Listener] = []
    private var connections: [UUID: Connection] = [:]
    private var port = 0
    func start(port: Int) throws {
        stop(); self.port = port
        guard (1024...65535).contains(port) else { throw MCPFailure("invalid_port") }
        do {
            for family in [AF_INET, AF_INET6] {
                let fd = Darwin.socket(family, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                var keep = false
                defer { if !keep { Darwin.close(fd) } }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
                var yes: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                let bound: Int32
                if family == AF_INET {
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = UInt16(port).bigEndian
                    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                    bound = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                } else {
                    guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EIO) }
                    var address = sockaddr_in6()
                    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    address.sin6_family = sa_family_t(AF_INET6)
                    address.sin6_port = UInt16(port).bigEndian
                    address.sin6_addr = in6addr_loopback
                    bound = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                    }
                }
                guard bound == 0, Darwin.listen(fd, 16) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
                source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept(fd) } }
                listeners.append(Listener(fd: fd, source: source)); keep = true; source.resume()
            }
        } catch { stop(); throw error }
    }
    func stop() {
        for listener in listeners { listener.source.setEventHandler {}; listener.source.cancel(); Darwin.close(listener.fd) }
        listeners = []
        for id in Array(connections.keys) { close(id) }
    }
    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard connections.count < 16 else { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var yes: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let id = UUID(), source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            connections[id] = Connection(fd: fd, reader: source)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.receive(id) } }; source.resume()
            Task { [weak self] in try? await Task.sleep(for: .seconds(15)); self?.close(id) }
        }
    }
    private func receive(_ id: UUID) {
        guard let c = connections[id], !c.handling else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.recv(c.fd, &buffer, buffer.count, 0)
            if count == 0 { close(id); return }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close(id) }; return }
            c.incoming.append(contentsOf: buffer.prefix(count))
            do {
                if let request = try MCPHTTPRequest.parse(c.incoming, port: port) {
                    c.handling = true; c.reader.setEventHandler {}; c.reader.cancel()
                    Task { [weak self] in
                        guard let self else { return }
                        let response = await self.handle?(request) ?? MCPHTTPResponse(status: 503)
                        self.send(response, id)
                    }
                    return
                }
            } catch { c.handling = true; send(MCPHTTPResponse(status: (error as? MCPHTTPRequest.HTTPError)?.status ?? 400), id); return }
        }
    }
    private func send(_ response: MCPHTTPResponse, _ id: UUID) {
        guard let c = connections[id] else { return }
        c.outgoing = response.encoded()
        let source = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: .main)
        c.writer = source
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.write(id) } }; source.resume()
    }
    private func write(_ id: UUID) {
        guard let c = connections[id] else { return }
        while c.sent < c.outgoing.count {
            let count = c.outgoing.withUnsafeBytes { bytes in Darwin.send(c.fd, bytes.baseAddress!.advanced(by: c.sent), bytes.count - c.sent, 0) }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close(id) }; return }
            if count == 0 { close(id); return }
            c.sent += count
        }
        close(id)
    }
    private func close(_ id: UUID) {
        guard let c = connections.removeValue(forKey: id) else { return }
        c.reader.setEventHandler {}; c.reader.cancel(); c.writer?.setEventHandler {}; c.writer?.cancel(); Darwin.close(c.fd)
    }
}
