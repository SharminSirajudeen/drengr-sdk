# Drengr SDK: keep the public API.
-keep class dev.drengr.sdk.Drengr { *; }
-keep class dev.drengr.sdk.DrengrInterceptor { *; }
-keep class dev.drengr.sdk.NetworkEvent { *; }
-keep class dev.drengr.sdk.DrengrCronetListener { *; }
# Cronet is compileOnly; consumers without it must not fail the R8 missing-class check.
-dontwarn org.chromium.net.**
