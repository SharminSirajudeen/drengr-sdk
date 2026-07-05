package dev.drengr.sdk

import org.json.JSONArray
import org.json.JSONObject

// Secret + PII redaction for captured events (port of redact.dart/js): structural
// key-masking + value-level scrubbing; best-effort, never throws (input unchanged).
internal object Redact {
    const val MASK = "[REDACTED]"

    /** Header names (lowercase) whose values are always masked. */
    val sensitiveHeaders = setOf(
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-auth-token", "x-api-key", "x-access-token", "x-session-token",
        "x-secret", "www-authenticate", "proxy-authenticate",
        "x-csrf-token", "x-xsrf-token",
    )

    // Whole-name matches (short tokens live here, not as substrings).
    private val sensitiveExact = setOf(
        "password", "passwd", "pwd", "pass", "passphrase", "secret", "token",
        "authorization", "pin", "cvv", "cvc", "csc", "cvv2", "ssn", "sin",
        "otp", "totp", "iban",
    )

    // Longer fragments safe as substrings of a normalized name.
    private val sensitiveFragments = listOf(
        "token", "secret", "password", "passphrase", "apikey", "apisecret",
        "accesstoken", "refreshtoken", "idtoken", "oauthtoken", "privatekey",
        "secretkey", "sessiontoken", "cardnumber", "cardno", "ccnumber",
        "creditcard", "accountnumber", "routingnumber", "sortcode",
        // Rare-substring credential tokens as fragments so COMPOUND names are
        // caught (card_cvv, payment_otp, user_ssn); pin/pass/sin stay exact-only.
        "cvv", "cvc", "cvv2", "ssn", "otp", "totp",
        // PII, redacted by default — 0-code means 0-code PII safety.
        "email", "phone", "firstname", "lastname", "fullname", "username",
        "recipientname", "customername", "sendername", "passport", "nationality",
        "address", "birthdate", "dateofbirth", "promocode", "promotioncode",
        "messagetext", "giftmessage",
    )

    private val normalize = Regex("[_\\-$@.\\s]")

    fun isSensitiveName(name: String): Boolean {
        val n = normalize.replace(name.lowercase(), "")
        if (n in sensitiveExact) return true
        return sensitiveFragments.any { n.contains(it) }
    }

    fun redactHeaders(headers: Map<String, String>, extra: Set<String>): Map<String, String> {
        val out = LinkedHashMap<String, String>(headers.size)
        for ((k, v) in headers) {
            val lk = k.lowercase()
            out[k] = if (lk in sensitiveHeaders || lk in extra) MASK else v
        }
        return out
    }

    // --- value-level scrubbers ---
    private val digitRun = Regex("[0-9](?:[ -]?[0-9]){11,}")
    private val jwt = Regex("eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]*")
    private val bearer = Regex("[Bb]earer\\s+[A-Za-z0-9\\-._~+/]+=*")
    private val cookieLine = Regex("(?im)^(set-cookie|cookie)\\s*:\\s*.*$")
    // Free-text PII by VALUE PATTERN (audit blocker #1). Phone needs separators
    // so bare id/timestamp digit-runs aren't hit.
    private val email = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private val ssn = Regex("\\b\\d{3}-\\d{2}-\\d{4}\\b")
    private val phone = Regex("(?:\\+\\d{1,3}[ .-]?)?\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b")
    // Well-known opaque SECRETS by unambiguous vendor prefix — catches a key under a
    // benign field name (name-masking misses). Zero-FP by anchoring on the prefix.
    private val secretToken = Regex(
        "\\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\\b")
    private val pem = Regex("-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z0-9 ]*PRIVATE KEY-----")

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

    fun scrubValues(s: String): String {
        var out = digitRun.replace(s) { m ->
            val digits = m.value.replace(Regex("[ -]"), "")
            if (digits.length > 40) return@replace "[REDACTED-PAN]"
            var len = 13
            while (len <= 19 && len <= digits.length) {
                var i = 0
                while (i + len <= digits.length) {
                    if (luhn(digits.substring(i, i + len))) return@replace "[REDACTED-PAN]"
                    i++
                }
                len++
            }
            m.value
        }
        out = jwt.replace(out, "[REDACTED-JWT]")
        out = bearer.replace(out, "Bearer $MASK")
        out = cookieLine.replace(out) { m -> "${m.groupValues[1]}: $MASK" }
        out = email.replace(out, "[REDACTED-EMAIL]")
        out = ssn.replace(out, "[REDACTED-SSN]")
        out = phone.replace(out, "[REDACTED-PHONE]")
        out = secretToken.replace(out, "[REDACTED-SECRET]")
        out = pem.replace(out, "[REDACTED-KEY]")
        return out
    }

