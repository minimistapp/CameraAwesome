package com.apparence.camerawesome.cameraX

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

        // Below a 24fps floor the exposure cap (1/24 = 42ms) is still long enough
        // to blur a moving hand-held frame, so pinning would trade image quality
        // (shorter exposure means more gain, and this sensor is already past its
        // analog gain limit) for no user-visible gain. Leave AE alone instead.
        //
        // Measured on the TB-X606F, 30s idle traces (see MIN-3577):
        //   (5,30) default : median 61.9ms  16.6fps  0 stalls >150ms
        //   (20,20)        : median 50.7ms  19.8fps  1 stall
        //   (30,30)        : median 34.8ms  23.1fps  28 stalls
        // (30,30) wins on exposure -- 50ms -> 30ms, which is the motion blur users
        // were retaking photos for -- but overruns this tablet's *display* path:
        // SurfaceFlinger GPU-composites the preview in ~36ms, so it can only drain
        // ~28fps, and the surplus exhausts the BufferQueue about once a second
        // (the HAL then blocks in dequeueBuffer for ~260ms). That ceiling is a
        // composition bug, not an AE one, and is tracked separately. If it turns
        // out the hitch bothers users more than the blur did, dropping both
        // constants to 20 selects (20,20), which measured stall-free.
        private const val MIN_USEFUL_FPS_FLOOR = 24

        /**
         * The best AE target FPS range this camera actually advertises, or null
         * to leave the HAL default alone.
         *
         * Highest lower bound wins, because the lower bound is what caps exposure;
         * the upper bound only breaks ties. Ranges above [PREFERRED_MAX_FPS] are
         * ignored: the stream configuration backing preview + analysis cannot
         * sustain a high-speed range, and requesting one risks a rejected session.
         */
        @androidx.annotation.OptIn(ExperimentalCamera2Interop::class)
        fun pickAeTargetFpsRange(
            cameraSelector: CameraSelector,
            cameraProvider: ProcessCameraProvider
        ): Range<Int>? {
            val available = cameraSelector.filter(cameraProvider.availableCameraInfos)
                .firstOrNull()
                ?.let { Camera2CameraInfo.from(it) }
                ?.getCameraCharacteristic(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                ) ?: return null

            return available
                .filter { it.upper <= PREFERRED_MAX_FPS && it.lower >= MIN_USEFUL_FPS_FLOOR }
                .maxWithOrNull(compareBy({ it.lower }, { it.upper }))
                .also {
                    Log.i(
                        CamerawesomePlugin.TAG,
                        "AE target FPS range: picked $it from ${available.joinToString()}"
                    )
                }
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