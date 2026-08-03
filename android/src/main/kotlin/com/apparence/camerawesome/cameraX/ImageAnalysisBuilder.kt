package com.apparence.camerawesome.cameraX

import android.annotation.SuppressLint
import android.graphics.Rect
import android.util.Size
import androidx.camera.core.AspectRatio
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.internal.utils.ImageUtil
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.*
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToLong

enum class OutputImageFormat {
    JPEG, YUV_420_888, NV21, RGBA_8888
}

class ImageAnalysisBuilder private constructor(
    private val format: OutputImageFormat,
    private val width: Int,
    private val height: Int,
    // Mutable so CameraXState can keep the analysis use case on the same aspect
    // ratio as preview/capture when the user switches ratios. If it drifts (e.g.
    // analysis stays 16:9 while the user picks 4:3), the shared UseCaseGroup
    // ViewPort intersects the two FOVs and crops the captured photo to the
    // analysis FOV — cutting the photo's top/bottom vs the preview (MIN-1991).
    var aspectRatio: Int,
    private val executor: Executor,
    var previewStreamSink: EventChannel.EventSink? = null,
    private val maxFramesPerSecond: Double?,
) {
    private var lastImageEmittedTimeStamp: Long? = null

    // Frames sent to Dart but not yet acked via receivedImageFromStream ->
    // lastFrameAnalysisFinished. Keeping un-acked frames from accumulating
    // bounds the platform channel's main-thread queue: without it, frames (each
    // a multi-MB map) pile up faster than Dart drains them and every other
    // platform call — including takePhoto — queues behind them (MIN-3577). The
    // predecessor of this gate was a one-shot latch that stopped gating after
    // the first frame. A counter rather than a boolean because acks carry no
    // frame id: after a stale-ack escape puts a second frame in flight, the
    // first frame's late ack must not reopen the gate while the second is
    // still outstanding.
    private val pendingAcks = AtomicInteger(0)

    @Volatile
    private var lastSentTimeStamp: Long = 0L

    fun lastFrameAnalysisFinished() {
        // Never below zero: an ack from a use case torn down by build() must
        // not pre-open the gate of the next binding.
        pendingAcks.updateAndGet { if (it > 0) it - 1 else 0 }
    }

    companion object {
        // If an ack never arrives (e.g. the Dart-side listener threw before
        // acking), resume sending after this long instead of wedging the stream.
        private const val STALE_ACK_TIMEOUT_MS = 2_000L

        fun configure(
            aspectRatio: Int,
            format: OutputImageFormat,
            executor: Executor,
            width: Long?,
            maxFramesPerSecond: Double?,
        ): ImageAnalysisBuilder {
            var widthOrDefault = 1024
            if (width != null && width > 0) {
                widthOrDefault = width.toInt()
            }
            val analysisAspectRatio = when (aspectRatio) {
                AspectRatio.RATIO_4_3 -> 4f / 3
                else -> 16f / 9
            }
            val height = widthOrDefault * (1 / analysisAspectRatio)
            val maxFps = if (maxFramesPerSecond == 0.0) null else maxFramesPerSecond
            return ImageAnalysisBuilder(
                format,
                widthOrDefault,
                height.toInt(),
                aspectRatio,
                executor,
                maxFramesPerSecond = maxFps,
            )
        }
    }

    @SuppressLint("RestrictedApi")
    fun build(): ImageAnalysis {
        val outputImageFormat = if (format == OutputImageFormat.RGBA_8888) ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888 else ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888
        pendingAcks.set(0)
        lastSentTimeStamp = 0L
        // Align analysis with preview on aspect ratio (MIN-1991: a ratio mismatch
        // makes the shared UseCaseGroup ViewPort crop captures to the analysis FOV)
        // *and* honour the caller's requested width. Expressing the ratio via
        // setTargetAspectRatio would leave resolution entirely to CameraX, which
        // defaults ImageAnalysis to 640x480 — far too coarse to decode a 1D
        // barcode (MIN-3302). The two APIs are mutually exclusive, so the ratio
        // moves into the selector's AspectRatioStrategy, matching how preview and
        // capture are configured in CameraXState.getResolutionSelector.
        val imageAnalysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(
                        when (aspectRatio) {
                            AspectRatio.RATIO_16_9 -> AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY
                            else -> AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
                        }
                    )
                    // Closest-higher-then-lower rather than an exact match: the
                    // requested width is a floor to aim for, and every device
                    // exposes a different set of analysis resolutions.
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(width, height),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                        )
                    )
                    .build()
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(outputImageFormat).build()
        imageAnalysis.setAnalyzer(Dispatchers.IO.asExecutor()) { imageProxy ->
            // `use` closes the ImageProxy as soon as this block returns — whether
            // the frame is dropped or copied. The previous scheme sent every frame
            // and applied the FPS cap by *delaying the close*, holding the camera's
            // buffer hostage so KEEP_ONLY_LATEST couldn't hand over fresh frames:
            // the preview pipeline itself stuttered under load (MIN-3577). Now
            // dropped frames cost nothing and the buffer is always returned
            // immediately.
            imageProxy.use {
                if (previewStreamSink == null) {
                    return@use
                }
                val now = System.currentTimeMillis()
                val minIntervalMs = maxFramesPerSecond?.let { (1000 / it).roundToLong() } ?: 0L
                val last = lastImageEmittedTimeStamp
                if (last != null && now - last < minIntervalMs) {
                    return@use
                }
                if (pendingAcks.get() > 0 && now - lastSentTimeStamp < STALE_ACK_TIMEOUT_MS) {
                    return@use
                }
                val imageMap = imageProxyBaseAdapter(imageProxy)
                when (format) {
                    OutputImageFormat.JPEG -> {
                        imageMap["jpegImage"] = ImageUtil.yuvImageToJpegByteArray(
                            imageProxy,
                            Rect(0, 0, imageProxy.width, imageProxy.height),
                            80,
                            imageProxy.imageInfo.rotationDegrees
                        )
                        imageMap["cropRect"] = cropRect(imageProxy)
                    }

                    OutputImageFormat.YUV_420_888 -> {
                        imageMap["planes"] = imagePlanesAdapter(imageProxy)
                        imageMap["cropRect"] = cropRect(imageProxy)
                    }

                    OutputImageFormat.NV21 -> {
                        imageMap["nv21Image"] = ImageUtil.yuv_420_888toNv21(imageProxy)
                        // Stride metadata only: NV21 consumers read
                        // planes.first.bytesPerRow, while the pixel data travels in
                        // nv21Image. Copying the three YUV planes alongside it
                        // roughly doubled the per-frame payload (MIN-3577).
                        imageMap["planes"] = imagePlanesMetadataAdapter(imageProxy)
                        imageMap["cropRect"] = cropRect(imageProxy)
                    }

                    OutputImageFormat.RGBA_8888 -> {
                        imageMap["planes"] = imagePlanesAdapter(imageProxy)
                    }
                }
                lastImageEmittedTimeStamp = now
                lastSentTimeStamp = now
                pendingAcks.incrementAndGet()
                executor.execute { previewStreamSink?.success(imageMap) }
            }
        }
        return imageAnalysis
    }

    private fun cropRect(imageProxy: ImageProxy): Map<String, Any> {
        return mapOf(
            "left" to imageProxy.cropRect.left,
            "top" to imageProxy.cropRect.top,
            "right" to imageProxy.cropRect.right,
            "bottom" to imageProxy.cropRect.bottom,
        )
    }

    @SuppressLint("RestrictedApi", "UnsafeOptInUsageError")
    private fun imageProxyBaseAdapter(imageProxy: ImageProxy): MutableMap<String, Any> {
        return mutableMapOf(
            // Use ImageProxy width/height which reflect the current targetRotation,
            // instead of the underlying Image's buffer dimensions.
            "height" to imageProxy.height,
            "width" to imageProxy.width,
            "format" to format.name.lowercase(),
            "rotation" to "rotation${imageProxy.imageInfo.rotationDegrees}deg",
        )
    }

    @SuppressLint("RestrictedApi", "UnsafeOptInUsageError")
    private fun imagePlanesMetadataAdapter(imageProxy: ImageProxy): List<Map<String, Any>> {
        return imageProxy.image!!.planes.map {
            mapOf(
                "bytes" to ByteArray(0), "rowStride" to it.rowStride, "pixelStride" to it.pixelStride
            )
        }
    }

    @SuppressLint("RestrictedApi", "UnsafeOptInUsageError")
    private fun imagePlanesAdapter(imageProxy: ImageProxy): List<Map<String, Any>> {
        return imageProxy.image!!.planes.map {
            val byteArray = ByteArray(it.buffer.remaining())
            it.buffer.get(byteArray, 0, byteArray.size)
            mapOf(
                "bytes" to byteArray, "rowStride" to it.rowStride, "pixelStride" to it.pixelStride
            )
        }
    }

}