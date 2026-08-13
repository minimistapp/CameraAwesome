package com.apparence.camerawesome.cameraX

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.*
import android.hardware.camera2.CameraCharacteristics
import android.hardware.display.DisplayManager
import android.location.Location
import android.os.*
import android.util.Log
import android.util.Rational
import android.util.Size
import android.view.Surface
import androidx.camera.camera2.Camera2Config
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.util.Consumer
import androidx.exifinterface.media.ExifInterface
import com.apparence.camerawesome.*
import com.apparence.camerawesome.buttons.PhysicalButtonMessageHandler
import com.apparence.camerawesome.buttons.PhysicalButtonsHandler
import com.apparence.camerawesome.buttons.PlayerService
import com.apparence.camerawesome.models.FlashMode
import com.apparence.camerawesome.sensors.SensorOrientationListener
import com.apparence.camerawesome.utils.isMultiCamSupported
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import io.reactivex.rxjava3.disposables.Disposable
import io.reactivex.rxjava3.subjects.BehaviorSubject
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.math.roundToInt


enum class CaptureModes {
    PHOTO, VIDEO, PREVIEW, ANALYSIS_ONLY,
}

class CameraAwesomeX : CameraInterface, FlutterPlugin, ActivityAware, PreviewViewProvider {
    private lateinit var physicalButtonHandler: PhysicalButtonsHandler
    private var binding: FlutterPluginBinding? = null
    private var textureRegistry: TextureRegistry? = null
    private var activity: Activity? = null
    private lateinit var imageStreamChannel: EventChannel
    private lateinit var orientationStreamChannel: EventChannel
    private var orientationStreamListener: OrientationStreamListener? = null

    // Rebinds the camera when the window's display rotation changes so the preview
    // crop tracks the orientation on tablets (no-op on portrait-locked phones —
    // refreshDisplayRotation only rebinds when the window rotation actually
    // changes). (MIN-2437)
    private var displayManager: DisplayManager? = null
    private var displayListener: DisplayManager.DisplayListener? = null

    // One-shot: rebind the camera the first time the native PreviewView attaches
    // to the window, so the preview leaves the bind-time (display-less, portrait)
    // rotation and fills the screen upright. Set only on tablets (phones are
    // portrait-locked and already correct, so a startup rebind would just
    // flicker). (MIN-2437)
    private var rebindOnFirstAttach = false
    private val sensorOrientationListener: SensorOrientationListener = SensorOrientationListener()

    /// When set, the EXIF Orientation of captured photos is forced to this
    /// `Surface.ROTATION_*` value instead of the sensor-driven one read from
    /// [OrientationStreamListener]. Set via [setCaptureOrientationOverride]
    /// from Dart; null means "use the sensor."
    private var captureOrientationOverride: Int? = null

    private lateinit var cameraState: CameraXState
    private val cameraPermissions = CameraPermissions()
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var exifPreferences = ExifPreferences(false)
    private var cancellationTokenSource = CancellationTokenSource()
    private var lastRecordedVideos: List<BehaviorSubject<Boolean>>? = null
    private var lastRecordedVideoSubscriptions: MutableList<Disposable>? = null
    private var colorMatrix: List<Double>? = null

    // MIN-3655: whether the active colour matrix is baked into captured
    // photos. False makes the filter preview-only — the bake is a
    // full-resolution decode + re-encode on the main executor that delays the
    // capture callback, and the caller applies the matrix elsewhere (server
    // side, for Minimist). Defaults to true, the historical behaviour.
    private var bakeCaptures: Boolean = true

    private val noneFilter: List<Double> = listOf(
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0
    )

    @SuppressLint("UnsafeOptInUsageError")
    fun configureCameraXLogs() {
        try {
            ProcessCameraProvider.configureInstance(
                CameraXConfig.Builder.fromConfig(Camera2Config.defaultConfig())
                    .setMinimumLoggingLevel(Log.ERROR).build()
            )
        } catch (e: IllegalStateException) {
            // Ignore if trying to configure CameraX more than once
        }
    }

    private fun getCameraProvider(): ProcessCameraProvider {
        configureCameraXLogs()
        val future = ProcessCameraProvider.getInstance(
            activity!!
        )
        return future.get()
    }


