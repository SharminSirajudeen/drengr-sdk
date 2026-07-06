package dev.drengr.sdk

import org.json.JSONArray
import org.json.JSONObject

// Seal-by-default body splitter (port of classify.ts). One pass over a body splits
// every leaf into DROP (credentials/PCI → [REDACTED-*], never stored), SEAL (PII +
// unknown free-text → typed placeholder in the plaintext projection; raw goes to
// piiMap for on-device encryption), or KEEP (business scalars/allowlisted enums).
// Fail-closed: a value reaches the projection ONLY if credential-free AND
// (numeric/bool not-PII OR business-allowlisted). Typed placeholders keep leaf type.
internal object Classify {
    data class Result(val projection: String?, val piiMap: Map<String, String>, val piiPaths: List<String>)

    private const val MAX_KEYS = 512
    private const val MAX_DEPTH = 12
    private const val MAX_STR = 1024
    private val normRe = Regex("[_\\-$@.\\s]")
    private fun norm(name: String) = normRe.replace(name.lowercase(), "")

    private val CREDENTIAL_NAMES = setOf(
        "password", "passwd", "pwd", "pass", "passphrase", "secret", "clientsecret", "token",
        "apikey", "apisecret", "accesstoken", "refreshtoken", "idtoken", "oauthtoken", "bearertoken",
        "privatekey", "secretkey", "sessiontoken", "authorization", "auth", "otp", "totp",
        "csrf", "xsrf", "csrftoken", "xsrftoken",
        "cvv", "cvc", "cvv2", "csc", "pin", "cardnumber", "cardno", "ccnumber", "creditcard", "pan",
    )

    private val PII_NAMES = setOf(
        "email", "phone", "mobile", "tel", "telephone", "fax",
        "firstname", "lastname", "middlename", "fullname", "username", "nickname",
        "customername", "recipientname", "sendername", "contactname",
        "ssn", "sin", "iban", "accountnumber", "routingnumber", "sortcode",
        "passport", "nationality", "dob", "dateofbirth", "birthdate",
        "address", "street", "zip", "zipcode", "postal", "postalcode",
        "lat", "latitude", "lng", "lon", "longitude", "geo", "coordinates",
        "ip", "ipaddress", "deviceid", "idfa", "gaid", "adid", "imei", "macaddress",
        "promocode", "promotioncode", "coupon", "giftmessage", "messagetext",
    )

    private val BUSINESS_ALLOWLIST = setOf(
        "status", "statuscode", "httpstatus", "responsecode", "code", "state", "result", "outcome",
        "declinereason", "declinecode", "reason", "errorcode",
        "currency", "amount", "price", "total", "subtotal", "tax", "shipping", "discount", "fee",
        "balance", "cost", "revenue", "quantity", "qty", "count",
        "sku", "productid", "itemid", "variantid", "orderid", "transactionid", "paymentid", "invoiceid",
        "plan", "planid", "tier", "type", "kind", "category", "subcategory",
        "event", "eventname", "action", "method", "httpmethod", "verb",
        "success", "ok", "enabled", "active", "error",
        "duration", "latency", "elapsed", "level", "score", "rating", "stars",
        "version", "appversion", "build", "step", "index", "page", "pagesize", "limit", "offset",
    )

    private val credRe = listOf(
        Regex("eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]*"),
        Regex("[Bb]earer\\s+[A-Za-z0-9\\-._~+/]+=*"),
        Regex("\\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\\b"),
        Regex("-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----"),
    )
    private val emailRe = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private val ssnRe = Regex("\\b\\d{3}-\\d{2}-\\d{4}\\b")
    private val phoneRe = Regex("(?:\\+\\d{1,3}[ .-]?)?\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b")
    private val ipv4Re = Regex("\\b(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\b")
    private val ipv6Re = Regex("\\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{0,4}\\b")
    private val uuidRe = Regex("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b")
    private val digitRun = Regex("[0-9](?:[ -]?[0-9]){11,}")
    private val sep = Regex("[ -]")
    private val doubleSpace = Regex("\\s{2,}")

    private sealed class Disp
    private class Keep(val v: Any) : Disp()
    private class Drop(val v: Any) : Disp()
    private class Seal(val placeholder: Any, val raw: String, val path: String) : Disp()

    private fun luhn(digits: String): Boolean {
        if (digits.length < 13) return false
        var sum = 0
        var alt = false
        for (i in digits.length - 1 downTo 0) {
            var n = digits[i].code - 48
            if (n < 0 || n > 9) return false
            if (alt) { n *= 2; if (n > 9) n -= 9 }
            sum += n
            alt = !alt
        }
        return sum % 10 == 0
    }

    private fun credentialValue(s: String) = credRe.any { it.containsMatchIn(s) }

