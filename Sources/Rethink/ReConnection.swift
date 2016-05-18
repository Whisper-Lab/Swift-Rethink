import Foundation
import Socket
import SCRAM

private typealias ReQueryToken = UInt64

private struct ReTokenCounter {
    private var nextQueryToken: UInt64 = 0x5ADFACE
    private var queue = Queue(type: .SERIAL, label: "com.whisperlab.Rethink.ReTokenCounter")

    mutating func next() -> ReQueryToken {
        var nt: UInt64 = 0
        self.queue.queueSync() {
            nt = self.nextQueryToken
            self.nextQueryToken += 1
        }
        return nt
    }
}

private enum ReSocketState {
    case Unconnected
    case Connecting
    case Connected
}

private class ReSocket {
    typealias WriteCallback = (String?) -> ()
    typealias ReadCallback = (NSData?) -> ()

    private static let BUFFER_SIZE = 2000

    let socket: Socket?
    private var queue: Queue
    private var state: ReSocketState = .Unconnected
    private var ioBuffer = NSMutableData(capacity: BUFFER_SIZE)
    private var unreadCount = 0

    private var onConnect: ((String?) -> ())?
    private var writeCallbacks: [Int: WriteCallback] = [:]
    private var readCallbacks: [Int: ReadCallback] = [:]

    init(queue: Queue) {
        do {
            self.socket = try Socket.create()
        }
        catch {
            self.socket = nil
        }
        self.queue = queue
    }

    func connect(url: NSURL, callback: (String?) -> ()) {
        assert(self.state == .Unconnected, "Already connected or connecting")
        self.onConnect = callback
        self.state = .Connecting

        guard let host = url.host else { return callback("Invalid URL") }
        let port = url.port ?? 28015

        do {
            try socket!.connect(to: host, port: port.int32Value)
            if socket!.isConnected {
              queue.queueAsync() {
                self.socketDidConnect(sock: self.socket, toHost: self.socket!.signature!.hostname, port: self.socket!.signature!.port)
              }
            }
            else {
              return callback("not_connected")
            }
        }
        catch let e as NSError {
            return callback(e.localizedDescription)
        }
    }

    private func socketDidConnect(sock: Socket!, toHost host: String!, port: Int32) {
        self.state = .Connected
        self.onConnect?(nil)
    }

    private func socketDidDisconnect(sock: Socket!, withError err: NSError!) {
        self.state = .Unconnected
    }

    func read(length: Int, callback: ReadCallback)  {
        assert(length > 0, "Length cannot be zero or less")

        if self.state != .Connected {
            return callback(nil)
        }

        queue.queueAsync() {
            let tag = (self.readCallbacks.count + 1)
            self.readCallbacks[tag] = callback
            let outData = NSMutableData(capacity: length)!
            var total = self.unreadCount;
            var count = -1
            do {
                while count != 0 && total < length {
                    count = try self.socket!.read(into: self.ioBuffer!)
                    total += count
                }
            }
            catch {
                return callback(nil)
            }
            self.unreadCount = total - length
            memcpy(outData.mutableBytes, self.ioBuffer!.bytes + (self.ioBuffer!.length - length), length)
            memcpy(self.ioBuffer!.mutableBytes, self.ioBuffer!.bytes + (self.ioBuffer!.length - self.unreadCount), self.unreadCount)
            self.ioBuffer!.length = self.unreadCount
            self.socket(sock:self.socket, didReadData: outData, withTag: tag)
        }
    }

    func readZeroTerminatedASCII(callback: (String?) -> ()) {
        if self.state != .Connected {
            return callback(nil)
        }

        queue.queueAsync() {
            let tag = (self.readCallbacks.count + 1)
            self.readCallbacks[tag] = { data in
                if let d = data {
                    let s = NSString(data: d.subdata(with: NSRange(location: 0, length: d.length - 1)), encoding: NSASCIIStringEncoding)!
                    callback(String(s))
                }
                else {
                    callback(nil)
                }
            }
            let outData = NSMutableData()
            do {
                try self.socket!.read(into: self.ioBuffer!)
            }
            catch{
                return callback(nil)
            }
            memcpy(outData.mutableBytes, self.ioBuffer!.bytes, self.ioBuffer!.length)
            self.ioBuffer!.length = 0
            self.socket(sock: self.socket, didReadData: outData, withTag: tag)
        }
    }