    fun redactUrl(url: String): String {
        return try {
            val q = url.indexOf('?')
            if (q < 0) return scrubValues(url)
            val base = url.substring(0, q)
            val frag = url.indexOf('#', q)
            val queryEnd = if (frag < 0) url.length else frag
            val query = url.substring(q + 1, queryEnd)
            val tail = if (frag < 0) "" else url.substring(frag)
            val maskedQuery = query.split('&').joinToString("&") { pair ->
                val i = pair.indexOf('=')
                if (i > 0 && isSensitiveName(pair.substring(0, i))) {
                    "${pair.substring(0, i)}=$MASK"
                } else pair
            }
            scrubValues("$base?$maskedQuery$tail")
        } catch (_: Throwable) {
            url
        }
    }

    // --- named-value scrubbers (net secrets structural + value passes miss) ---
    // Mask a value whenever its adjacent NAME is sensitive — for bodies key-masking
    // can't reach (JSON truncated past the cap, XML/SOAP) and inline literals in a
    // parsed JSON string (GraphQL `query`). Value stops at any backslash/quote so a
    // JSON-wrapped literal matches the INNERMOST name:"value" pair. Bounded → no ReDoS.
    // escNamed runs FIRST (anchored on the escaped quote) so a plain-quote wrapper
    // can't shadow the first inner literal.
    private val escNamed = Regex("([A-Za-z][A-Za-z0-9_.\\-]{0,63})(\\s*[:=]\\s*)\\\\\"[^\"\\\\]{0,8192}\\\\\"")
    private val dqNamed = Regex("([\"']?)([A-Za-z][A-Za-z0-9_.\\-]{0,63})\\1(\\s*[:=]\\s*\\\\?\")[^\"\\\\]{0,8192}(\\\\?\")")
    private val sqNamed = Regex("([\"']?)([A-Za-z][A-Za-z0-9_.\\-]{0,63})\\1(\\s*[:=]\\s*\\\\?')[^'\\\\]{0,8192}(\\\\?')")
    private val xmlElem = Regex("<([A-Za-z][A-Za-z0-9_.\\-:]{0,63})>[^<]{0,8192}</\\1\\s*>")
    private val jsonNum = Regex("(\"[A-Za-z][A-Za-z0-9_.\\-]{0,63}\"\\s*:\\s*)(-?\\d[\\d.eE+\\-]{0,40}|true|false)")

    /** Mask values whose adjacent name is sensitive (see note above). Best-effort. */
    fun scrubNamedValues(s: String): String {
        var out = escNamed.replace(s) { m ->
            val (name, sep) = m.destructured
            if (isSensitiveName(name)) "$name$sep\\\"$MASK\\\"" else m.value
        }
        out = dqNamed.replace(out) { m ->
            val (q, name, sep, close) = m.destructured
            if (isSensitiveName(name)) "$q$name$q$sep$MASK$close" else m.value
        }
        out = sqNamed.replace(out) { m ->
            val (q, name, sep, close) = m.destructured
            if (isSensitiveName(name)) "$q$name$q$sep$MASK$close" else m.value
        }
        out = xmlElem.replace(out) { m ->
            val name = m.groupValues[1]
            if (isSensitiveName(name)) "<$name>$MASK</$name>" else m.value
        }
        out = jsonNum.replace(out) { m ->
            val head = m.groupValues[1]
            val name = head.substring(1, head.indexOf('"', 1))
            if (isSensitiveName(name)) "$head$MASK" else m.value
        }
        return out
    }

    fun redactBody(body: String): String {
        val out = try {
            val t = body.trimStart()
            when {
                t.startsWith("{") -> scrubValues(redactJsonObject(JSONObject(body)).toString())
                t.startsWith("[") -> scrubValues(redactJsonArray(JSONArray(body)).toString())
                looksFormEncoded(body) -> scrubValues(redactForm(body))
                else -> scrubValues(body)
            }
        } catch (_: Throwable) {
            scrubValues(body)
        }
        // Net values sensitive by NAME only that survived structural + value passes.
        return scrubNamedValues(out)
    }

