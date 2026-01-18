import Foundation
import os.log

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

struct Logger {
    static let subsystem = "info.karsa.app.ios.audionote"
    static let category = "SpeechRecognition"

    #if DEBUG
    private static let isDebug = true
    #else
    private static let isDebug = false
    #endif

    static func log(
        _ message: String,
        level: LogLevel = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(level.rawValue)] [\(fileName):\(line)] \(function) - \(message)"

        #if DEBUG
        print(logMessage)
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
