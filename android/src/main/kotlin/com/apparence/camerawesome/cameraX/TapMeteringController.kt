package com.apparence.camerawesome.cameraX

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.MeteringRectangle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Rational
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.MeteringPoint
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.apparence.camerawesome.CamerawesomePlugin
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Tap-to-focus that behaves like the system camera app (MIN-6738).
 *
 * CameraX's `startFocusAndMetering` alone can't do this. A successful AF action
 * switches the lens to `AF_MODE_AUTO` and *locks* it until the action is
 * cancelled, and cancelling (or the auto-cancel timer) also drops the metering
 * regions. The old tap either held a hard lock or, after the 5 s auto-cancel,
 * snapped focus and exposure back to the whole frame. That was the "jumpy"
 * camera in the report. Samsung's and Apple's cameras do neither: a tap
 * focuses at the point, then keeps refining focus and exposure *at that point*
 * until the scene changes.
 *
 * So a tap here does two things:
 *  1. Sets Camera2 `CONTROL_AF_REGIONS` / `CONTROL_AE_REGIONS` at the point via
 *     [Camera2CameraControl]. Interop options override CameraX's own values, so
 *     the regions outlive CameraX's focus action. White balance is left alone:
 *     metering AWB on a small patch shifted every colour on each tap.
 *  2. Runs one CameraX AF action at the point (an immediate, active scan, the
 *     way the system camera responds to a tap), then cancels it once it
 *     settles. That puts CameraX back on `CONTINUOUS_PICTURE`, which now keeps
 *     focusing inside the tapped region.
 *
 * The point is released, back to full-frame auto, when the phone turns past
 * [RELEASE_ROTATION_DEGREES] (the Android stand-in for iOS's subject-area-change
 * notification), on the next tap, on a rebind and when the camera stops or the
 * activity pauses.
 *
 * Long-press ([focusAt] with `lock = true`) is the native AE/AF lock: the AF
 * action is kept (focus stays locked) and `CONTROL_AE_LOCK` pins exposure, with
 * no release on movement. Only the next tap, a rebind or the camera stopping
 * clears it.
 *
 * Main thread only.
 */
@androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
class TapMeteringController(
    context: Context,
    val lifecycleOwner: LifecycleOwner,
    private val mainExecutor: Executor,
    /// A point or lock was dropped without a new tap, with the reason. The
    /// app hides its focus square and lock label then.
    private val onReleased: (String) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val motion = MotionReleaseWatcher(context.applicationContext) { onDeviceMoved() }
    private val lifecycleObserver = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_PAUSE) reset("activity paused")
    }
    private var observingLifecycle = false

    private var camera: Camera? = null
    private var point: MeteringPoint? = null
    private var fallbackAspect: Rational? = null
    private var locked = false

    /// Bumped by every tap and every reset, so a callback from an older
    /// action never touches state that a newer one owns.
    private var generation = 0
    private var holdTimeout: Runnable? = null

    /**
     * Focuses and meters at [point] (a CameraX point, already in the camera's
     * surface coordinates).
     *
     * @param fallbackAspect the preview surface's aspect ratio, sensor-oriented,
     *   used when [point] doesn't carry one.
     * @param lock long-press AE/AF lock instead of continuous focus at the point.
     * @param holdMillis > 0: release back to full-frame auto after this long
     *   (minimum 1 s). <= 0: hold until a release condition above.
     */
    fun focusAt(
        camera: Camera,
        point: MeteringPoint,
        fallbackAspect: Rational?,
        lock: Boolean,
        holdMillis: Long,
    ) {
        val gen = ++generation
        cancelHoldTimeout()
        motion.stop()
        val previous = this.camera
        if (previous != null && previous !== camera) {
            clearInterop(previous, "camera changed")
        }
        this.camera = camera
        this.point = point
        this.fallbackAspect = fallbackAspect
        this.locked = lock
        observeLifecycle()

        val regions = meteringRegions(camera, point, fallbackAspect)
        if (regions == null) {
            Log.w(
                CamerawesomePlugin.TAG,
                "Tap-to-focus skipped: the camera reports no active array size (point=${point.x},${point.y})",
            )
            reset("no active array")
            return
        }
        applyInterop(camera, regions, aeLock = false)

        if (regions.af == null) {
            // Fixed-focus lens: there is nothing to scan, only exposure to meter.
            Log.d(CamerawesomePlugin.TAG, "Tap-to-focus: no AF regions on this camera, metering exposure only")
            if (lock) {
                handler.postDelayed({
                    if (gen == generation) applyInterop(camera, regions, aeLock = true)
                }, AE_SETTLE_MS)
            } else {
                startHolding(gen, holdMillis)
            }
            return
        }

        val control = camera.cameraControl
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF)
            .disableAutoCancel()
            .build()
        val scan = control.startFocusAndMetering(action)
        scan.addListener({
            if (gen != generation) {
                Log.d(CamerawesomePlugin.TAG, "Tap-to-focus scan finished after a newer tap or reset; ignored")
                return@addListener
            }
            runCatching { scan.get() }.onFailure { e ->
                Log.w(CamerawesomePlugin.TAG, "Tap-to-focus scan didn't complete (lock=$lock): ${e.message}")
            }
            if (lock) {
                // Focus stays locked by the (never cancelled) action; pin
                // exposure too now that it has metered the point.
                applyInterop(camera, regions, aeLock = true)
            } else {
                // Back to CONTINUOUS_PICTURE. The interop regions keep it
                // aimed at the tapped point.
                logFailure(control.cancelFocusAndMetering(), "resume continuous AF after the tap scan")
                startHolding(gen, holdMillis)
            }
        }, mainExecutor)
    }

    /// Back to full-frame continuous AF/AE. Safe to call when nothing is active.
    fun reset(reason: String) {
        generation++
        cancelHoldTimeout()
        motion.stop()
        stopObservingLifecycle()
        val cam = camera ?: return
        val wasActive = point != null
        if (wasActive) {
            Log.d(CamerawesomePlugin.TAG, "Tap-to-focus point released: $reason")
        }
        camera = null
        point = null
        locked = false
        clearInterop(cam, reason)
        logFailure(cam.cameraControl.cancelFocusAndMetering(), "cancel tap focus ($reason)")
        if (wasActive) onReleased(reason)
    }

    /**
     * Zoom changed. With `CONTROL_ZOOM_RATIO` the regions are post-zoom and stay
     * valid. Only the older crop-region zoom needs them recomputed.
     */
    fun onZoomChanged() {
        val cam = camera ?: return
        val p = point ?: return
        val info = Camera2CameraInfo.from(cam.cameraInfo)
        if (usesZoomRatio(info)) return
        val regions = meteringRegions(cam, p, fallbackAspect)
        if (regions == null) {
            Log.w(CamerawesomePlugin.TAG, "Tap-to-focus regions not recomputed after zoom: no active array size")
            return
        }
        applyInterop(cam, regions, aeLock = locked)
    }

    private fun startHolding(gen: Int, holdMillis: Long) {
        motion.start()
        if (holdMillis > 0) {
            val timeout = Runnable { if (gen == generation) reset("hold of ${holdMillis}ms elapsed") }
            holdTimeout = timeout
            handler.postDelayed(timeout, max(holdMillis, MIN_HOLD_MS))
        }
    }

    private fun onDeviceMoved() {
        if (point == null || locked) return
        reset("device turned more than $RELEASE_ROTATION_DEGREES°")
    }

    private fun cancelHoldTimeout() {
        holdTimeout?.let { handler.removeCallbacks(it) }
        holdTimeout = null
    }

    private fun observeLifecycle() {
        if (observingLifecycle) return
        lifecycleOwner.lifecycle.addObserver(lifecycleObserver)
        observingLifecycle = true
    }

    private fun stopObservingLifecycle() {
        if (!observingLifecycle) return
        lifecycleOwner.lifecycle.removeObserver(lifecycleObserver)
        observingLifecycle = false
    }

    private fun applyInterop(camera: Camera, regions: Regions, aeLock: Boolean) {
        val options = CaptureRequestOptions.Builder().apply {
            regions.af?.let { setCaptureRequestOption(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(it)) }
            regions.ae?.let { setCaptureRequestOption(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(it)) }
            if (aeLock) {
                if (regions.aeLockAvailable) {
                    setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, true)
                } else {
                    Log.w(CamerawesomePlugin.TAG, "AE/AF lock: this camera can't lock exposure, only focus is locked")
                }
            }
        }.build()
        logFailure(
            Camera2CameraControl.from(camera.cameraControl).setCaptureRequestOptions(options),
            "set tap metering regions (aeLock=$aeLock)",
        )
    }

    private fun clearInterop(camera: Camera, reason: String) {
        logFailure(
            Camera2CameraControl.from(camera.cameraControl).clearCaptureRequestOptions(),
            "clear tap metering regions ($reason)",
        )
    }

    /// Camera-control futures fail when the camera is inactive or a newer
    /// request supersedes them. Both are expected, but log them: a regions
    /// call that silently didn't land is exactly the bug this class fixes.
    private fun logFailure(future: ListenableFuture<*>, what: String) {
        future.addListener({
            runCatching { future.get() }.onFailure { e ->
                Log.d(CamerawesomePlugin.TAG, "Couldn't $what: ${e.message}")
            }
        }, mainExecutor)
    }

    private class Regions(
        val af: MeteringRectangle?,
        val ae: MeteringRectangle?,
        val aeLockAvailable: Boolean,
    )

    @SuppressLint("RestrictedApi")
    private fun meteringRegions(camera: Camera, point: MeteringPoint, fallbackAspect: Rational?): Regions? {
        val info = Camera2CameraInfo.from(camera.cameraInfo)
        val activeArray = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            ?: return null
        val zoomRatio = if (usesZoomRatio(info)) 1f else camera.cameraInfo.zoomState.value?.zoomRatio ?: 1f
        val crop = TapMeteringMath.cropRegion(activeArray.width(), activeArray.height(), zoomRatio)
        // MeteringPoint.getSurfaceAspectRatio is library-restricted, but it is
        // the very value CameraX's own FocusMeteringControl reads for this.
        val aspect = point.surfaceAspectRatio ?: fallbackAspect
        val r = TapMeteringMath.meteringRect(
            point.x, point.y, point.size,
            aspect?.toDouble() ?: (crop.width.toDouble() / crop.height),
            crop,
        )
        val rect = MeteringRectangle(Rect(r.left, r.top, r.right, r.bottom), MeteringRectangle.METERING_WEIGHT_MAX)

        val maxAf = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0
        val afModes = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        val canFocus = maxAf > 0 && afModes.contains(CameraMetadata.CONTROL_AF_MODE_AUTO)
        val maxAe = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0
        val aeLockAvailable = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
        return Regions(
            af = if (canFocus) rect else null,
            ae = if (maxAe > 0) rect else null,
            aeLockAvailable = aeLockAvailable,
        )
    }

    /// Mirrors CameraX's ZoomControl choice: Android R zoom (CONTROL_ZOOM_RATIO)
    /// whenever the camera reports a zoom-ratio range, crop-region zoom otherwise.
    private fun usesZoomRatio(info: Camera2CameraInfo): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            info.getCameraCharacteristic(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) != null

    companion object {
        /// The phone turning this far from where it was at the tap means the
        /// user has moved on to something else.
        const val RELEASE_ROTATION_DEGREES = 15f

        /// Metering spot as a fraction of the frame. CameraX's default is 0.15.
        /// A smaller spot lets a small, bright item on a dark cloth (jewellery)
        /// dominate exposure instead of the background around it.
        const val TAP_POINT_SIZE = 0.1f

        private const val MIN_HOLD_MS = 1000L
        private const val AE_SETTLE_MS = 500L
    }
}

