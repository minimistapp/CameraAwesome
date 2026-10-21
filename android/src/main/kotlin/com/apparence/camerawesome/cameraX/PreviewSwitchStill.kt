package com.apparence.camerawesome.cameraX

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.camera.view.PreviewView
import androidx.lifecycle.Observer
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max
import kotlin.math.roundToInt

/// The photo/video switch (MIN-4185), done like the system camera: the app
/// covers the preview with a blurred still of its last frame ([capture]), runs
/// the switch under it, and reveals once the new stream is on screen
/// ([settled]). The app draws the still, so it can grow or shrink with the
/// preview box.
///
/// Main thread only.
internal class PreviewSwitchStill(private val previewView: () -> PreviewView?) {
    private val handler = Handler(Looper.getMainLooper())
    private val answerNow = Runnable { answer() }

    private var watched: PreviewView? = null
    private var pending: MethodChannel.Result? = null

    /// The switch first drops the stream to IDLE; only a STREAMING that follows
    /// it is the new stream. (LiveData also replays the current STREAMING the
    /// moment we subscribe, which must not count.)
    private var sawStreamStop = false

    private val streamObserver = Observer<PreviewView.StreamState> { state ->
        when (state) {
            PreviewView.StreamState.IDLE -> {
                sawStreamStop = true
                // A second rebind (the ratio rides along with the mode) restarts the wait.
                if (pending != null) armTimeoutOnly()
            }
            PreviewView.StreamState.STREAMING -> if (sawStreamStop && pending != null) answerAfterStable()
        }
    }

    /// A [width]-px-wide blurred copy of what the preview shows, as RGBA
    /// ({width, height, pixels}), or null when nothing is displayed. Starts
    /// watching the stream for [settled].
    fun capture(width: Int): Map<String, Any>? {
        val view = previewView() ?: return null
        watch(view)
        val frame = view.bitmap ?: return null
        val scaledHeight = max(1, (frame.height * width.toFloat() / frame.width).roundToInt())
        val small = Bitmap.createScaledBitmap(frame, max(1, width), scaledHeight, true)
        if (small !== frame) frame.recycle()
        val w = small.width
        val h = small.height
        val pixels = IntArray(w * h)
        small.getPixels(pixels, 0, w, 0, 0, w, h)
        small.recycle()
        val scratch = IntArray(pixels.size)
        val radius = max(2, w / 40)
        repeat(BLUR_PASSES) {
            PreviewFreezeFrame.boxBlur(pixels, scratch, w, h, radius, horizontal = true)
            PreviewFreezeFrame.boxBlur(scratch, pixels, w, h, radius, horizontal = false)
        }
        val rgba = ByteArray(pixels.size * 4)
        for (i in pixels.indices) {
            val p = pixels[i]
            rgba[i * 4] = (p shr 16).toByte()
            rgba[i * 4 + 1] = (p shr 8).toByte()
            rgba[i * 4 + 2] = p.toByte()
            rgba[i * 4 + 3] = 0xFF.toByte()
        }
        return mapOf("width" to w, "height" to h, "pixels" to rgba)
    }

    /// Answers [result] once the stream that followed the switch has been on
    /// screen for a moment — or after [MAX_WAIT_MS] regardless.
    fun settled(result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        val view = watched
        if (view == null) {
            answer()
            return
        }
        if (sawStreamStop && view.previewStreamState.value == PreviewView.StreamState.STREAMING) {
            answerAfterStable()
        } else {
            armTimeoutOnly()
        }
    }

    fun dispose() {
        handler.removeCallbacks(answerNow)
        pending?.success(null)
        pending = null
        unwatch()
    }

    private fun answerAfterStable() {
        handler.removeCallbacks(answerNow)
        handler.postDelayed(answerNow, STABLE_MS)
    }

    private fun armTimeoutOnly() {
        handler.removeCallbacks(answerNow)
        handler.postDelayed(answerNow, MAX_WAIT_MS)
    }

    private fun answer() {
        handler.removeCallbacks(answerNow)
        pending?.success(null)
        pending = null
        unwatch()
    }

    private fun watch(view: PreviewView) {
        unwatch()
        sawStreamStop = false
        watched = view
        view.previewStreamState.observeForever(streamObserver)
    }

    private fun unwatch() {
        watched?.previewStreamState?.removeObserver(streamObserver)
        watched = null
    }

    companion object {
        private const val BLUR_PASSES = 3

        /// The new stream's first frames can still be the old shape for a beat.
        private const val STABLE_MS = 120L

        /// A rebind normally takes 300-700 ms; never hold the still longer.
        private const val MAX_WAIT_MS = 1500L
    }
}
