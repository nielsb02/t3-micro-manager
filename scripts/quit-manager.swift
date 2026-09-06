import AppKit

let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.t3micromanager.app")
for application in applications where !application.isTerminated {
    guard application.terminate() else {
        fputs("Micro Manager could not quit. Quit it before installing.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(10)
while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard applications.allSatisfy({ $0.isTerminated }) else {
    fputs("Micro Manager is still running; installation stopped.\n", stderr)
    exit(1)
}