/// Pure geometry for [TapMeteringController], kept free of Android types so it
/// can be unit-tested on the JVM.
object TapMeteringMath {
    data class IntRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width get() = right - left
        val height get() = bottom - top
    }

    /**
     * A normalised point in the *displayed* (upright) preview to the same point
     * in the camera surface, which is sensor-oriented. [rotationDegrees] is the
     * clockwise rotation from surface to display (`ResolutionInfo.rotationDegrees`).
     */
    fun displayToSurface(u: Float, v: Float, rotationDegrees: Int): Pair<Float, Float> =
        when (((rotationDegrees % 360) + 360) % 360) {
            90 -> v to 1f - u
            180 -> 1f - u to 1f - v
            270 -> 1f - v to u
            else -> u to v
        }

    /**
     * The sensor region 3A coordinates refer to: the whole active array, or with
     * crop-region zoom the centred crop at [zoomRatio] (as CameraX's
     * CropRegionZoomImpl computes it). Origin is the active array's top-left.
     */
    fun cropRegion(activeWidth: Int, activeHeight: Int, zoomRatio: Float): IntRect {
        if (zoomRatio <= 1f) return IntRect(0, 0, activeWidth, activeHeight)
        val w = activeWidth / zoomRatio
        val h = activeHeight / zoomRatio
        val left = ((activeWidth - w) / 2f).toInt()
        val top = ((activeHeight - h) / 2f).toInt()
        return IntRect(left, top, (left + w).toInt(), (top + h).toInt())
    }

    /**
     * A normalised surface point to its metering rectangle in [crop], the same
     * way CameraX's FocusMeteringControl does it: when the surface's aspect
     * ratio differs from the crop's, the surface only covers the centre of the
     * crop, so the point is moved into that part first.
     */
    fun meteringRect(
        x: Float,
        y: Float,
        size: Float,
        surfaceAspect: Double,
        crop: IntRect,
    ): IntRect {
        val cropAspect = crop.width.toDouble() / crop.height
        var ax = x
        var ay = y
        if (abs(surfaceAspect - cropAspect) > 1e-3) {
            if (surfaceAspect > cropAspect) {
                // Wider surface: it spans the crop's width, not all of its height.
                val heightOfFov = (surfaceAspect / cropAspect).toFloat()
                ay = ((heightOfFov - 1f) / 2f + y) / heightOfFov
            } else {
                val widthOfFov = (cropAspect / surfaceAspect).toFloat()
                ax = ((widthOfFov - 1f) / 2f + x) / widthOfFov
            }
        }
        val cx = crop.left + ax.coerceIn(0f, 1f) * crop.width
        val cy = crop.top + ay.coerceIn(0f, 1f) * crop.height
        val halfW = max(1f, size * crop.width / 2f)
        val halfH = max(1f, size * crop.height / 2f)
        val left = (cx - halfW).roundToInt().coerceIn(crop.left, crop.right - 1)
        val top = (cy - halfH).roundToInt().coerceIn(crop.top, crop.bottom - 1)
        val right = (cx + halfW).roundToInt().coerceIn(left + 1, crop.right)
        val bottom = (cy + halfH).roundToInt().coerceIn(top + 1, crop.bottom)
        return IntRect(left, top, right, bottom)
    }

    /// Angle in degrees between two orientations given as unit quaternions
    /// (`SensorManager.getQuaternionFromVector` order: w, x, y, z).
    fun rotationDegreesBetween(a: FloatArray, b: FloatArray): Float {
        val dot = abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
        return Math.toDegrees(2.0 * acos(min(1f, dot).toDouble())).toFloat()
    }
}