    private fun redactJsonObject(o: JSONObject): JSONObject {
        val out = JSONObject()
        for (k in o.keys()) {
            out.put(k, if (isSensitiveName(k)) MASK else redactJsonValue(o.get(k)))
        }
        return out
    }

    private fun redactJsonArray(a: JSONArray): JSONArray {
        val out = JSONArray()
        for (i in 0 until a.length()) out.put(redactJsonValue(a.get(i)))
        return out
    }

    private fun redactJsonValue(v: Any?): Any? = when (v) {
        is JSONObject -> redactJsonObject(v)
        is JSONArray -> redactJsonArray(v)
        else -> v
    }

    private val formShape = Regex("^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$")
    private fun looksFormEncoded(body: String): Boolean {
        if (!body.contains('=') || body.contains('\n') || body.contains(' ')) return false
        return formShape.matches(body)
    }

    private fun redactForm(body: String): String =
        body.split('&').joinToString("&") { pair ->
            val i = pair.indexOf('=')
            if (i <= 0) return@joinToString pair
            val key = pair.substring(0, i)
            val name = try { java.net.URLDecoder.decode(key, "UTF-8") } catch (_: Throwable) { key }
            if (isSensitiveName(name)) return@joinToString "$key=$MASK"
            // Scrub the DECODED value — an encoded value (e.g. a PAN with %20 seps)
            // would slip the outer scrubValues, then projectBody ships the real secret.
            val raw = pair.substring(i + 1)
            val decoded = try { java.net.URLDecoder.decode(raw, "UTF-8") } catch (_: Throwable) { raw }
            "$key=${scrubValues(decoded)}"
        }

    // --- safe projection (the annotatable DTO shipped to the server) ---
    private const val PROJ_MAX_KEYS = 512
    private const val PROJ_MAX_DEPTH = 12
    private const val PROJ_MAX_STR = 1024

    /** Project an already-redacted body into `dotted.path -> scalar`, keeping only
     *  analytics scalars (num/bool/short non-mask strings). Returns null when
     *  nothing structured/safe remains. */
    fun projectBody(body: String?): String? {
        if (body.isNullOrEmpty()) return null
        return try {
            val t = body.trimStart()
            val out = JSONObject()
            when {
                t.startsWith("{") -> flatten("", JSONObject(body), out, 0)
                t.startsWith("[") -> flatten("", JSONArray(body), out, 0)
                looksFormEncoded(body) -> {
                    for (pair in body.split('&')) {
                        val i = pair.indexOf('='); if (i <= 0) continue
                        val k = try { java.net.URLDecoder.decode(pair.substring(0, i), "UTF-8") } catch (_: Throwable) { pair.substring(0, i) }
                        val v = try { java.net.URLDecoder.decode(pair.substring(i + 1), "UTF-8") } catch (_: Throwable) { pair.substring(i + 1) }
                        putScalar(out, k, v)
                    }
                }
                else -> return null
            }
            if (out.length() == 0) null else out.toString()
        } catch (_: Throwable) {
            null
        }
    }

    private fun flatten(prefix: String, v: Any?, out: JSONObject, depth: Int) {
        if (out.length() >= PROJ_MAX_KEYS || depth > PROJ_MAX_DEPTH) return
        when (v) {
            is JSONObject -> for (k in v.keys()) {
                if (out.length() >= PROJ_MAX_KEYS) break
                flatten(if (prefix.isEmpty()) k else "$prefix.$k", v.get(k), out, depth + 1)
            }
            is JSONArray -> {
                var i = 0
                while (i < v.length() && out.length() < PROJ_MAX_KEYS) {
                    flatten(if (prefix.isEmpty()) "$i" else "$prefix.$i", v.get(i), out, depth + 1); i++
                }
            }
            is String -> putScalar(out, prefix, v)
            is Number, is Boolean -> out.put(prefix, v)
            // JSONObject.NULL / other: skip
        }
    }

    private fun putScalar(out: JSONObject, key: String, v: String) {
        if (v.isEmpty() || v.length > PROJ_MAX_STR) return
        if (v.startsWith("[REDACTED")) return
        out.put(key, v)
    }
}
