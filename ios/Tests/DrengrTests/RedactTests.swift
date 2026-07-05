import XCTest
@testable import Drengr

final class RedactTests: XCTestCase {
    func testSensitiveNames() {
        for n in ["password", "PWD", "api_key", "access-token", "creditCard", "email", "phoneNumber", "firstName"] {
            XCTAssertTrue(Redact.isSensitiveName(n), n)
        }
        for n in ["shipping", "spinner", "opinion", "session_id", "signature", "productId"] {
            XCTAssertFalse(Redact.isSensitiveName(n), n)
        }
    }

    func testCompoundNames() {
        for n in ["card_cvv", "paymentOtp", "user_ssn", "cvc2", "totp_code"] {
            XCTAssertTrue(Redact.isSensitiveName(n), n)
        }
        for n in ["passenger", "business"] {
            XCTAssertFalse(Redact.isSensitiveName(n), n)
        }
    }

    func testHeaders() {
        let out = Redact.redactHeaders(["Authorization": "Bearer abc", "X-Api-Key": "k", "Accept": "application/json"], extra: [])
        XCTAssertEqual(out["Authorization"], "[REDACTED]")
        XCTAssertEqual(out["X-Api-Key"], "[REDACTED]")
        XCTAssertEqual(out["Accept"], "application/json")
    }

    func testScrub() {
        XCTAssertTrue(Redact.scrubValues("card 4111 1111 1111 1111 end").contains("REDACTED-PAN"))
        XCTAssertEqual(Redact.scrubValues("id 1234 5678 has 8 digits"), "id 1234 5678 has 8 digits")
        XCTAssertTrue(Redact.scrubValues("t=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc").contains("REDACTED-JWT"))
        XCTAssertTrue(Redact.scrubValues("Authorization: Bearer sk_live_9xabcdef").contains("Bearer [REDACTED]"))
    }

    func testSecretPrefixes() {
        XCTAssertTrue(Redact.scrubValues("k=sk_live_abcdef0123456789ABCDEF").contains("REDACTED-SECRET"))
        XCTAssertTrue(Redact.scrubValues("AKIAIOSFODNN7EXAMPLE").contains("REDACTED-SECRET"))
        XCTAssertTrue(Redact.scrubValues("ghp_" + String(repeating: "a", count: 36)).contains("REDACTED-SECRET"))
        XCTAssertEqual(Redact.scrubValues("pk_live_51H8xYzPublishableKey"), "pk_live_51H8xYzPublishableKey")
        XCTAssertEqual(Redact.scrubValues("order_12345"), "order_12345")
    }

    func testURL() {
        let r = Redact.redactURL("https://api.x.com/v1/pay?token=SECRET&amount=25&email=a@b.com")
        XCTAssertTrue(r.contains("token=[REDACTED]"))
        XCTAssertFalse(r.contains("a@b.com"))
        XCTAssertTrue(r.contains("amount=25"))
    }

    func testRelativeURL() {
        let r = Redact.redactURL("/api/pay?token=SECRET&amount=25")
        XCTAssertTrue(r.contains("token=[REDACTED]"))
        XCTAssertTrue(r.contains("amount=25"))
        XCTAssertTrue(r.hasPrefix("/api/pay"))
    }

