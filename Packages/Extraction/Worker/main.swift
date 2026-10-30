// xs-extract: the extraction worker process. Reads framed requests on stdin, extracts one file
// at a time, writes framed responses on stdout. Holds no state between requests, so the
// supervisor can SIGKILL and restart it at any moment.
import Extraction
import Foundation

// Dev: `xs-extract --probe FILE…` prints statistics only (never names or text).
if CommandLine.arguments.dropFirst().first == "--probe" {
    for path in CommandLine.arguments.dropFirst(2) {
        let start = Date()
        let ext = (path as NSString).pathExtension.lowercased()
        do {
            let r = try autoreleasepool { try Extractor.extract(path: path, limits: ExtractionLimits()) }
            let anchors = (try? JSONSerialization.jsonObject(with: Data(r.anchorsJSON.utf8)) as? [Any])?.count ?? 0
            print("\(ext)\tok\tchars=\(r.text.unicodeScalars.count)\tanchors=\(anchors)\tstate=\(r.state)\twarnings=\(r.warnings.count)\tms=\(Int(Date().timeIntervalSince(start) * 1000))")
        } catch {
            print("\(ext)\terror\t\(String("\(error)".filter { !$0.isNumber }.prefix(80)))")
        }
    }
    exit(0)
}

let faultsAllowed = ProcessInfo.processInfo.environment["XS_EXTRACT_FAULTS"] == "1"
signal(SIGPIPE, SIG_IGN)

while let data = Framing.read(from: STDIN_FILENO) {
    guard let request = try? JSONDecoder().decode(WorkerRequest.self, from: data) else { exit(2) }
    if faultsAllowed {
        switch request.fault {
        case "hang": while true { sleep(60) }
        case "crash": abort()
        default: break
        }
    }
    var response = WorkerResponse(id: request.id, result: nil, error: nil)
    do {
        response.result = try autoreleasepool { try Extractor.extract(path: request.path, limits: request.limits) }
    } catch {
        response.error = "\(error)"
    }
    guard let out = try? JSONEncoder().encode(response), Framing.write(out, to: STDOUT_FILENO) else { exit(3) }
}
