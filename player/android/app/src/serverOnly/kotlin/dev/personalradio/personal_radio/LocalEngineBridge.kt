package dev.personalradio.personal_radio

import android.content.Context

object LocalEngineBridge {
    val available = false
    fun start(context: Context): String = error("Use the standalone build on a supported device.")
    fun stop() {}
}