    @SuppressLint("RestrictedApi")
    override fun setupCamera(
        sensors: List<PigeonSensor>,
        aspectRatio: String,
        zoom: Double,
        mirrorFrontCamera: Boolean,
        enablePhysicalButton: Boolean,
        flashMode: String,
        captureMode: String,
        enableImageStream: Boolean,
        exifPreferences: ExifPreferences,
        videoOptions: VideoOptions?,
        callback: (Result<Boolean>) -> Unit
    ) {
        if (enablePhysicalButton) {
            val serviceIntent = Intent(activity!!, PlayerService::class.java)
            serviceIntent.putExtra(
                PhysicalButtonsHandler.BROADCAST_VOLUME_BUTTONS,
                Messenger(PhysicalButtonMessageHandler(physicalButtonHandler))
            )
            activity!!.startService(serviceIntent)
        } else {
            activity!!.stopService(Intent(activity!!, PlayerService::class.java))
        }

        val cameraProvider = getCameraProvider()

        val mode = CaptureModes.valueOf(captureMode)
        cameraState = CameraXState(cameraProvider = cameraProvider,
            textureEntries = sensors.mapIndexed { index: Int, pigeonSensor: PigeonSensor ->
                (pigeonSensor.deviceId
                    ?: index.toString()) to textureRegistry!!.createSurfaceTexture()
            }.toMap(),
            sensors = sensors,
            mirrorFrontCamera = mirrorFrontCamera,
            currentCaptureMode = mode,
            enableImageStream = enableImageStream,
            videoOptions = videoOptions?.android,
            videoRecordingQuality = videoOptions?.quality,
            onStreamReady = { state -> state.updateLifecycle(activity!!) }).apply {
            this.updateAspectRatio(aspectRatio)
            this.flashMode = FlashMode.valueOf(flashMode)
            this.enableAudioRecording = videoOptions?.enableAudio ?: true
        }
        // MIN-2406 (Android parity with iOS): render the single-sensor preview
        // through a native CameraX PreviewView — OS-composited and decoupled
        // from Flutter's compositor — hosted by the `camerawesome/preview`
        // platform view. Created on the main thread before updateLifecycle so
        // the Preview use case can bind to its surfaceProvider. Multi-sensor and
        // ANALYSIS_ONLY keep the Flutter Texture path.
        //
        // PERFORMANCE uses a SurfaceView (dedicated hardware-composer overlay);
        // a plain AndroidView promotes to Hybrid Composition automatically. If
        // the Flutter overlays drawn on top flicker/jank under HC, switching to
        // COMPATIBLE (TextureView) is the documented one-line fallback.
        if (mode != CaptureModes.ANALYSIS_ONLY && sensors.size <= 1) {
            // buildPreviewView honours any active colour filter (MIN-3655);
            // a fresh CameraXState starts unfiltered and Dart re-asserts the
            // filter on start, which recreates the view if needed.
            cameraState.previewView = cameraState.buildPreviewView(activity!!)
            // Tablets render the preview full-screen following the window; rebind
            // once the PreviewView attaches so it isn't stuck at the bind-time
            // portrait rotation. Phones stay portrait-locked, so skip. (MIN-2437)
            rebindOnFirstAttach = activity!!.resources.configuration.smallestScreenWidthDp >= 600
        }
        this.exifPreferences = exifPreferences
        orientationStreamListener =
            OrientationStreamListener(activity!!, listOf(sensorOrientationListener, cameraState))
        registerDisplayListener()
        imageStreamChannel.setStreamHandler(cameraState)
        if (mode != CaptureModes.ANALYSIS_ONLY) {
            cameraState.updateLifecycle(activity!!)
            // Zoom should be set after updateLifeCycle
            if (zoom > 0) {
                // TODO Find a better way to set initial zoom than using a postDelayed
                Handler(Looper.getMainLooper()).postDelayed({
                    (cameraState.concurrentCamera?.cameras?.firstOrNull()
                        ?: cameraState.previewCamera)?.cameraControl?.setLinearZoom(zoom.toFloat())
                }, 200)
            }
        }

        callback(Result.success(true))
    }

    override fun checkPermissions(permissions: List<String>): List<String> {
        throw Exception("Not implemented on Android")
    }

