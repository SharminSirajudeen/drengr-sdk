package dev.drengr.sdk

import java.io.InputStream
import java.io.OutputStream
import java.net.URL
import java.security.Permission
import java.security.Principal
import java.security.cert.Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

/** Delegating HttpsURLConnection twin of [DrengrHttpURLConnection] (SSL surface kept). */
internal class DrengrHttpsURLConnection(
    u: URL,
    private val d: HttpsURLConnection,
) : HttpsURLConnection(u) {
    private val x = UrlExchange(d, u.toString())

    override fun getCipherSuite(): String = d.cipherSuite
    override fun getLocalCertificates(): Array<Certificate>? = d.localCertificates
    override fun getServerCertificates(): Array<Certificate> = d.serverCertificates
    override fun getPeerPrincipal(): Principal = d.peerPrincipal
    override fun getLocalPrincipal(): Principal? = d.localPrincipal
    override fun setHostnameVerifier(v: HostnameVerifier) { d.hostnameVerifier = v }
    override fun getHostnameVerifier(): HostnameVerifier = d.hostnameVerifier
    override fun setSSLSocketFactory(f: SSLSocketFactory) { d.sslSocketFactory = f }
    override fun getSSLSocketFactory(): SSLSocketFactory = d.sslSocketFactory

    override fun connect() {
        x.begin()
        d.connect()
    }

    override fun disconnect() {
        try { x.finish(null) } catch (_: Throwable) {}
        d.disconnect()
    }

    override fun usingProxy(): Boolean = d.usingProxy()

    override fun getResponseCode(): Int {
        x.begin()
        return try { d.responseCode.also { x.noteStatus(it) } } catch (e: Throwable) { x.finish(e); throw e }
    }

    override fun getResponseMessage(): String? = d.responseMessage

    override fun getInputStream(): InputStream {
        x.begin()
        return try {
            val s = d.inputStream
            x.noteStatus(try { d.responseCode } catch (_: Throwable) { 0 })
            x.input(s)
        } catch (e: Throwable) {
            x.noteStatus(try { d.responseCode } catch (_: Throwable) { 0 })
            x.finish(e)
            throw e
        }
    }

    override fun getOutputStream(): OutputStream {
        x.begin()
        return try { x.output(d.outputStream) } catch (e: Throwable) { x.finish(e); throw e }
    }

    override fun getErrorStream(): InputStream? =
        try { x.errorStream(d.errorStream) } catch (_: Throwable) { d.errorStream }

    override fun setRequestMethod(method: String?) { d.requestMethod = method }
    override fun getRequestMethod(): String = d.requestMethod

    override fun setRequestProperty(key: String?, value: String?) {
        d.setRequestProperty(key, value)
        x.recordHeader(key, value, add = false)
    }

    override fun addRequestProperty(key: String?, value: String?) {
        d.addRequestProperty(key, value)
        x.recordHeader(key, value, add = true)
    }

    override fun getRequestProperty(key: String?): String? = d.getRequestProperty(key)
    override fun getRequestProperties(): Map<String, List<String>> = d.requestProperties

    override fun getHeaderField(name: String?): String? = d.getHeaderField(name)
    override fun getHeaderField(n: Int): String? = d.getHeaderField(n)
    override fun getHeaderFieldKey(n: Int): String? = d.getHeaderFieldKey(n)
    override fun getHeaderFields(): Map<String, List<String>> = d.headerFields
    override fun getHeaderFieldInt(name: String?, default: Int): Int = d.getHeaderFieldInt(name, default)
    override fun getHeaderFieldDate(name: String?, default: Long): Long = d.getHeaderFieldDate(name, default)

    override fun getContentLength(): Int = d.contentLength
    override fun getContentType(): String? = d.contentType
    override fun getContentEncoding(): String? = d.contentEncoding
    override fun getExpiration(): Long = d.expiration
    override fun getDate(): Long = d.date
    override fun getLastModified(): Long = d.lastModified
    override fun getPermission(): Permission = d.permission
    override fun getURL(): URL = d.url

    override fun setDoInput(v: Boolean) { d.doInput = v }
    override fun getDoInput(): Boolean = d.doInput
    override fun setDoOutput(v: Boolean) { d.doOutput = v }
    override fun getDoOutput(): Boolean = d.doOutput
    override fun setUseCaches(v: Boolean) { d.useCaches = v }
    override fun getUseCaches(): Boolean = d.useCaches
    override fun setDefaultUseCaches(v: Boolean) { d.defaultUseCaches = v }
    override fun getDefaultUseCaches(): Boolean = d.defaultUseCaches
    override fun setAllowUserInteraction(v: Boolean) { d.allowUserInteraction = v }
    override fun getAllowUserInteraction(): Boolean = d.allowUserInteraction
    override fun setIfModifiedSince(v: Long) { d.ifModifiedSince = v }
    override fun getIfModifiedSince(): Long = d.ifModifiedSince
    override fun setConnectTimeout(t: Int) { d.connectTimeout = t }
    override fun getConnectTimeout(): Int = d.connectTimeout
    override fun setReadTimeout(t: Int) { d.readTimeout = t }
    override fun getReadTimeout(): Int = d.readTimeout
    override fun setInstanceFollowRedirects(v: Boolean) { d.instanceFollowRedirects = v }
    override fun getInstanceFollowRedirects(): Boolean = d.instanceFollowRedirects
    override fun setFixedLengthStreamingMode(len: Int) = d.setFixedLengthStreamingMode(len)
    override fun setFixedLengthStreamingMode(len: Long) = d.setFixedLengthStreamingMode(len)
    override fun setChunkedStreamingMode(len: Int) = d.setChunkedStreamingMode(len)

    override fun toString(): String = d.toString()
}
