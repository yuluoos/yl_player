pluginManagement {
 resolutionStrategy { eachPlugin { if (requested.id.id == "com.android.library") useModule("com.android.tools.build:gradle:9.0.1") } }
 repositories { google(); mavenCentral(); gradlePluginPortal() }
 plugins { id("com.android.library") version "9.0.1" }
}
rootProject.name = "yl_player_android"
