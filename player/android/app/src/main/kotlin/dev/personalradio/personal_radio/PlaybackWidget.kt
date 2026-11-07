package dev.personalradio.personal_radio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.view.View
import android.widget.RemoteViews

class PlaybackWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action !in actions) return
        val controls = session?.transportControls
        if (controls == null || occurrence == null) {
            refresh(context, force = true)
            return
        }
        when (intent.action) {
            PLAY -> controls.play()
            PAUSE -> controls.pause()
            PREVIOUS -> controls.skipToPrevious()
            NEXT -> controls.skipToNext()
        }
    }

    companion object {
        private const val PLAY = "dev.personalradio.widget.PLAY"
        private const val PAUSE = "dev.personalradio.widget.PAUSE"
        private const val PREVIOUS = "dev.personalradio.widget.PREVIOUS"
        private const val NEXT = "dev.personalradio.widget.NEXT"
        private val actions = setOf(PLAY, PAUSE, PREVIOUS, NEXT)
        private const val MAX_ART_SIZE = 384

        private var session: MediaController? = null
        private var callback: MediaController.Callback? = null
        private var occurrence: String? = null
        private var metadata: MediaMetadata? = null
        private var playing = false
        private var rendered: Display? = null

        private data class Display(
            val active: Boolean,
            val title: String?,
            val artist: String?,
            val artwork: Bitmap?,
            val playing: Boolean,
        )

        fun setOccurrence(context: Context, controller: MediaController?, id: String?) {
            occurrence = id
            attach(context, controller)
        }

        // Observe the controller audio_service installed on the activity. This
        // does not bind a second service or keep the player alive on its own.
        fun attach(context: Context, controller: MediaController?) {
            if (controller != null && session?.sessionToken != controller.sessionToken) {
                callback?.let { session?.unregisterCallback(it) }
                session = controller
                metadata = controller.metadata
                playing = isPlaying(controller.playbackState)
                callback = object : MediaController.Callback() {
                    override fun onMetadataChanged(value: MediaMetadata?) {
                        if (session !== controller) return
                        metadata = value
                        refresh(context)
                    }

                    override fun onPlaybackStateChanged(state: PlaybackState?) {
                        if (session !== controller) return
                        playing = isPlaying(state)
                        refresh(context)
                    }

                    override fun onSessionDestroyed() {
                        if (session !== controller) return
                        controller.unregisterCallback(this)
                        session = null
                        callback = null
                        metadata = null
                        playing = false
                        refresh(context)
                    }
                }.also { controller.registerCallback(it) }
            }
            refresh(context)
        }

        private fun isPlaying(state: PlaybackState?): Boolean =
            state?.state == PlaybackState.STATE_PLAYING ||
                (state?.state == PlaybackState.STATE_BUFFERING && state.playbackSpeed > 0)

        private fun display(): Display {
            // audio_service may publish the artwork later, or retain old
            // metadata after a queue clears. Only use metadata for this track.
            val active = session != null && occurrence != null
            val current = metadata?.takeIf {
                active && it.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) == occurrence
            }
            return Display(
                active,
                current?.getString(MediaMetadata.METADATA_KEY_TITLE),
                current?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                current?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART),
                active && playing,
            )
        }

        private fun refresh(context: Context, force: Boolean = false) {
            val current = display()
            if (!force && current == rendered) return
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, PlaybackWidget::class.java))
            render(context, manager, ids, current)
        }

        private fun render(
            context: Context,
            manager: AppWidgetManager,
            ids: IntArray,
            current: Display = display(),
        ) {
            if (ids.isEmpty()) return
            val views = RemoteViews(context.packageName, R.layout.playback_widget)
            val launch = Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val open = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_open, open)
            views.setOnClickPendingIntent(R.id.widget_details, open)

            views.setTextViewText(
                R.id.widget_title,
                current.title ?: context.getString(R.string.widget_label),
            )
            views.setTextViewText(
                R.id.widget_artist,
                current.artist ?: context.getString(
                    if (current.active) R.string.widget_loading else R.string.widget_open,
                ),
            )
            val artwork = current.artwork
            if (artwork != null) {
                val ratio = MAX_ART_SIZE.toFloat() / maxOf(artwork.width, artwork.height)
                val scaled = if (ratio >= 1) artwork else Bitmap.createScaledBitmap(
                    artwork,
                    (artwork.width * ratio).toInt().coerceAtLeast(1),
                    (artwork.height * ratio).toInt().coerceAtLeast(1),
                    true,
                )
                views.setImageViewBitmap(R.id.widget_art, scaled)
            }
            views.setViewVisibility(R.id.widget_art, if (artwork != null) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.widget_logo, if (artwork == null) View.VISIBLE else View.GONE)

            views.setImageViewResource(
                R.id.widget_play,
                if (current.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
            )
            views.setContentDescription(
                R.id.widget_play,
                context.getString(when {
                    current.playing -> R.string.widget_pause
                    current.active -> R.string.widget_play
                    else -> R.string.widget_open
                }),
            )
            views.setOnClickPendingIntent(
                R.id.widget_play,
                if (current.active) command(context, if (current.playing) PAUSE else PLAY) else open,
            )
            val skipVisibility = if (current.active) View.VISIBLE else View.INVISIBLE
            views.setViewVisibility(R.id.widget_previous, skipVisibility)
            views.setViewVisibility(R.id.widget_next, skipVisibility)
            views.setOnClickPendingIntent(R.id.widget_previous, command(context, PREVIOUS))
            views.setOnClickPendingIntent(R.id.widget_next, command(context, NEXT))
            manager.updateAppWidget(ids, views)
            rendered = current
        }

        private fun command(context: Context, action: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, PlaybackWidget::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE,
            )
    }
}