    func write(data: NSData, callback: WriteCallback) {
        if self.state != .Connected {
            return callback("socket is not connected!")
        }

        queue.queueAsync() {
            let tag = (self.writeCallbacks.count + 1)
            self.writeCallbacks[tag] = callback
            //self.socket.writeData(data, withTimeout: -1.0, tag: tag)
            do {
                try self.socket!.write(from: data)
                self.socket(sock: self.socket, didWriteDataWithTag: tag)
            }
            catch let error as Socket.Error {
                callback("Error sending command to Redis server. Error=\(error.description)")
            }
            catch {
                callback("Error sending command to Redis server. Unknown error.")
            }
        }
    }

    private func socket(sock: Socket!, didWriteDataWithTag tag: Int) {
        queue.queueAsync() {
            if let cb = self.writeCallbacks[tag] {
                cb(nil)
                self.writeCallbacks.removeValue(forKey: tag)
            }
        }
    }

    private func socket(sock: Socket!, didReadData data: NSData!, withTag tag: Int) {
        queue.queueAsync() {
            if let cb = self.readCallbacks[tag] {
                cb(data)
                self.readCallbacks.removeValue(forKey: tag)
            }
        }
    }

    func disconnect() {
        self.socket!.close()
        self.state = .Unconnected
        queue.queueAsync() {
            self.socketDidDisconnect(sock: self.socket, withError: nil)
        }
    }

    deinit {
        self.socket!.close()
        queue.queueAsync() {
            self.socketDidDisconnect(sock: self.socket, withError: nil)
        }
    }
}

public enum ReProtocolVersion {
    case V0_4
    case V1_0

    var protocolVersionCode: UInt32 {
        switch self {
        case .V0_4: return 0x400c2d20
        case .V1_0: return 0x34c2bdc3
        }
    }
}

public class ReConnection: NSObject {
    public let url: NSURL
    public let protocolVersion: ReProtocolVersion
    public var authenticationKey: String? { get { return self.url.user } }

    private var state = ReConnectionState.Unconnected
    private let socket: ReSocket
    private var outstandingQueries: [ReQueryToken: ReResponse.Callback] = [:]
    private var onConnectCallback: ((String?) -> ())? = nil

    private static var tokenCounter = ReTokenCounter()
    private let queue = Queue(type: .SERIAL, label: "com.whisperlab.Rethink.ReConnectionQueue")

    // Create a connection to a RethinkDB instance. The URL should be of the form 'rethinkdb://host:port'. If
    // no port is given, the default port is used. If the server requires the use of an authentication key, put it
    // in the 'user' part of the URL, e.g. "rethinkdb://key@server:port".
    internal init(url: NSURL, protocolVersion: ReProtocolVersion = .V1_0) {
        self.url = url
        self.protocolVersion = protocolVersion
        self.socket = ReSocket(queue: self.queue)
    }

    internal func connect(username: String = ReProtocol.defaultUser, password: String = ReProtocol.defaultPassword, callback: (ReError?) -> ()) {
        self.socket.connect(url: self.url) { err in
            if let e = err {
                return callback(ReError.Fatal(e))
            }

            // Start authentication
            guard let data = NSMutableData(capacity: 128) else {
                let e = ReError.Fatal("Could not create data object")
                self.state = .Error(e)
                return callback(e)
            }

            switch self.protocolVersion {
            case .V0_4:
                // Append protocol version
                data.append(NSData.dataWithLittleEndianOf(nr: UInt32(self.protocolVersion.protocolVersionCode)))

                // Append authentication key length and the key itself (as ASCII)
                if let authKey = self.authenticationKey?.data(using: NSASCIIStringEncoding) {
                    data.append(NSData.dataWithLittleEndianOf(nr: UInt32(authKey.length)))
                    data.append(authKey)
                }
                else {
                    data.append(NSData.dataWithLittleEndianOf(nr: UInt32(0)))
                }

                // Append protocol type (JSON)
                data.append(NSData.dataWithLittleEndianOf(nr: UInt32(ReProtocol.protocolType)))

            case .V1_0:
                data.append(NSData.dataWithLittleEndianOf(nr: UInt32(self.protocolVersion.protocolVersionCode)))
            }

            self.socket.write(data: data) { err in
                if let e = err {
                    self.state = .Error(ReError.Fatal(e))
                    return callback(ReError.Fatal(e))
                }

                self.state = .HandshakeSent

                // Let's see if we get a reply
                if self.socket.state == .Connected {
                    self.socket.readZeroTerminatedASCII() { s in
                        switch self.protocolVersion {
                        case .V0_4:
                            if s == ReProtocol.handshakeSuccessResponse {
                                // Start read loop
                                self.state = .Connected
                                self.startReading()
                                return callback(nil)
                            }
                            else {
                                let e = ReError.Fatal("Handshake failed, server returned: \(s)")
                                self.state = .Error(e)
                                return callback(e)
                            }

                        case .V1_0:
                            do {
                                if let replyString = s {
                                    /* The reply is a JSON object containing the keys 'success' (should be true), 'min_protocol_version',
                                    'max_protocol_version' and 'server_version'. */
                                    let reply = try NSJSONSerialization.jsonObject(with: replyString.data(using: NSASCIIStringEncoding)!, options: [])

                                    if let replyDictionary = reply as? [String: AnyObject], let success = replyDictionary["success"] as? NSNumber where success.boolValue {
                                        self.performSCRAMAuthentication(username: username, password: password) { err in
                                            if err == nil {
                                                // Start read loop
                                                self.state = .Connected
                                                self.startReading()
                                                return callback(nil)
                                            }
                                            else {
                                                self.state = .Error(err!)
                                                return callback(err)
                                            }
                                        }
                                    }
                                    else {
                                        /* On error, the server will return a null-terminated error string (non JSON), 
                                        or a JSON object with 'success' set to false. */
                                        let e = ReError.Fatal("Server returned \(replyString)")
                                        self.state = .Error(e)
                                        return callback(e)
                                    }
                                }
                                else {
                                    let e = ReError.Fatal("Handshake failed, server returned: \(s)")
                                    self.state = .Error(e)
                                    return callback(e)
                                }
                            }
                            catch let error as NSError {
                                return callback(ReError.Fatal(error.localizedDescription))
                            }
                        }
                    }
                }
            }
        }
    }

