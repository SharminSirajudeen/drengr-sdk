import XCTest
@testable import Drengr

/// Parity suite mirroring classify.test.mjs — same corpus, same dispositions.
final class ClassifyTests: XCTestCase {
    private func proj(_ r: Classify.Classified) -> [String: Any] {
        guard let s = r.projection, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    func testBusinessSignalStaysPlaintext() {
        let r = Classify.classifyBody(#"{"status":"declined","decline_reason":"insufficient_funds","amount":42.5,"quantity":3,"success":false}"#)
        let p = proj(r)
        XCTAssertEqual(p["status"] as? String, "declined")
        XCTAssertEqual(p["decline_reason"] as? String, "insufficient_funds")
        XCTAssertEqual(p["amount"] as? Double, 42.5)
        XCTAssertEqual(p["quantity"] as? Int, 3)
        XCTAssertEqual(p["success"] as? Bool, false)
        XCTAssertTrue(r.piiMap.isEmpty)
        XCTAssertTrue(r.piiPaths.isEmpty)
    }

    func testPIISealedRawToPiiMap() {
        let r = Classify.classifyBody(#"{"email":"a@b.com","firstName":"John","phone":"+1 415-555-1212"}"#)
        let p = proj(r)
        XCTAssertEqual(p["email"] as? String, "[PII:email]")
        XCTAssertEqual(p["firstName"] as? String, "[PII:firstname]")
        XCTAssertEqual(p["phone"] as? String, "[PII:phone]")
        XCTAssertEqual(r.piiMap["email"], "\"a@b.com\"")
        XCTAssertEqual(r.piiMap["firstName"], "\"John\"")
        XCTAssertTrue(r.piiPaths.contains("email") && r.piiPaths.contains("phone"))
    }

    func testFailClosedNoRawPIIInProjection() {
        let raws = ["john.doe@example.com", "415-555-1212", "123-45-6789", "192.168.1.42"]
        let r = Classify.classifyBody(#"{"contact":{"email":"john.doe@example.com","phone":"415-555-1212"},"ssn":"123-45-6789","client_ip":"192.168.1.42","note":"reach me at john.doe@example.com"}"#)
        let s = r.projection ?? ""
        for raw in raws { XCTAssertFalse(s.contains(raw), "LEAK in projection: \(raw)") }
        let sealed = r.piiMap.values.joined(separator: "|")
        XCTAssertTrue(sealed.contains("john.doe@example.com"))
    }

    func testCredentialsDropped() {
        let r = Classify.classifyBody(#"{"password":"hunter2","api_key":"sk_live_ABCDEFGHIJ1234567890","card":"4111 1111 1111 1111"}"#)
        let p = proj(r)
        XCTAssertEqual(p["password"] as? String, "[REDACTED-SECRET]")
        XCTAssertTrue(String(describing: p["api_key"]).contains("REDACTED"))
        let s = r.projection ?? ""
        XCTAssertFalse(s.contains("hunter2") || s.contains("sk_live") || s.contains("4111"))
        XCTAssertFalse(r.piiMap.values.contains { $0.contains("hunter2") || $0.contains("sk_live") },
                       "credentials must NOT be in piiMap")
    }

    func testSealByDefaultFreeText() {
        let r = Classify.classifyBody(#"{"bio":"anything at all here","status":"ok"}"#)
        let p = proj(r)
        XCTAssertEqual(p["bio"] as? String, "[PII]")
        XCTAssertEqual(p["status"] as? String, "ok")
        XCTAssertTrue(r.piiPaths.contains("bio"))
    }

    func testTypedPlaceholdersPreserveType() {
        let r = Classify.classifyBody(#"{"ssn":123456789,"amount":10,"active":true}"#)
        let p = proj(r)
        XCTAssertEqual(p["ssn"] as? Int, 0)          // sealed number stays number (0)
        XCTAssertNil(p["ssn"] as? String)
        XCTAssertEqual(p["amount"] as? Int, 10)
        XCTAssertEqual(p["active"] as? Bool, true)
    }

    func testNestedArraysInheritParentKey() {
        let r = Classify.classifyBody(#"{"emails":["a@b.com","c@d.com"],"amounts":[1,2]}"#)
        let p = proj(r)
        XCTAssertEqual(p["emails.0"] as? String, "[PII:email]")
        XCTAssertEqual(p["amounts.0"] as? Int, 1)
        XCTAssertTrue(r.piiPaths.contains("emails.0") && r.piiPaths.contains("emails.1"))
    }

    func testEmptyOrNonParseable() {
        XCTAssertNil(Classify.classifyBody(nil).projection)
        XCTAssertNil(Classify.classifyBody("not json").projection)
        XCTAssertNil(Classify.classifyBody("").projection)
    }

    /// Planted PII across body + header + url: NONE may appear in projected/redacted
    /// output; business fields survive plaintext; typed placeholders preserve type.
    func testFailClosedAcrossBodyHeaderURL() {
        let secrets = ["john.doe@example.com", "415-555-1212", "123-45-6789",
                       "192.168.1.42", "550e8400-e29b-41d4-a716-446655440000", "221B Baker St"]

        let bodyProj = Classify.classifyBody(#"""
        {"email":"john.doe@example.com","phone":"415-555-1212","ssn":"123-45-6789","ip":"192.168.1.42","idfa":"550e8400-e29b-41d4-a716-446655440000","address":"221B Baker St","amount":25,"active":true,"status":"ok"}
        """#).projection ?? ""
        for s in secrets { XCTAssertFalse(bodyProj.contains(s), "body LEAK: \(s)") }
        let bp = (try? JSONSerialization.jsonObject(with: bodyProj.data(using: .utf8)!) as? [String: Any]) ?? [:]
        XCTAssertEqual(bp["amount"] as? Int, 25)       // business survives plaintext
        XCTAssertEqual(bp["active"] as? Bool, true)    // typed placeholder / value preserved
        XCTAssertEqual(bp["status"] as? String, "ok")

        let headers = Redact.redactHeaders([
            "X-User-Email": "john.doe@example.com",
            "X-Client-IP": "192.168.1.42",
            "X-Device-Id": "550e8400-e29b-41d4-a716-446655440000",
            "Accept": "application/json",
        ], extra: [])
        let hv = headers.values.joined(separator: "|")
        for s in secrets { XCTAssertFalse(hv.contains(s), "header LEAK: \(s)") }
        XCTAssertEqual(headers["Accept"], "application/json")

        let url = Redact.redactURL("https://api.x.com/v1/pay?token=SECRET&email=john.doe@example.com&ip=192.168.1.42&device=550e8400-e29b-41d4-a716-446655440000&amount=25")
        for s in secrets { XCTAssertFalse(url.contains(s), "url LEAK: \(s)") }
        XCTAssertTrue(url.contains("amount=25"))
    }
}
