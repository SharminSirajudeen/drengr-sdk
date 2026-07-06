import Flutter
import Drengr

/// Bridges the Flutter add-on to the native Drengr iOS SDK. Fail-open throughout.
public class DrengrFlutterNativePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "drengr_flutter_native",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(DrengrFlutterNativePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
            var extra: [String: Any] = [:]
            if let id = args["install_id"] as? String, !id.isEmpty { extra["install_id"] = id }
            if let sid = args["session_id"] as? String, !sid.isEmpty { extra["session_id"] = sid }
            Drengr.start(
                publishableKey: args["publishable_key"] as? String ?? "",
                ingestURL: args["ingest_url"] as? String ?? "",
                appPackage: args["app_package"] as? String ?? "",
                maxBodyBytes: args["max_body_bytes"] as? Int ?? 64 * 1024,
                redactHeaders: Set((args["redact_headers"] as? [String]) ?? []),
                extraContext: extra
            )
            result(true)
        // HttpURLConnection is Android-only.
        case "installUrlConnectionCapture":
            result(false)
        // No set-session API in the native SDK yet; install_id unifies identity.
        case "updateSession":
            result(false)
        case "setEnabled":
            Drengr.setEnabled(args["value"] as? Bool ?? true)
            result(nil)
        case "optOut":
            Drengr.optOut()
            result(nil)
        case "optIn":
            Drengr.optIn()
            result(nil)
        case "identify":
            Drengr.identify(args["external_id"] as? String ?? "",
                            traits: args["traits"] as? [String: Any] ?? [:])
            result(nil)
        case "setExperiment":
            Drengr.setExperiment(args["key"] as? String ?? "",
                                 variant: args["variant"] as? String)
            result(nil)
        case "flush":
            Drengr.flush { DispatchQueue.main.async { result(nil) } }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