    private func performSCRAMAuthentication(username: String, password: String, callback: (ReError?) -> ()) {
        assert(self.protocolVersion == .V1_0, "SCRAM authentication not supported with protocol version \(self.protocolVersion)")
        let scram = SCRAM(username: username, password: password)
        var zeroByte: UInt8 = 0x00

        // Send authentication first message
        do {
            let firstMessage = ["protocol_version": 0, "authentication_method": "SCRAM-SHA-256", "authentication": scram.clientFirstMessage]
            let data = try NSJSONSerialization.data(withJSONObject: firstMessage, options: [])
            let zeroTerminatedData = NSMutableData(data: data)
            zeroTerminatedData.append(&zeroByte, length: 1)

            self.socket.write(data: zeroTerminatedData) { err in
                if let e = err {
                    return callback(ReError.Fatal(e))
                }

                // Server should send us some JSON back
                self.socket.readZeroTerminatedASCII() { replyString in
                    do {
                        if let s = replyString {
                            if let reply = try NSJSONSerialization.jsonObject(with: s.data(using: NSASCIIStringEncoding)!, options: []) as? [String: AnyObject] {
                                if let success = reply["success"] as? NSNumber where success.boolValue {
                                    let authData = reply["authentication"] as! String
                                    if let shouldSend = scram.receive(authData) {
                                        // Send the generated reply back
                                        let secondMessage = [
                                            "authentication": shouldSend
                                        ]
                                        let secondReply = try NSJSONSerialization.data(withJSONObject: secondMessage, options: [])
                                        let zeroSecondReply = NSMutableData(data: secondReply)
                                        zeroSecondReply.append(&zeroByte, length: 1)

                                        self.socket.write(data: zeroSecondReply) { err in
                                            if let e = err {
                                                return callback(ReError.Fatal(e))
                                            }

                                            // Verify server signature
                                            self.socket.readZeroTerminatedASCII() { replyString in
                                                do {
                                                    if let s = replyString {
                                                        if let reply = try NSJSONSerialization.jsonObject(with: s.data(using: NSASCIIStringEncoding)!, options: []) as? [String: AnyObject] {
                                                            if let success = reply["success"] as? NSNumber where success.boolValue {
                                                                let authData = reply["authentication"] as! String
                                                                scram.receive(authData)
                                                                if scram.authenticated {
                                                                    return callback(nil)
                                                                }
                                                                else {
                                                                    return callback(ReError.Fatal("SCRAM authentication invalid!"))
                                                                }
                                                            }
                                                            else {
                                                                if let errorString = reply["error"] as? String {
                                                                    return callback(ReError.Fatal(errorString))
                                                                }
                                                                else {
                                                                    return callback(ReError.Fatal("Server returned \(s)"))
                                                                }
                                                            }
                                                        }
                                                        else {
                                                            return callback(ReError.Fatal("Server returned \(s)"))
                                                        }
                                                    }
                                                    else {
                                                        return callback(ReError.Fatal("Server did not return a server final message in SCRAM exchange"))
                                                    }
                                                }
                                                catch let error as NSError {
                                                    return callback(ReError.Fatal(error.localizedDescription))
                                                }
                                            }
                                        }
                                    }
                                    else {
                                        return callback(ReError.Fatal("SCRAM authentication failed"))
                                    }
                                }
                                else {
                                    if let errorString = reply["error"] as? String {
                                        return callback(ReError.Fatal(errorString))
                                    }
                                    else {
                                        return callback(ReError.Fatal("Server returned \(s)"))
                                    }
                                }
                            }
                            else {
                                return callback(ReError.Fatal("Server returned \(s)"))
                            }
                        }
                        else {
                            return callback(ReError.Fatal("Server did not return a reply to our first authentication message"))
                        }
                    }
                    catch let error as NSError {
                        return callback(ReError.Fatal(error.localizedDescription))
                    }
                }
            }
        }
        catch let error as NSError {
            return callback(ReError.Fatal(error.localizedDescription))
        }
    }

