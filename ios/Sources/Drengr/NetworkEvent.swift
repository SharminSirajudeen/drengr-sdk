import Foundation

public struct NetworkEvent {
    public let method: String
    public let url: String
    public let statusCode: Int?
    public let durationMs: Int
    public let requestBodyBytes: Int
    public let responseBodyBytes: Int
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: String?
    public let responseBody: String?
    public let errorText: String?
    public let timestampMs: Int64
}
