package com.apparence.camerawesome.cameraX

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.camera.view.PreviewView
import androidx.lifecycle.Observer
import kotlin.math.max

/// Covers the native preview with a blurred still of its last frame while CameraX
/// rebinds for an aspect-ratio change, then fades it out once the new stream is on
/// screen — the transition Samsung's camera app uses. Without it the rebind tears
/// the stream down and the black container shows through for a few hundred ms.
///
/// Main thread only. Lives inside the preview platform view's container, on top
/// of the PreviewView, so it is sized and clipped by the same Flutter box.
internal class PreviewFreezeFrame(private val container: FrameLayout) {
    private val handler = Handler(Looper.getMainLooper())
    private val revealOnTimeout = Runnable { reveal() }

    private var overlay: ImageView? = null
    private var watchedPreview: PreviewView? = null

    /// The rebind first drops the stream to IDLE; only a STREAMING that follows
    /// it is the new stream. (LiveData also replays the current STREAMING the
    /// moment we subscribe, which must not reveal.)
    private var sawStreamStop = false

    private val streamObserver = Observer<PreviewView.StreamState> { state ->
        when (state) {
            PreviewView.StreamState.IDLE -> sawStreamStop = true
            PreviewView.StreamState.STREAMING -> if (sawStreamStop) reveal()
        }
    }

    /// Freezes [previewView]'s current frame, blurred, on top of it. Call right
    /// before the rebind, while the old stream is still displayed. A second call
    /// mid-transition keeps the frame already up (the preview behind it is no
    /// longer showing anything worth freezing) and restarts the wait.
    fun cover(previewView: PreviewView) {
        val current = overlay
        if (current == null) {
            // Null when nothing is displayed yet (first open) — nothing to cover.
            val frame = previewView.bitmap ?: return
            val blurred = blurredThumbnail(frame)
            frame.recycle()
            overlay = ImageView(container.context).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageBitmap(blurred)
                isClickable = false
                isFocusable = false
                container.addView(
                    this,
                    FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
                )
            }
        } else {
            // Caught mid fade-out: bring it back.
            current.animate().cancel()
            current.alpha = 1f
        }
        watch(previewView)
        handler.removeCallbacks(revealOnTimeout)
        handler.postDelayed(revealOnTimeout, MAX_COVER_MS)
    }

    /// Drops the overlay immediately (the platform view is going away).
    fun dispose() {
        handler.removeCallbacks(revealOnTimeout)
        unwatch()
        overlay?.let { container.removeView(it) }
        overlay = null
    }

    private fun reveal() {
        handler.removeCallbacks(revealOnTimeout)
        unwatch()
        val view = overlay ?: return
        overlay = null
        view.animate()
            .alpha(0f)
            .setDuration(FADE_OUT_MS)
            .withEndAction { container.removeView(view) }
            .start()
    }

    private fun watch(previewView: PreviewView) {
        unwatch()
        sawStreamStop = false
        watchedPreview = previewView
        previewView.previewStreamState.observeForever(streamObserver)
    }

    private fun unwatch() {
        watchedPreview?.previewStreamState?.removeObserver(streamObserver)
        watchedPreview = null
    }

    companion object {
        /// Fallback if the new stream never reports STREAMING (e.g. the bind
        /// failed): don't leave a stale frame up. A rebind normally takes
        /// 300-700 ms.
        private const val MAX_COVER_MS = 1500L
        private const val FADE_OUT_MS = 200L

        /// The frame is shrunk this much before blurring: the blur is then cheap
        /// (a few thousand pixels), and the bilinear upscale back to the view
        /// softens it further.
        private const val DOWNSCALE = 12
        private const val BLUR_RADIUS = 2
        private const val BLUR_PASSES = 2

        /// A small, box-blurred copy of [frame]. Software so it looks the same on
        /// every API level (RenderEffect is 31+). Two box passes approximate a
        /// Gaussian.
        fun blurredThumbnail(frame: Bitmap): Bitmap {
            val width = max(1, frame.width / DOWNSCALE)
            val height = max(1, frame.height / DOWNSCALE)
            val small = Bitmap.createScaledBitmap(frame, width, height, true)
                .let { if (it.isMutable && it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, true) }
            val pixels = IntArray(width * height)
            small.getPixels(pixels, 0, width, 0, 0, width, height)
            val scratch = IntArray(pixels.size)
            repeat(BLUR_PASSES) {
                boxBlur(pixels, scratch, width, height, BLUR_RADIUS, horizontal = true)
                boxBlur(scratch, pixels, width, height, BLUR_RADIUS, horizontal = false)
            }
            small.setPixels(pixels, 0, width, 0, 0, width, height)
            return small
        }

        /// One box-blur pass over ARGB [src] into [dst], along rows or columns,
        /// clamping at the edges. Internal for the JVM unit test.
        internal fun boxBlur(src: IntArray, dst: IntArray, width: Int, height: Int, radius: Int, horizontal: Boolean) {
            val lines = if (horizontal) height else width
            val length = if (horizontal) width else height
            val window = 2 * radius + 1
            for (line in 0 until lines) {
                fun at(i: Int): Int {
                    val clamped = i.coerceIn(0, length - 1)
                    return if (horizontal) line * width + clamped else clamped * width + line
                }
                var a = 0
                var r = 0
                var g = 0
                var b = 0
                for (i in -radius..radius) {
                    val p = src[at(i)]
                    a += p ushr 24
                    r += (p shr 16) and 0xFF
                    g += (p shr 8) and 0xFF
                    b += p and 0xFF
                }
                for (i in 0 until length) {
                    dst[at(i)] = ((a / window) shl 24) or ((r / window) shl 16) or ((g / window) shl 8) or (b / window)
                    val out = src[at(i - radius)]
                    val inn = src[at(i + radius + 1)]
                    a += (inn ushr 24) - (out ushr 24)
                    r += ((inn shr 16) and 0xFF) - ((out shr 16) and 0xFF)
                    g += ((inn shr 8) and 0xFF) - ((out shr 8) and 0xFF)
                    b += (inn and 0xFF) - (out and 0xFF)
                }
            }
        }
    }
}
