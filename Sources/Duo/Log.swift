import OSLog

/// Read with: log show --predicate 'subsystem == "app.duo"' --last 5m --info
enum Log {
    static let engine = Logger(subsystem: "app.duo", category: "engine")
    static let capture = Logger(subsystem: "app.duo", category: "capture")
}