    func testJSONBody() throws {
        let r = Redact.redactBody(#"{"password":"hunter2","amount":25,"nested":{"cvv":"123","ok":true}}"#)
        let o = try JSONSerialization.jsonObject(with: r.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(o["password"] as? String, "[REDACTED]")
        let nested = o["nested"] as! [String: Any]
        XCTAssertEqual(nested["cvv"] as? String, "[REDACTED]")
        XCTAssertEqual(o["amount"] as? Int, 25)
        XCTAssertEqual(nested["ok"] as? Bool, true)
    }

    func testFormBody() {
        let r = Redact.redactBody("user=alice&password=hunter2&amount=25")
        XCTAssertTrue(r.contains("password=[REDACTED]"))
        XCTAssertTrue(r.contains("amount=25"))
    }

    func testProjection() throws {
        let big = String(repeating: "x", count: 2000)
        let r = Redact.projectBody(#"{"meta":{"status":"DECLINED"},"amount":25,"ok":true,"secretField":"[REDACTED]","note":"\#(big)"}"#)
        let o = try JSONSerialization.jsonObject(with: r!.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(o["meta.status"] as? String, "DECLINED")
        XCTAssertEqual(o["amount"] as? Int, 25)
        XCTAssertEqual(o["ok"] as? Bool, true)
        XCTAssertNil(o["secretField"])
        XCTAssertNil(o["note"])
    }

    func testFailOpen() {
        _ = Redact.scrubValues("garbage  ")
        _ = Redact.redactURL("::::not a url::::")
        _ = Redact.redactBody("{unterminated")
        XCTAssertNil(Redact.projectBody("not json not form"))
        XCTAssertNil(Redact.projectBody(""))
    }

    func testFreeTextPII() {
        let b = Redact.redactBody(#"{"note":"reach me at john.doe@x.com or 555-123-4567","field":"123-45-6789","amount":25}"#)
        XCTAssertFalse(b.contains("john.doe@x.com"))
        XCTAssertFalse(b.contains("555-123-4567"))
        XCTAssertFalse(b.contains("123-45-6789"))
        XCTAssertTrue(b.contains("REDACTED-EMAIL"))
        XCTAssertEqual(Redact.scrubValues("order 1234567890 shipped"), "order 1234567890 shipped")
    }

    func testFormEncodedValueScrubbed() {
        let b = Redact.redactBody("cc=4111%201111%201111%201111&amount=25")
        XCTAssertFalse(b.replacingOccurrences(of: "%20", with: " ").contains("4111 1111 1111 1111"))
        XCTAssertTrue(b.contains("REDACTED-PAN"))
    }

    private let pwd = "hunter2secret"
    private let addr = "221B Baker St"

    func testLeakTruncatedJSONDoubleQuoted() {
        let b = Redact.redactBody(#"{"user":"bob","address":"221B Baker St","password":"hunter2secret""#)
        XCTAssertFalse(b.contains(pwd), b)
        XCTAssertFalse(b.contains(addr), b)
        XCTAssertTrue(b.contains("password"))
        XCTAssertTrue(b.contains("[REDACTED]"))
    }

    func testLeakSingleQuoted() {
        let b = Redact.redactBody("{'user':'bob','password':'hunter2secret','address':'221B Baker St'")
        XCTAssertFalse(b.contains(pwd), b)
        XCTAssertFalse(b.contains(addr), b)
        XCTAssertTrue(b.contains("[REDACTED]"))
    }

    func testLeakXMLElement() {
        let b = Redact.redactBody("<root><user>bob</user><password>hunter2secret</password><address>221B Baker St</address></root>")
        XCTAssertFalse(b.contains(pwd), b)
        XCTAssertFalse(b.contains(addr), b)
        XCTAssertTrue(b.contains("<password>[REDACTED]</password>"))
        XCTAssertTrue(b.contains("<user>bob</user>"))
    }

    func testLeakJSONNumericUnderQuotedKey() {
        let b = Redact.redactBody(#"{"amount":25,"otp":987654,"pin":1234"#)
        XCTAssertFalse(b.contains("987654"), b)
        XCTAssertFalse(b.contains("1234"), b)
        XCTAssertTrue(b.contains("amount\":25"))
        XCTAssertTrue(b.contains("[REDACTED]"))
    }

    func testLeakGraphQLInlineLiteral() {
        let b = Redact.redactBody(#"{"query":"mutation { register(city:\"NYC\", password:\"hunter2secret\", address:\"221B Baker St\") }"}"#)
        XCTAssertFalse(b.contains(pwd), b)
        XCTAssertFalse(b.contains(addr), b)
        XCTAssertTrue(b.contains("[REDACTED]"))
    }

    func testLeakGraphQLFirstArg() {
        let b = Redact.redactBody(#"{"query":"mutation { login(password:\"hunter2secret\", note:\"x\") }"}"#)
        XCTAssertFalse(b.contains(pwd), b)
        XCTAssertTrue(b.contains("[REDACTED]"))
    }

    func testWellFormedJSONControlStillRedacts() throws {
        let b = Redact.redactBody(#"{"password":"hunter2secret","address":"221B Baker St","amount":25,"ok":true}"#)
        let o = try JSONSerialization.jsonObject(with: b.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(o["password"] as? String, "[REDACTED]")
        XCTAssertEqual(o["address"] as? String, "[REDACTED]")
        XCTAssertEqual(o["amount"] as? Int, 25)
        XCTAssertEqual(o["ok"] as? Bool, true)
    }

    func testScrubNamedValuesIdempotent() {
        let inputs = [
            #"{"password":"hunter2secret""#,
            "<password>hunter2secret</password>",
            #"{"otp":987654"#,
        ]
        for s in inputs {
            let once = Redact.scrubNamedValues(s)
            XCTAssertEqual(Redact.scrubNamedValues(once), once, s)
        }
    }
}
