package com.apparence.camerawesome.cameraX

import android.app.Activity
import android.view.OrientationEventListener
import android.view.Surface
import com.apparence.camerawesome.sensors.SensorOrientation

class OrientationStreamListener(
    activity: Activity,
    private var listeners: List<SensorOrientation>
) {
    var currentOrientation: Int = 0
    private var lastNotifiedOrientation: Int? = null
    val surfaceOrientation
        get() = when (currentOrientation) {
            in 225 until 315 -> {
                Surface.ROTATION_90
            }

            in 135 until 225 -> {
                Surface.ROTATION_180
            }

            in 45 until 135 -> {
                Surface.ROTATION_270
            }

            else -> {
                Surface.ROTATION_0
            }
        }

    private val orientationEventListener: OrientationEventListener

    init {
        orientationEventListener =
            object : OrientationEventListener(activity.applicationContext) {
                override fun onOrientationChanged(i: Int) {
                    if (i == ORIENTATION_UNKNOWN) {
                        return
                    }
                    var snapped = (i + 45) / 90 * 90
                    if (snapped == 360) snapped = 0
                    // The sensor fires continuously while the device moves, but
                    // snapping to 90° increments means almost every sample maps to
                    // the value we already published. Notifying regardless put ~75
                    // messages/second on the platform thread just from carrying the
                    // tablet around while scanning (MIN-3577).
                    //
                    // Compared against a nullable sentinel rather than
                    // currentOrientation, so the very first sample still publishes
                    // even when the device is already at 0°.
                    if (snapped == lastNotifiedOrientation) {
                        return
                    }
                    lastNotifiedOrientation = snapped
                    currentOrientation = snapped
                    for (listener in listeners) {
                        listener.onOrientationChanged(currentOrientation)
                    }
                }
            }
        orientationEventListener.enable()
    }

    fun stop() {
        orientationEventListener.disable()
    }
}