import Foundation

/// A single captured HTTP exchange (already redacted by the capture layer).
public struct NetworkEvent {
    public let method: String
    public let url: String
    public let statusCode: Int?
    public let durationMs: Int
    public let requestBodyBytes: Int
    public let responseBodyBytes: Int
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    /// Redacted request body text (textual bodies only, capped).
    public let requestBody: String?
    /// Redacted response body text (textual bodies only, capped).
    public let responseBody: String?
    public let errorText: String?
    public let timestampMs: Int64
}
