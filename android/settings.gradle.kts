pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
    plugins {
        id("com.android.library") version "8.6.1"
        id("org.jetbrains.kotlin.android") version "2.0.21"
        id("com.vanniktech.maven.publish") version "0.30.0"
    }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "drengr-android"
include(":drengr")
