import AppKit
import Darwin

// An isolated app that implements one navigation reply, then exits.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Bundle.main.object(forInfoDictionaryKey: "FixtureSocket") as! String
        alarm(20)
        DispatchQueue.global().async {
            defer { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
            Thread.sleep(forTimeInterval: 0.3)
            let server = socket(AF_UNIX, SOCK_STREAM, 0)
            guard server >= 0 else { return }
            defer { Darwin.close(server); unlink(path) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                path.withCString { source in
                    _ = strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, path.utf8.count + 1)
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(server, 1) == 0 else { return }
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var bytes = Data()
            var byte: UInt8 = 0
            while bytes.count < 65_536, Darwin.read(client, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
            guard let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let requestID = request["requestId"] as? String,
                  let environment = request["environmentId"] as? String,
                  let thread = request["threadId"] as? String,
                  let response = try? JSONSerialization.data(withJSONObject: [
                    "version": 1, "requestId": requestID, "ok": true,
                    "environmentId": environment, "threadId": thread
                  ]) + Data([10]) else { return }
            response.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(client, raw.baseAddress! + sent, raw.count - sent)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