    override fun setupImageAnalysisStream(
        format: String, width: Long, maxFramesPerSecond: Double?, autoStart: Boolean
    ) {
        cameraState.apply {
            try {
                imageAnalysisBuilder = ImageAnalysisBuilder.configure(
                    aspectRatio ?: AspectRatio.RATIO_4_3,
                    when (format.uppercase()) {
                        "YUV_420" -> OutputImageFormat.YUV_420_888
                        "NV21" -> OutputImageFormat.NV21
                        "JPEG" -> OutputImageFormat.JPEG
                        "BGRA8888" -> OutputImageFormat.RGBA_8888
                        else -> OutputImageFormat.NV21
                    },
                    executor(activity!!), width,
                    maxFramesPerSecond = maxFramesPerSecond,
                )
                enableImageStream = autoStart
                updateLifecycle(activity!!)
            } catch (e: Exception) {
                Log.e(CamerawesomePlugin.TAG, "error while enable image analysis", e)
            }
        }

    }

    override fun setExifPreferences(
        exifPreferences: ExifPreferences, callback: (Result<Boolean>) -> Unit
    ) {
        if (exifPreferences.saveGPSLocation) {
            val permissions = listOf(
                Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION
            )
            CoroutineScope(Dispatchers.Main).launch {
                if (cameraPermissions.hasPermission(activity!!, permissions)) {
                    this@CameraAwesomeX.exifPreferences = exifPreferences
                    callback(Result.success(true))
                } else {
                    cameraPermissions.requestPermissions(
                        activity!!,
                        permissions,
                        CameraPermissions.PERMISSION_GEOLOC,
                    ) { grantedPermissions ->
                        if (grantedPermissions.isNotEmpty()) {
                            this@CameraAwesomeX.exifPreferences = exifPreferences
                        }
                        callback(Result.success(grantedPermissions.isNotEmpty()))
                    }
                }
            }
        } else {
            this.exifPreferences = exifPreferences
            callback(Result.success(true))
        }
    }

    override fun setFilter(matrix: List<Double>, bakeCaptures: Boolean) {
        colorMatrix = matrix
        this.bakeCaptures = bakeCaptures
        // MIN-3655: the preview is tinted natively — a filtered PreviewView
        // (TextureView + hardware-layer colour-filter paint) replaces the
        // PERFORMANCE one while a real matrix is active; identity restores it.
        // Pigeon calls arrive on the main thread, where CameraX wants both
        // setSurfaceProvider and view creation.
        val act = activity ?: return
        if (!::cameraState.isInitialized) return
        val recreated = cameraState.applyPreviewColorFilter(if (noneFilter != matrix) matrix else null, act)
        if (recreated) onPreviewViewRecreated?.invoke()
    }

