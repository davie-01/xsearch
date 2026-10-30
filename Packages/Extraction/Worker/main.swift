// xs-extract: the extraction worker process. Reads framed requests on stdin, extracts one file
// at a time, writes framed responses on stdout. Holds no state between requests, so the
// supervisor can SIGKILL and restart it at any moment.
import Extraction
import Foundation

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
