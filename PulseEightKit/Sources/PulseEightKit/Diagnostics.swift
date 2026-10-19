import Foundation
#if canImport(os)
import os
#endif

/// A trail of what the connection to the matrix did, for working out why it misbehaved. On macOS it goes to the
/// unified log; read it with
///
///     log stream --level info --predicate 'subsystem == "com.bytefloater.pulseeight-control"'
///
/// (or in Console.app, filtering on that subsystem). Elsewhere it is dropped. Never holds passwords.
public enum Diagnostics {
    public static func note(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.info("\(text, privacy: .public)")
        #endif
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.bytefloater.pulseeight-control", category: "connection")
    #endif
}