/// Reports when the phone has turned more than
/// [TapMeteringController.RELEASE_ROTATION_DEGREES] since [start].
private class MotionReleaseWatcher(
    context: Context,
    private val onMoved: () -> Unit,
) : SensorEventListener {
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    /// Game rotation vector: gyro + accelerometer, no magnetometer, so a nearby
    /// metal shelf can't make it drift.
    private val sensor: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private var running = false
    private var baseline: FloatArray? = null
    private val current = FloatArray(4)

    fun start() {
        baseline = null
        if (running) return
        val sm = sensorManager
        val s = sensor
        if (sm == null || s == null) {
            Log.d(CamerawesomePlugin.TAG, "No rotation-vector sensor: a tap point is held until the next tap")
            return
        }
        running = sm.registerListener(this, s, SensorManager.SENSOR_DELAY_UI)
        if (!running) {
            Log.w(CamerawesomePlugin.TAG, "Rotation-vector listener refused: a tap point is held until the next tap")
        }
    }

    fun stop() {
        if (running) sensorManager?.unregisterListener(this)
        running = false
        baseline = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        SensorManager.getQuaternionFromVector(current, event.values)
        val base = baseline
        if (base == null) {
            baseline = current.copyOf()
            return
        }
        if (TapMeteringMath.rotationDegreesBetween(base, current) > TapMeteringController.RELEASE_ROTATION_DEGREES) {
            onMoved()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
