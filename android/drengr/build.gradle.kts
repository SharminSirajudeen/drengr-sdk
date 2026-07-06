import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "dev.drengr.sdk"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // compileOnly: the SDK must never hard-require Cronet (class-load guarded adapter).
    compileOnly("org.chromium.net:cronet-api:119.6045.31")
    // compileOnly: compose-ui is never hard-required either (class-load guarded tap hook).
    compileOnly("androidx.compose.ui:ui:1.7.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.chromium.net:cronet-api:119.6045.31")
    testImplementation("androidx.compose.ui:ui:1.7.5")
}

mavenPublishing {
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL)
    signAllPublications()

    coordinates("dev.drengr", "analytics-android", "0.2.0")

    pom {
        name.set("Drengr Analytics (Android)")
        description.set(
            "0-code mobile analytics SDK for Android — captures network + behavior, " +
                "redacts PII on-device."
        )
        url.set("https://drengr.dev")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("SharminSirajudeen")
                name.set("Sharmin Sirajudeen")
                email.set("sharminsirajudeen11@gmail.com")
            }
        }
        scm {
            url.set("https://github.com/SharminSirajudeen/drengr-sdk")
            connection.set("scm:git:git://github.com/SharminSirajudeen/drengr-sdk.git")
            developerConnection.set(
                "scm:git:ssh://git@github.com/SharminSirajudeen/drengr-sdk.git"
            )
        }
    }
}