    public func close() {
        self.queue.queueAsync() {
            self.socket.disconnect()
            self.state = .Unconnected
            self.outstandingQueries.removeAll()
        }
    }

    public var connected: Bool {
        if case ReConnectionState.Connected = state {
            return true
        }
        return false
    }

    public var error: ReError? {
        return self.state.error
    }

    private func startReading() {
        self.socket.read(length: 8 + 4) { data in
            if let d = data {
                let queryToken = d.readLittleEndianUInt64(atIndex: 0)
                let responseSize = d.readLittleEndianUInt32(atIndex: 8)

                self.socket.read(length: Int(responseSize), callback: { data in
                    if let d = data {
                        assert(d.length == Int(responseSize))

                        var called = false
                        let continuation: ReResponse.ContinuationCallback = { [weak self] (cb: ReResponse.Callback) -> () in
                            assert(!called, "continuation callback for query token \(queryToken) must never be called more than once")
                            called = true
                            self?.sendContinuation(token: queryToken, callback: cb)
                        }

                        self.queue.queueAsync() {
                            if let handler = self.outstandingQueries[queryToken] {
                                if let response = ReResponse(json: d, continuation: continuation) {
                                    self.outstandingQueries.removeValue(forKey: queryToken)
                                    handler(response)
                                    self.startReading()
                                }
                                else {
                                    self.state = .Error(ReError.Fatal("Invalid response object from server"))
                                }
                            }
                        }
                    }
                    else {
                        self.state = .Error(ReError.Fatal("Disconnected"))
                    }
                })
            }
            else {
                self.state = .Error(ReError.Fatal("Disconnected"))
            }
        }
    }

    private func sendContinuation(token: ReQueryToken, callback: ReResponse.Callback) {
        let json = [ReProtocol.ReQueryType.CONTINUE.rawValue];
        let query = try! NSJSONSerialization.data(withJSONObject: json, options: [])
        self.sendQuery(query: query, token: token, callback: callback)
    }

    private func dummy() {
    }

    private func sendQuery(query: NSData, token: ReQueryToken, callback: ReResponse.Callback) {
        queue.queueAsync() {
            assert(self.outstandingQueries[token] == nil, "A query with token \(token) is already outstanding")
            assert(self.connected, "Cannot send a query when the connection is not open")
            let data = NSMutableData(capacity: query.length + 8 + 4)!

            let reffingCallback: ReResponse.Callback = { (res) -> () in
                // This is used to create a reference to ReConnection, and keeps it alive at least until the query has finished.
                self.dummy()
                callback(res)
            }


            data.append(NSData.dataWithLittleEndianOf(nr: token))
            data.append(NSData.dataWithLittleEndianOf(nr: UInt32(query.length)))
            data.append(query)
            self.socket.write(data: data) { err in
                if let e = err {
                    self.state = .Error(ReError.Fatal(e))
                    callback(ReResponse.Error(e))
                }
                else {
                    self.outstandingQueries[token] = reffingCallback
                }
            }
        }
    }

    internal func startQuery(query: NSData, callback: ReResponse.Callback) throws {
        queue.queueAsync() {
            let token = ReConnection.tokenCounter.next()
            self.sendQuery(query: query, token: token, callback: callback)
        }
    }
}

private enum ReConnectionState {
    case Unconnected // Nothing has been done yet
    case HandshakeSent // Our handshake has been sent, we are waiting for confirmation of success
    case Connected // Handshake has been completed, and we are awaiting respones from the server
    case Error(ReError) // A protocol error has occurred
    case Terminated // The connection has been terminated

    var error: ReError? {
        switch self {
        case .Error(let e):
            return e

        default:
            return nil
        }
    }
}

