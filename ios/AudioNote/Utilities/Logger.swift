import Foundation
import os.log

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

/// The app's log.
///
/// Writes to **two** places, the same text to both:
///
/// - **stdout**, so a console attached at launch (`devicectl device process
///   launch --console`) shows the messages live. This is the only way to
///   watch a device from the command line: `log show` and `log stream` read
///   the *Mac's* unified log, and `log collect --device-udid` refuses to run
///   without root.
/// - **the unified log** (`os.Logger`), so a message can be read long after
///   the fact — Xcode's console and Console.app both read a connected
///   device's log — and so nothing logged before the console was attached is
///   lost for good. This was the whole reason for the migration: a `print`
///   only ever reached the terminal that launched the app.
///
/// Release builds log nothing, exactly as before: the messages carry record
/// ids and tag names, and a release build has no business leaving them where
/// a device backup or a sysdiagnose can pick them up.
struct Logger {
    static let subsystem = "info.karsa.app.ios.audionote"
    static let category = "SpeechRecognition"

    private static let osLog = os.Logger(subsystem: subsystem, category: category)

    static func log(
        _ message: String,
        level: LogLevel = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        // The file and line stay in the message text: the unified log keeps
        // them as metadata, but `log show` does not print them, and knowing
        // where a message came from is most of what makes it useful.
        let fileName = (file as NSString).lastPathComponent
        let text = "[\(level.rawValue)] [\(fileName):\(line)] \(function) - \(message)"

        print(text)

        switch level {
        case .debug: osLog.debug("\(text, privacy: .public)")
        case .info: osLog.info("\(text, privacy: .public)")
        case .warning: osLog.warning("\(text, privacy: .public)")
        case .error: osLog.error("\(text, privacy: .public)")
        }
        #endif
    }

    // Convenience methods
    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warning, file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    // Speech recognition specific logs
    static func speechEvent(_ event: String, details: String = "") {
        let message = details.isEmpty ? event : "\(event) - \(details)"
        log("[SPEECH] \(message)")
    }

    static func recognitionResult(_ text: String, isFinal: Bool) {
        let type = isFinal ? "FINAL" : "PARTIAL"
        log("[\(type)] \(text)")
    }
}
