package com.apparence.camerawesome.cameraX

import android.app.ActivityManager
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.util.Log
import android.util.Range
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExtendableBuilder
import androidx.camera.lifecycle.ProcessCameraProvider
import com.apparence.camerawesome.CamerawesomePlugin

class CameraCapabilities {
    companion object {
        // Auto-exposure is otherwise free to buy brightness with frame time. On
        // the Lenovo TB-X606F (MIN-3577) the default range is (5,30), and in shop
        // lighting AE settles on a 50-60ms exposure -- 16-20fps. Because the
        // sensor cannot begin a frame before the previous exposure ends, that
        // single choice is *both* the juddery preview and the motion blur users
        // were retaking photos for. Pinning a range caps exposure at 1/lower.
        //
        // Measured on the TB-X606F, which advertises exactly:
        //   (10,10) (15,15) (15,20) (20,20) (5,30) (30,30)
        // Note there is no (24,30) or (15,30) here -- ranges the HAL does not
        // advertise are rejected or silently ignored, so the supported set must
        // be read from the device rather than assumed.
        private const val PREFERRED_MAX_FPS = 30

        // Low-end devices are held to 20fps. Measured on the TB-X606F, 30s idle
        // traces (see MIN-3577):
        //   (5,30) default : median 61.9ms  16.6fps   0 stalls>150ms  4.0 analysis frames/s
        //   (20,20)        : median 50.7ms  19.8fps   1 stall         3.1 analysis frames/s
        //   (30,30)        : median 33.8ms  22.3fps  32 stalls        1.1 analysis frames/s
        // (30,30) wins on exposure (50ms -> 30ms, the motion blur users were
        // retaking photos for) but overruns this tablet's *display* path, and the
        // resulting ~260ms dequeueBuffer stalls also starve the analysis stream
        // ~4x -- which is what April-tag/barcode detection reads, and the very
        // thing the preceding fix protected. 20fps sits under the ceiling and
        // keeps both, at a smaller exposure win.
        private const val LOW_END_MAX_FPS = 20

        // 4GB, matching the TB-X606F. Deliberately generous: the phones this
        // would wrongly catch still composite 20fps preview fine, whereas a
        // tablet wrongly let through hitches once a second.
        private const val LOW_END_MAX_RAM_BYTES = 4L * 1024 * 1024 * 1024

        // Below a 20fps floor the exposure cap (1/15 = 67ms) is no tighter than
        // what AE was already choosing unpinned, so pinning would trade image
        // quality (shorter exposure means more gain, and this sensor is already
        // past its analog gain limit) for nothing. Leave AE alone instead --
        // which is what a device advertising only (10,10) and (15,15) gets.
        private const val MIN_USEFUL_FPS_FLOOR = 20

        /**
         * The best AE target FPS range this camera actually advertises, or null
         * to leave the HAL default alone.
         *
         * Highest lower bound wins, because the lower bound is what caps exposure;
         * the upper bound only breaks ties. Ranges above the ceiling are ignored:
         * a high-speed range is not something the stream configuration backing
         * preview + analysis can sustain, and requesting one risks a rejected
         * session. The ceiling is [LOW_END_MAX_FPS] on devices [isLowEndDevice]
         * flags, [PREFERRED_MAX_FPS] otherwise.
         */
        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        fun pickAeTargetFpsRange(
            cameraSelector: CameraSelector,
            cameraProvider: ProcessCameraProvider,
            context: Context?,
        ): Range<Int>? {
            val available = cameraSelector.filter(cameraProvider.availableCameraInfos)
                .firstOrNull()
                ?.let { Camera2CameraInfo.from(it) }
                ?.getCameraCharacteristic(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                ) ?: return null

            val ceiling = if (isLowEndDevice(context)) LOW_END_MAX_FPS else PREFERRED_MAX_FPS
            return available
                .filter { it.upper <= ceiling && it.lower >= MIN_USEFUL_FPS_FLOOR }
                .maxWithOrNull(compareBy({ it.lower }, { it.upper }))
                .also {
                    Log.i(
                        CamerawesomePlugin.TAG,
                        "AE target FPS range: picked $it (ceiling ${ceiling}fps) " +
                            "from ${available.joinToString()}"
                    )
                }
        }

        /**
         * Whether to hold this device to [LOW_END_MAX_FPS].
         *
         * Total RAM is a proxy, and an imperfect one — what actually matters is
         * how fast the device can composite the preview, which no API reports.
         * It is used because the failure it stands in for is a low-end-device
         * failure: on the 4GB TB-X606F, SurfaceFlinger GPU-composites the preview
         * in ~36ms (a ~28fps ceiling), so a 30fps sensor overruns the BufferQueue
         * and the HAL blocks in dequeueBuffer ~once a second. Conservative by
         * design: an unknown context leaves the device on the fast path.
         */
        private fun isLowEndDevice(context: Context?): Boolean {
            val am = context?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return false
            if (am.isLowRamDevice) return true
            val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            return info.totalMem in 1..LOW_END_MAX_RAM_BYTES
        }

        /**
         * Pin [range] on a use case builder. No-op when [range] is null so callers
         * don't have to branch.
         */
        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        fun <T> applyAeTargetFpsRange(builder: ExtendableBuilder<T>, range: Range<Int>?) {
            if (range == null) return
            Camera2Interop.Extender(builder)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
        }

        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        fun getCameraLevel(
            cameraSelector: CameraSelector,
            cameraProvider: ProcessCameraProvider
        ): Int {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                return cameraSelector.filter(cameraProvider.availableCameraInfos).firstOrNull()
                    ?.let { Camera2CameraInfo.from(it) }
                    ?.getCameraCharacteristic(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
                    ?: CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED
            }
            return CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY
        }
    }
}