public enum ReError: ErrorProtocol {
    case Fatal(String)
    case Other(ErrorProtocol)

    public var description: String {
        switch self {
        case .Fatal(let s): return s
        case .Other(let e): return "\(e)"
        }
    }
}

public enum ReResponse {
    public typealias Callback = (ReResponse) -> ()
    public typealias ContinuationCallback = (Callback) -> ()

    case Error(String)
    case Value(AnyObject)
    case Rows([ReDocument], ContinuationCallback?)
    case Unknown

    init?(json: NSData, continuation: ContinuationCallback) {
        do {
            if let d = try NSJSONSerialization.jsonObject(with: json, options: []) as? NSDictionary {
                if let type = d.value(forKey: "t") as? NSNumber {
                    switch type.intValue {
                    case ReProtocol.responseTypeSuccessAtom:
                        guard let r = d.value(forKey: "r") as? [AnyObject] else { return nil }
                        if r.count != 1 { return nil }
                        self = .Value(ReDatum(jsonSerialization: r.first!).value)

                    case ReProtocol.responseTypeSuccessPartial, ReProtocol.responseTypeSuccessSequence:
                        if let r = d.value(forKey: "r") as? [[String: AnyObject]] {
                            let deserialized = r.map { (document) -> ReDocument in
                                var dedoc: ReDocument = [:]
                                for (k, v) in document {
                                    dedoc[k] = ReDatum(jsonSerialization: v).value
                                }
                                return dedoc
                            }

                            self = .Rows(deserialized, type.intValue == ReProtocol.responseTypeSuccessPartial ? continuation : nil)
                        }
                        else if let r = d.value(forKey: "r") as? [AnyObject] {
                            let deserialized = r.map { (value) -> AnyObject in
                                return ReDatum(jsonSerialization: value).value
                            }

                            self = .Value(deserialized)
                        }
                        else {
                            return nil
                        }

                    case ReProtocol.responseTypeClientError:
                        guard let r = d.value(forKey: "r") as? [AnyObject] else { return nil }
                        if r.count != 1 { return nil }
                        self = .Error("Client error: \(r.first!)")

                    case ReProtocol.responseTypeCompileError:
                        guard let r = d.value(forKey: "r") as? [AnyObject] else { return nil }
                        if r.count != 1 { return nil }
                        self = .Error("Compile error: \(r.first!)")

                    case ReProtocol.responseTypeRuntimeError:
                        guard let r = d.value(forKey: "r") as? [AnyObject] else { return nil }
                        if r.count != 1 { return nil }
                        self = .Error("Run-time error: \(r.first!)")

                    default:
                        self = .Unknown
                    }
                }
                else {
                    return nil
                }
            }
            else {
                return nil
            }
        }
        catch {
            return nil
        }
    }

    public var isError: Bool {
        switch self {
        case .Error(_): return true
        default: return false
        }
    }

    public var value: AnyObject? {
        switch self {
        case .Value(let v):
            return v

        default:
            return nil
        }
    }
}

private extension NSData {
    static func dataWithLittleEndianOf(nr: UInt64) -> NSData {
        var swapped = CFSwapInt64HostToLittle(nr)

        var bytes: [UInt8] = [0,0,0,0,0,0,0,0]
        for i in 0...7 {
            bytes[i] = UInt8(swapped & 0xFF)
            swapped = swapped >> 8
        }

        return NSData(bytes: bytes, length: 8)
    }

    static func dataWithLittleEndianOf(nr: UInt32) -> NSData {
        var swapped = CFSwapInt32HostToLittle(nr) // No-op on little endian archs

        var bytes: [UInt8] = [0,0,0,0]
        for i in 0...3 {
            bytes[i] = UInt8(swapped & 0xFF)
            swapped = swapped >> 8
        }

        return NSData(bytes: bytes, length: 4)
    }

    func readLittleEndianUInt64(atIndex: Int = 0) -> UInt64 {
        assert(self.length >= atIndex + 8)
        let buffer = UnsafeMutablePointer<UInt8>(self.bytes)
        var read: UInt64 = 0
        for i in (0...7).reversed() {
            read = (read << 8) + UInt64(buffer[atIndex + i])
        }
        return CFSwapInt64LittleToHost(read)
    }

    func readLittleEndianUInt32(atIndex: Int = 0) -> UInt32 {
        assert(self.length >= (atIndex + 4))
        let buffer = UnsafeMutablePointer<UInt8>(self.bytes)
        var read: UInt32 = 0
        for i in (0...3).reversed() {
            read = (read << 8) + UInt32(buffer[atIndex + i])
        }
        return CFSwapInt32LittleToHost(read)
    }
}