    override fun isVideoRecordingAndImageAnalysisSupported(
        sensor: PigeonSensorPosition, callback: (Result<Boolean>) -> Unit
    ) {
        val cameraSelector =
            if (sensor == PigeonSensorPosition.BACK) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val cameraProvider = ProcessCameraProvider.getInstance(
                activity!!
            ).get()
            callback(
                Result.success(
                    CameraCapabilities.getCameraLevel(
                        cameraSelector, cameraProvider
                    ) == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3
                )
            )
        } else {
            callback(Result.success(false))
        }

    }

    override fun startAnalysis() {
        cameraState.apply {
            enableImageStream = true
            updateLifecycle(activity!!)
        }
    }

    override fun stopAnalysis() {
        cameraState.apply {
            enableImageStream = false
            updateLifecycle(activity!!)
        }
    }

    override fun requestPermissions(
        saveGpsLocation: Boolean, callback: (Result<List<String>>) -> Unit
    ) {
        // On a generic call, don't ask for specific permissions (location, record audio)
        cameraPermissions.requestBasePermissions(
            activity!!,
            saveGps = saveGpsLocation,
            recordAudio = false,
        ) { grantedPermissions ->
            callback(Result.success(grantedPermissions.mapNotNull {
                when (it) {
                    Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION -> CamerAwesomePermission.LOCATION.name.lowercase()
                    Manifest.permission.CAMERA -> CamerAwesomePermission.CAMERA.name.lowercase()
                    Manifest.permission.RECORD_AUDIO -> CamerAwesomePermission.RECORD_AUDIO.name.lowercase()
                    Manifest.permission.WRITE_EXTERNAL_STORAGE -> CamerAwesomePermission.STORAGE.name.lowercase()
                    else -> null
                }
            }))
        }
    }

    private fun getOrientedSize(width: Int, height: Int): Size {
        val portrait = cameraState.portrait
        return Size(
            if (portrait) width else height,
            if (portrait) height else width,
        )
    }

    override fun getPreviewTextureId(cameraPosition: Long): Long {
        return cameraState.textureEntries[cameraPosition.toString()]!!.id()
    }

    /// [PreviewViewProvider]: the current native preview surface for the
    /// `camerawesome/preview` platform view. Owned by [CameraXState] and only
    /// set for the single-sensor preview path (MIN-2406); null otherwise, in
    /// which case the Dart side falls back to the Flutter Texture.
    override fun currentPreviewView(): PreviewView? {
        return if (::cameraState.isInitialized) cameraState.previewView else null
    }

    /// MIN-3655: single-slot re-attach hook — see [PreviewViewProvider].
    private var onPreviewViewRecreated: (() -> Unit)? = null

    override fun setOnPreviewViewRecreated(listener: (() -> Unit)?) {
        onPreviewViewRecreated = listener
    }

    override fun onPreviewViewAttached() {
        // First open on a tablet: the camera bound while the PreviewView had no
        // display (so the preview defaulted to portrait, centered). Now that it's
        // attached, rebind once so the preview resolves the real window rotation
        // and fills the screen. One-shot to avoid re-flickering on later attaches.
        // (MIN-2437)
        if (!rebindOnFirstAttach || !::cameraState.isInitialized) return
        rebindOnFirstAttach = false
        activity?.let { cameraState.updateLifecycle(it) }
    }

    /***
     * [fusedLocationClient.getCurrentLocation] takes time, we might want to use
     * [fusedLocationClient.lastLocation] instead to go faster
     */
    @SuppressLint("MissingPermission")
    private fun retrieveLocation(callback: (Location?) -> Unit) {
        if (exifPreferences.saveGPSLocation && ActivityCompat.checkSelfPermission(
                activity!!, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            fusedLocationClient.getCurrentLocation(
                Priority.PRIORITY_HIGH_ACCURACY, cancellationTokenSource.token
            ).addOnCompleteListener {
                if (it.isSuccessful) {
                    callback(it.result)
                } else {
                    if (it.exception != null) {
                        Log.e(
                            CamerawesomePlugin.TAG, "Error finding location", it.exception
                        )
                    }
                    callback(null)
                }
            }
        } else {
            callback(null)
        }
    }

    override fun takePhoto(
        sensors: List<PigeonSensor>, paths: List<String?>, callback: (Result<Boolean>) -> Unit
    ) {
        if (sensors.size != paths.size) {
            throw Exception("sensors and paths must have the same length")
        }
        if (paths.size != cameraState.imageCaptures.size) {
            throw Exception("paths and imageCaptures must have the same length")
        }

        val sensorsMap = sensors.mapIndexed { index, pigeonSensor ->
            pigeonSensor to paths[index]
        }.toMap()
        CoroutineScope(Dispatchers.Main).launch {
            val res: MutableMap<PigeonSensor, Boolean?> =
                sensorsMap.mapValues { null }.toMutableMap()
            for ((index, entry) in sensorsMap.entries.withIndex()) {
                // On Android, path should be specified
                val imageFile = File(entry.value!!)
                imageFile.parentFile?.mkdirs()
                // cameraState.imageCaptures must be in the same order as the sensors / paths lists
                res[entry.key] = takePhotoWith(cameraState.imageCaptures[index], imageFile)
            }
            callback(Result.success(res.all { it.value == true }))
        }
    }

    @SuppressLint("RestrictedApi")
    private suspend fun takePhotoWith(
        imageCapture: ImageCapture, imageFile: File
    ): Boolean = suspendCancellableCoroutine { continuation ->
        val metadata = ImageCapture.Metadata()
        if (cameraState.sensors.size == 1 && cameraState.sensors.first().position == PigeonSensorPosition.FRONT) {
            metadata.isReversedHorizontal = cameraState.mirrorFrontCamera
        }
        val outputFileOptions =
            ImageCapture.OutputFileOptions.Builder(imageFile).setMetadata(metadata).build()
//        for (imageCapture in cameraState.imageCaptures) {
        imageCapture.targetRotation = captureOrientationOverride
            ?: orientationStreamListener!!.surfaceOrientation
        imageCapture.takePicture(outputFileOptions,
            ContextCompat.getMainExecutor(activity!!),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    // MIN-3655: preview-only filters (bakeCaptures == false)
                    // skip the bake — the photo is saved as captured.
                    if (bakeCaptures && colorMatrix != null && noneFilter != colorMatrix) {
                        val exif = ExifInterface(outputFileResults.savedUri!!.path!!)

                        val originalBitmap = BitmapFactory.decodeFile(
                            outputFileResults.savedUri?.path
                        )
                        val bitmapCopy = Bitmap.createBitmap(
                            originalBitmap.width, originalBitmap.height, Bitmap.Config.ARGB_8888
                        )

                        val canvas = Canvas(bitmapCopy)
                        canvas.drawBitmap(originalBitmap, 0f, 0f, Paint().apply {
                            colorFilter = ColorMatrixColorFilter(colorMatrix!!.map { it.toFloat() }
                                .toFloatArray())
                        })

                        try {
                            FileOutputStream(outputFileResults.savedUri?.path).use { out ->
                                bitmapCopy.compress(
                                    Bitmap.CompressFormat.JPEG, 100, out
                                )
                            }
                            exif.saveAttributes()
                        } catch (e: IOException) {
                            e.printStackTrace()
                        }
                    }

                    if (exifPreferences.saveGPSLocation) {
                        retrieveLocation {
                            val exif = ExifInterface(outputFileResults.savedUri!!.path!!)
                            outputFileOptions.metadata.location = it
                            exif.setGpsInfo(it)
//                            Log.d("CAMERAX__EXIF", "GPS info saved ${it?.latitude} ${it?.longitude}")
                            // We need to actually save the exif data to the file system
                            exif.saveAttributes()
                            continuation.resume(true)
                        }
                    } else {
                        if (continuation.isActive) continuation.resume(true)
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(CamerawesomePlugin.TAG, "Error capturing picture", exception)
                    continuation.resume(false)
                }
            })
//        }
    }

    @SuppressLint("RestrictedApi", "MissingPermission")
    override fun recordVideo(
        sensors: List<PigeonSensor>, paths: List<String?>, callback: (Result<Unit>) -> Unit
    ) {
        if (sensors.size != paths.size) {
            throw Exception("sensors and paths must have the same length")
        }
        if (paths.size != cameraState.videoCaptures.size) {
            throw Exception("paths and imageCaptures must have the same length")
        }

        val requests = sensors.mapIndexed { index, pigeonSensor ->
            pigeonSensor to paths[index]
        }.toMap()
        CoroutineScope(Dispatchers.Main).launch {
            var ignoreAudio = false
            if (cameraState.enableAudioRecording) {
                if (!cameraPermissions.hasPermission(
                        activity!!, listOf(Manifest.permission.RECORD_AUDIO)
                    )
                ) {
                    cameraPermissions.requestPermissions(
                        activity!!,
                        listOf(Manifest.permission.RECORD_AUDIO),
                        CameraPermissions.PERMISSION_RECORD_AUDIO,
                    ) {
                        ignoreAudio = it.isEmpty()
                    }
                } else {
                    ignoreAudio = false
                }
            }


            lastRecordedVideoSubscriptions?.forEach { it.dispose() }
            lastRecordedVideos = buildList {
                for (i in (0 until requests.size)) {
                    this.add(BehaviorSubject.create())
                }
            }
            cameraState.recordings = mutableListOf()
            lastRecordedVideoSubscriptions = mutableListOf()
            for ((index, videoCapture) in cameraState.videoCaptures.values.withIndex()) {
                val recordingListener = Consumer<VideoRecordEvent> { event ->
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            Log.d(CamerawesomePlugin.TAG, "Capture Started")
                        }

                        is VideoRecordEvent.Finalize -> {
                            if (!event.hasError()) {
                                Log.d(
                                    CamerawesomePlugin.TAG,
                                    "Video capture succeeded: ${event.outputResults.outputUri}"
                                )
                                lastRecordedVideos!![index].onNext(true)
                            } else {
                                // update app state when the capture failed.
                                cameraState.apply {
                                    recordings?.get(index)?.close()
                                    if (recordings?.all {
                                            it.isClosed
                                        } == true) {
                                        recordings = null
                                    }
                                }
                                Log.e(
                                    CamerawesomePlugin.TAG,
                                    "Video capture ends with error: ${event.error}"
                                )
                                lastRecordedVideos!![index].onNext(false)
                            }
                        }
                    }
                }
                videoCapture.targetRotation = orientationStreamListener!!.surfaceOrientation
                cameraState.recordings!!.add(videoCapture.output.prepareRecording(
                    activity!!, FileOutputOptions.Builder(File(paths[index]!!)).build()
                ).apply { if (cameraState.enableAudioRecording && !ignoreAudio) withAudioEnabled() }
                    .start(cameraState.executor(activity!!), recordingListener))
            }
            callback(Result.success(Unit))
        }
    }

    override fun stopRecordingVideo(callback: (Result<Boolean>) -> Unit) {
        var submitted = false
        for (index in 0 until cameraState.recordings!!.size) {
            val countDownTimer = object : CountDownTimer(5000, 5000) {
                override fun onTick(interval: Long) {}
                override fun onFinish() {
                    if (!submitted) {
                        submitted = true
                        callback(Result.success(false))
                    }
                }
            }
            countDownTimer.start()

            cameraState.recordings!![index].stop()
            lastRecordedVideoSubscriptions!!.add(lastRecordedVideos!![index].subscribe({ it ->
                countDownTimer.cancel()
                if (!submitted) {
                    submitted = true
                    callback(Result.success(it))
                }
            }, { error -> error.printStackTrace() }))
        }
    }

    override fun getFrontSensors(): List<PigeonSensorTypeDevice> {
        TODO("Not yet implemented")
    }

    override fun getBackSensors(): List<PigeonSensorTypeDevice> {
        TODO("Not yet implemented")
    }

    override fun pauseVideoRecording() {
        cameraState.recordings?.forEach { it.pause() }
    }

    override fun resumeVideoRecording() {
        cameraState.recordings?.forEach { it.resume() }
    }

    override fun receivedImageFromStream() {
        cameraState.imageAnalysisBuilder?.lastFrameAnalysisFinished()
    }


    override fun start(): Boolean {
        // Already started on setUp
        return true
    }

    override fun stop(): Boolean {
        unregisterDisplayListener()
        orientationStreamListener?.stop()
        cameraState.stop()
        return true
    }

    /// Listen for display rotation changes so the preview ViewPort/crop tracks the
    /// window orientation on tablets. Fires on physical rotation, but
    /// [CameraXState.refreshDisplayRotation] only rebinds when the *window*
    /// rotation actually changed, so a portrait-locked phone never rebinds.
    /// (MIN-2437)
    private fun registerDisplayListener() {
        val act = activity ?: return
        if (displayListener != null) return
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}
            override fun onDisplayRemoved(displayId: Int) {}
            override fun onDisplayChanged(displayId: Int) {
                activity?.let { cameraState.refreshDisplayRotation(it) }
            }
        }
        val manager = act.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        manager.registerDisplayListener(listener, Handler(Looper.getMainLooper()))
        displayManager = manager
        displayListener = listener
    }

    private fun unregisterDisplayListener() {
        displayListener?.let { displayManager?.unregisterDisplayListener(it) }
        displayListener = null
        displayManager = null
    }

    @SuppressLint("RestrictedApi")
    override fun setFlashMode(mode: String) {
        val flashMode = FlashMode.valueOf(mode)
        cameraState.apply {
            this.flashMode = flashMode
            for (imageCapture in cameraState.imageCaptures) {
                imageCapture.flashMode = when (flashMode) {
                    FlashMode.ALWAYS, FlashMode.ON -> ImageCapture.FLASH_MODE_ON
                    FlashMode.AUTO -> ImageCapture.FLASH_MODE_AUTO
                    else -> ImageCapture.FLASH_MODE_OFF
                }
            }
            (cameraState.concurrentCamera?.cameras?.firstOrNull()
                ?: cameraState.previewCamera)?.cameraControl?.enableTorch(flashMode == FlashMode.ALWAYS)
        }
    }

    override fun handleAutoFocus() {
        focus()
    }

    override fun setZoom(zoom: Double) {
        cameraState.setLinearZoom(zoom.toFloat())
    }

    @SuppressLint("RestrictedApi")
    override fun setSensor(sensors: List<PigeonSensor>) {
        cameraState.apply {
            this.sensors = sensors
            // TODO Make below variables parameters
            // Also reset flash mode and aspect ratio
            this.flashMode = FlashMode.NONE
            this.aspectRatio = null
            this.rational = Rational(3, 4)
            updateLifecycle(activity!!)
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setCorrection(brightness: Double) {
        // Map the normalised [0,1] slider value onto a fixed, bounded EV window
        // centred on neutral (0.5 -> 0 EV) instead of spreading it across the
        // device's full exposureCompensationRange (which is steep and whose span
        // varies per device). This keeps fine adjustment comfortable and gives
        // iOS/Android parity: the same normalised value yields the same EV
        // compensation on both platforms. Keep this EV window in sync with the
        // iOS SingleCameraPreview.setBrightness kBrightnessEvWindow. See MIN-2312.
        val brightnessEvWindow = 2.0 // +/- EV around neutral
        val exposureState = (cameraState.concurrentCamera?.cameras?.firstOrNull()
            ?: cameraState.previewCamera!!).cameraInfo.exposureState
        val range = exposureState.exposureCompensationRange
        val step = exposureState.exposureCompensationStep.toDouble() // EV per index step
        val targetEv = (brightness - 0.5) * 2.0 * brightnessEvWindow
        // Convert EV -> exposure-compensation index, then clamp to the device range.
        val index = if (step > 0.0) (targetEv / step).roundToInt() else 0
        cameraState.previewCamera?.cameraControl?.setExposureCompensationIndex(
            index.coerceIn(range.lower, range.upper)
        )
    }

    /**
     * @return the max zoom ratio, or 1.0 if cameraState/zoomState isn't ready
     *         yet (camera mid-bind or not started). Never throws across Pigeon.
     */
    override fun getMaxZoom(): Double {
        return runCatching { cameraState.maxZoomRatio }.getOrDefault(1.0)
    }

    /**
     * @return the min zoom ratio, or 1.0 if cameraState/zoomState isn't ready
     *         yet (camera mid-bind or not started). Never throws across Pigeon.
     */
    override fun getMinZoom(): Double {
        return runCatching { cameraState.minZoomRatio }.getOrDefault(1.0)
    }

    fun convertLinearToRatio(linear: Double): Double {
        // TODO Not sure if this is correct
        return linear * getMaxZoom() / getMinZoom()
    }

    @Deprecated("Use focusOnPoint instead")
    fun focus() {
        val autoFocusPoint = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(.5f, .5f)
        try {
            val autoFocusAction = FocusMeteringAction.Builder(
                autoFocusPoint, FocusMeteringAction.FLAG_AF
            ).apply {
                //start auto-focusing after 2 seconds
                setAutoCancelDuration(2, TimeUnit.SECONDS)
            }.build()
            cameraState.startFocusAndMetering(autoFocusAction)
        } catch (e: CameraInfoUnavailableException) {
            throw e
        }
    }

    @SuppressLint("RestrictedApi")
    override fun focusOnPoint(
        previewSize: PreviewSize,
        x: Double,
        y: Double,
        androidFocusSettings: AndroidFocusSettings?,
        iosFocusSettings: IOSFocusSettings?,
    ) {
        val autoCancelDurationInMillis = androidFocusSettings?.autoCancelDurationInMillis ?: 2500L
        val factory: MeteringPointFactory = SurfaceOrientedMeteringPointFactory(
            previewSize.width.toFloat(), previewSize.height.toFloat(),
        )

        val autoFocusPoint = factory.createPoint(x.toFloat(), y.toFloat())
        try {
            (cameraState.concurrentCamera?.cameras?.firstOrNull()
                ?: cameraState.previewCamera!!).cameraControl.startFocusAndMetering(
                FocusMeteringAction.Builder(
                    autoFocusPoint,
                    FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE or FocusMeteringAction.FLAG_AWB
                ).apply {
                    if (autoCancelDurationInMillis <= 0) {
                        disableAutoCancel()
                    } else {
                        setAutoCancelDuration(autoCancelDurationInMillis, TimeUnit.MILLISECONDS)
                    }
                }.build()
            )
        } catch (e: CameraInfoUnavailableException) {
            throw e
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setCaptureMode(mode: String) {
        cameraState.apply {
            setCaptureMode(CaptureModes.valueOf(mode))
            updateLifecycle(activity!!)
        }
    }


    @SuppressLint("RestrictedApi")
    @ExperimentalCamera2Interop
    override fun isMultiCamSupported(): Boolean {
        return getCameraProvider().isMultiCamSupported()
    }

    /// Forces the EXIF Orientation tag of subsequently captured photos to a
    /// fixed value, bypassing the device orientation sensor. Mapping:
    ///   "portrait"  → Surface.ROTATION_0  (portrait_up)
    ///   "landscape" → Surface.ROTATION_90 (landscape_right)
    ///   anything else (including null/empty) → clear the override and resume
    ///   the sensor-driven path.
    override fun setCaptureOrientationOverride(orientation: String?) {
        captureOrientationOverride = when (orientation?.lowercase()) {
            "portrait" -> Surface.ROTATION_0
            "landscape" -> Surface.ROTATION_90
            else -> null
        }
    }

    /// Changing the recording audio mode can't be changed once a recording has starded
    override fun setRecordingAudioMode(
        enableAudio: Boolean, callback: (Result<Boolean>) -> Unit
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            cameraPermissions.requestPermissions(
                activity!!,
                listOf(Manifest.permission.RECORD_AUDIO),
                CameraPermissions.PERMISSION_RECORD_AUDIO,
            ) { granted ->
                if (granted.isNotEmpty()) {
                    cameraState.apply {
                        enableAudioRecording = enableAudio
                        // No need to update lifecycle, it will be applied on next recording
                    }
                }
                Dispatchers.Main.run { callback(Result.success(granted.isNotEmpty())) }
            }
        }
    }

    @SuppressLint("RestrictedApi", "UnsafeOptInUsageError")
    override fun availableSizes(): List<PreviewSize> {
        return cameraState.previewSizes().map {
            PreviewSize(
                width = it.width.toDouble(), height = it.height.toDouble()
            )
        }
    }

    override fun refresh() {
//        TODO Nothing to do?
    }

    @SuppressLint("RestrictedApi")
    override fun getEffectivPreviewSize(index: Long): PreviewSize {
        val preview = cameraState.previews?.getOrNull(index.toInt()) ?: return PreviewSize(0.0, 0.0)
        val resolutionInfo = preview.resolutionInfo ?: return PreviewSize(0.0, 0.0)
        val res = resolutionInfo.resolution

        val rotation = resolutionInfo.rotationDegrees
        val previewSize = when (rotation) {
            90, 270 -> PreviewSize(res.height.toDouble(), res.width.toDouble())
            else -> PreviewSize(res.width.toDouble(), res.height.toDouble())
        }

        Log.d("CameraX", "Preview size: width=${previewSize.width}, height=${previewSize.height}, rotation=$rotation")
        return previewSize
    }

    @SuppressLint("RestrictedApi")
    override fun setPhotoSize(size: PreviewSize) {
        cameraState.apply {
            photoSize = getOrientedSize(size.width.toInt(), size.height.toInt())
            updateLifecycle(activity!!)
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setPreviewSize(size: PreviewSize) {
        cameraState.apply {
            previewSize = getOrientedSize(size.width.toInt(), size.height.toInt())
            updateLifecycle(activity!!)
        }
    }

    override fun setAspectRatio(aspectRatio: String) {
        cameraState.apply {
            this.updateAspectRatio(aspectRatio)
            updateLifecycle(activity!!)
        }
    }

    override fun setMirrorFrontCamera(mirror: Boolean) {
        cameraState.apply {
            this.mirrorFrontCamera = mirror
            updateLifecycle(activity!!)
        }
    }


    //    FLUTTER ATTACHMENTS
    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        this.binding = binding
        textureRegistry = binding.textureRegistry
        CameraInterface.setUp(binding.binaryMessenger, this)
        AnalysisImageUtils.setUp(binding.binaryMessenger, AnalysisImageConverter())
        orientationStreamChannel = EventChannel(binding.binaryMessenger, "camerawesome/orientation")
        orientationStreamChannel.setStreamHandler(sensorOrientationListener)
        imageStreamChannel = EventChannel(binding.binaryMessenger, "camerawesome/images")
        EventChannel(binding.binaryMessenger, "camerawesome/permissions").setStreamHandler(
            cameraPermissions
        )
        physicalButtonHandler = PhysicalButtonsHandler()
        EventChannel(binding.binaryMessenger, "camerawesome/physical_button").setStreamHandler(
            physicalButtonHandler
        )
        // Native preview platform view (MIN-2406, Android parity with iOS). The
        // factory reads the current PreviewView from this plugin on demand.
        binding.platformViewRegistry.registerViewFactory(
            "camerawesome/preview",
            CameraPreviewPlatformViewFactory(this)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        this.binding = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(cameraPermissions)
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(cameraPermissions)
    }

    override fun onDetachedFromActivity() {
        activity = null
        cancellationTokenSource.cancel()
        cameraPermissions.onCancel(null)
    }

}