    private fun panValue(s: String): Boolean {
        val m = digitRun.find(s) ?: return false
        val d = sep.replace(m.value, "")
        if (d.length > 40) return true
        var len = 13
        while (len <= 19 && len <= d.length) {
            var i = 0
            while (i + len <= d.length) { if (luhn(d.substring(i, i + len))) return true; i++ }
            len++
        }
        return false
    }

    private fun piiKind(s: String): String? = when {
        emailRe.containsMatchIn(s) -> "email"
        ssnRe.containsMatchIn(s) -> "ssn"
        phoneRe.containsMatchIn(s) -> "phone"
        ipv4Re.containsMatchIn(s) || ipv6Re.containsMatchIn(s) -> "ip"
        uuidRe.containsMatchIn(s) -> "deviceid"
        else -> null
    }

    private fun sameTyped(v: Any, label: String): Any = when (v) {
        is Number -> 0
        is Boolean -> false
        else -> label
    }

    private fun jsonStringify(v: Any): String = if (v is String) JSONObject.quote(v) else v.toString()

    private fun classifyLeaf(key: String, path: String, v: Any): Disp {
        val n = norm(key)
        if (v is String && (credentialValue(v) || panValue(v))) return Drop(sameTyped(v, "[REDACTED-SECRET]"))
        if (n in CREDENTIAL_NAMES) return Drop(sameTyped(v, "[REDACTED-SECRET]"))

        val vk = if (v is String) piiKind(v) else null
        if (vk != null) return Seal("[PII:$vk]", jsonStringify(v), path)
        if (n in PII_NAMES) return Seal(sameTyped(v, "[PII:$n]"), jsonStringify(v), path)

        if (v is Number || v is Boolean) return Keep(v)

        if (v is String) {
            if (v.isEmpty()) return Keep(v)
            if (v.length > MAX_STR) return Drop("[FREETEXT:len=${v.length}]")
            if (n in BUSINESS_ALLOWLIST && v.length <= 64 && !doubleSpace.containsMatchIn(v)) return Keep(v)
            return Seal("[PII]", jsonStringify(v), path)
        }
        return Drop(sameTyped(v, "[REDACTED]"))
    }

    fun classifyBody(body: String?): Result {
        val empty = Result(null, emptyMap(), emptyList())
        if (body.isNullOrEmpty()) return empty
        val decoded = parseJson(body) ?: parseForm(body) ?: return empty

        val proj = JSONObject()
        val piiMap = LinkedHashMap<String, String>()
        val piiPaths = ArrayList<String>()

        fun walk(prefix: String, key: String, v: Any?, depth: Int) {
            if (proj.length() >= MAX_KEYS || depth > MAX_DEPTH) return
            when {
                v is JSONArray -> {
                    var i = 0
                    while (i < v.length() && proj.length() < MAX_KEYS) {
                        walk(if (prefix.isEmpty()) "$i" else "$prefix.$i", key, v.get(i), depth + 1); i++
                    }
                }
                v is JSONObject -> for (k in v.keys()) {
                    if (proj.length() >= MAX_KEYS) break
                    walk(if (prefix.isEmpty()) k else "$prefix.$k", k, v.get(k), depth + 1)
                }
                v == null || v === JSONObject.NULL -> {}
                else -> when (val d = classifyLeaf(key, prefix, v)) {
                    is Keep -> proj.put(prefix, d.v)
                    is Drop -> proj.put(prefix, d.v)
                    is Seal -> { proj.put(prefix, d.placeholder); piiMap[d.path] = d.raw; piiPaths.add(d.path) }
                }
            }
        }

        return try {
            walk("", "", decoded, 0)
            if (proj.length() == 0) empty else Result(proj.toString(), piiMap, piiPaths)
        } catch (_: Throwable) {
            empty
        }
    }

    private fun parseJson(body: String): Any? {
        val t = body.trimStart()
        if (t.isEmpty() || (t[0] != '{' && t[0] != '[')) return null
        return try {
            if (t[0] == '{') JSONObject(body) else JSONArray(body)
        } catch (_: Throwable) { null }
    }

    private val formShape = Regex("^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$")
    private fun parseForm(body: String): JSONObject? {
        if (!body.contains('=') || body.contains('\n') || body.contains(' ')) return null
        if (!formShape.matches(body)) return null
        val o = JSONObject()
        for (pair in body.split('&')) {
            val i = pair.indexOf('='); if (i <= 0) continue
            val k = try { java.net.URLDecoder.decode(pair.substring(0, i), "UTF-8") } catch (_: Throwable) { pair.substring(0, i) }
            val v = try { java.net.URLDecoder.decode(pair.substring(i + 1), "UTF-8") } catch (_: Throwable) { pair.substring(i + 1) }
            o.put(k, v)
        }
        return if (o.length() == 0) null else o
    }
}
