import Foundation
import os

/// Logs to the unified log (`log stream --predicate 'subsystem == "com.illixion.focusguard"'`)
/// and mirrors to stdout when run from a terminal.
enum Log {
    private static let logger = Logger(subsystem: "com.illixion.focusguard", category: "app")
    private static let tty = isatty(STDOUT_FILENO) != 0
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if tty { print("\(fmt.string(from: Date())) \(message)"); fflush(stdout) }
    }
}
