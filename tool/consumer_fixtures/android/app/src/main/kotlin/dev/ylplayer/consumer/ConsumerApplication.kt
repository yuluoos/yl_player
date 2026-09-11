package dev.ylplayer.consumer

import android.app.Application
import dev.ylplayer.yl_player_android.YlPlayerAndroidPlugin

class ConsumerApplication : Application() {
    val pluginEntryPoint: Class<YlPlayerAndroidPlugin> = YlPlayerAndroidPlugin::class.java
}
