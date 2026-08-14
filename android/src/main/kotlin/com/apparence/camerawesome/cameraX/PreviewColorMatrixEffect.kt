package com.apparence.camerawesome.cameraX

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraEffect
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import androidx.core.util.Consumer
import com.apparence.camerawesome.CamerawesomePlugin
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Executor

/**
 * MIN-3655: applies the preview colour matrix **inside the CameraX pipeline, on
 * the GPU**, as a [CameraEffect] targeting [CameraEffect.PREVIEW] only.
 *
 * Why this exists: the first implementation tinted the preview by putting
 * [androidx.camera.view.PreviewView] into `COMPATIBLE` (TextureView) and hanging
 * a `ColorMatrixColorFilter` off a hardware layer. That cost two things at once,
 * and the bigger one was the TextureView, not the colour maths:
 *
 * - **The TextureView.** `AwesomeCameraPreview` mounts the preview with
 *   `initSurfaceAndroidView`, which renders a platform view into a Flutter-owned
 *   Surface *unless* the view can't do that — and a SurfaceView can't, so
 *   `PERFORMANCE` silently falls back to true hybrid composition and the preview
 *   gets its own hardware-composer overlay plane. A TextureView can render into
 *   that Surface, so `COMPATIBLE` opts the preview back **into** Flutter's
 *   compositor: a full-surface copy per frame, GPU-composited. MIN-3577 measured
 *   exactly this regime on a Lenovo TB-X606F — the preview was the only
 *   `composition=CLIENT` layer on the device while everything else sat on
 *   overlays — and it was the preview jank there too.
 * - **The layer paint.** `setLayerPaint` on a hardware layer forces a second
 *   full-resolution offscreen pass on top of that.
 *
 * The corroborating datapoint from the field: the UVC preview — a plain Flutter
 * `Texture` under `ColorFiltered`, i.e. the same 4×5 matrix folded into a draw
 * Skia was doing anyway — stays smooth with any filter. The arithmetic was never
 * the problem; the display path was.
 *
 * With the matrix moved here the preview surface stays a SurfaceView
 * (`PERFORMANCE`) while filtered, and the colour maths rides the single texture
 * blit that the effect pipeline performs — no extra passes on the display path.
 *
 * Scope:
 * - **PREVIEW only.** Captures are never filtered (the app sets
 *   `bakeCaptures: false` and the backend bakes the profile server-side);
 *   targeting IMAGE_CAPTURE here would double-bake.
 * - Identity installs no effect at all — see [CameraXState.updateLifecycle].
 * - Retuning the matrix does **not** rebind: [colorMatrix] is read fresh by the
 *   render thread each frame, so dragging a slider costs nothing but new
 *   uniforms.
 */
class PreviewColorMatrixEffect private constructor(
    private val processor: ColorMatrixSurfaceProcessor,
) : CameraEffect(
    PREVIEW,
    processor.glExecutor,
    processor,
    Consumer<Throwable> { Log.e(CamerawesomePlugin.TAG, "Preview colour effect failed", it) },
) {

    constructor(matrix: List<Double>) : this(ColorMatrixSurfaceProcessor(matrix))

    /// Swaps the live matrix. Cheap and rebind-free — the next rendered frame
    /// picks it up.
    fun updateMatrix(matrix: List<Double>) {
        processor.colorMatrix = ColorMatrixUniforms(matrix)
    }

    /// Tears down the GL thread/context. Call once the effect has been unbound
    /// (i.e. after the rebind that drops it from the UseCaseGroup).
    fun release() = processor.release()
}

/**
 * The 4×5 colour matrix as the two uniforms the shader wants.
 *
 * Input layout is Flutter's `ColorFilter.matrix`: 20 doubles, **row-major**, one
 * row per output channel (R, G, B, A), each row `[r, g, b, a, offset]` — i.e.
 *
 * ```
 * R' = m[0]*R + m[1]*G + m[2]*B + m[3]*A + m[4]
 * ```
 *
 * The five columns are not homogeneous: the first four are unitless
 * coefficients, but the **fifth is an additive offset in the 0–255 domain**
 * while the shader works in 0..1 — hence the `/ 255f`.
 *
 * GLES 2.0 has no `transpose` flag on `glUniformMatrix4fv` (it must be
 * `GL_FALSE`), and `mat4` uniforms are read **column-major**, so the transpose
 * is done here: element `[row][col]` lands at `col * 4 + row`.
 */
class ColorMatrixUniforms(matrix: List<Double>) {
    /// Column-major mat4 of the 4×4 coefficient block.
    val coefficients = FloatArray(16)

    /// Per-channel additive offset, rescaled to 0..1.
    val offsets = FloatArray(4)

    init {
        for (row in 0 until 4) {
            for (col in 0 until 4) {
                coefficients[col * 4 + row] = matrix[row * 5 + col].toFloat()
            }
            offsets[row] = matrix[row * 5 + 4].toFloat() / 255f
        }
    }
}

/**
 * MIN-3655: the [SurfaceProcessor] behind [PreviewColorMatrixEffect].
 *
 * Everything (CameraX callbacks included — the effect hands CameraX
 * [glExecutor]) runs on one GL thread, so no locking is needed beyond the
 * `@Volatile` matrix that the platform channel writes from the main thread.
 *
 * The per-frame loop is the canonical CameraX effect recipe: latch the camera
 * frame into an external-OES texture, ask each [SurfaceOutput] to fold the
 * pipeline's crop/rotation/mirroring into the SurfaceTexture transform
 * ([SurfaceOutput.updateTransformMatrix]), and blit with that transform. Getting
 * the transform from the SurfaceOutput rather than inventing one is what keeps
 * the filtered preview upright and correctly cropped (cf. the orientation bug in
 * the earlier TextureView implementation).
 */
class ColorMatrixSurfaceProcessor(matrix: List<Double>) : SurfaceProcessor {

    private val glThread = HandlerThread("CamerAwesomeColorMatrixGL").apply { start() }
    private val glHandler = Handler(glThread.looper)

    /// Executor for both CameraX's [SurfaceProcessor] callbacks and our own
    /// teardown, so everything is serialised onto the GL thread.
    val glExecutor = Executor { glHandler.post(it) }

    @Volatile
    var colorMatrix: ColorMatrixUniforms = ColorMatrixUniforms(matrix)

    private var released = false
    private var glReady = false

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var tempSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var program = 0
    private var texMatrixLoc = 0
    private var colorMatrixLoc = 0
    private var colorOffsetLoc = 0

    private var inputTexture: SurfaceTexture? = null
    private val outputs = LinkedHashMap<SurfaceOutput, EGLSurface>()

    private val textureTransform = FloatArray(16)
    private val outputTransform = FloatArray(16)

    private val vertexBuffer: FloatBuffer = floatBufferOf(
        // A full-viewport triangle strip: (x, y) NDC.
        -1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f,
    )
    private val texCoordBuffer: FloatBuffer = floatBufferOf(
        // Matching (s, t, 0, 1) — vec4 so the 4×4 SurfaceTexture transform applies.
        0f, 0f, 0f, 1f,
        1f, 0f, 0f, 1f,
        0f, 1f, 0f, 1f,
        1f, 1f, 0f, 1f,
    )

    override fun onInputSurface(request: SurfaceRequest) {
        if (released) {
            request.willNotProvideSurface()
            return
        }
        if (!ensureGl() || !makeCurrent(tempSurface)) {
            request.willNotProvideSurface()
            return
        }
        // A texture per input rather than one shared one: a rebind can hand us a
        // new SurfaceRequest before CameraX has finished releasing the previous
        // surface, and two live SurfaceTextures on the same texture name alias
        // each other.
        val textureId = createExternalTexture()
        val surfaceTexture = SurfaceTexture(textureId)
        surfaceTexture.setDefaultBufferSize(request.resolution.width, request.resolution.height)
        val surface = Surface(surfaceTexture)
        // Released by CameraX when it stops using the surface (unbind, rebind,
        // camera close). Guarded because a *newer* input may already have taken
        // over by then.
        request.provideSurface(surface, glExecutor) {
            surfaceTexture.setOnFrameAvailableListener(null)
            surfaceTexture.release()
            surface.release()
            if (makeCurrent(tempSurface)) GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
            if (inputTexture === surfaceTexture) inputTexture = null
        }
        surfaceTexture.setOnFrameAvailableListener({ onFrame(it) }, glHandler)
        inputTexture = surfaceTexture
    }

    override fun onOutputSurface(surfaceOutput: SurfaceOutput) {
        if (released || !ensureGl()) {
            surfaceOutput.close()
            return
        }
        val surface = surfaceOutput.getSurface(glExecutor) { event -> removeOutput(event.surfaceOutput) }
        val eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
        )
        if (eglSurface == null || eglSurface == EGL14.EGL_NO_SURFACE) {
            Log.e(CamerawesomePlugin.TAG, "Colour effect: could not create an EGL surface for the preview")
            surfaceOutput.close()
            return
        }
        outputs[surfaceOutput] = eglSurface
    }

    private fun removeOutput(surfaceOutput: SurfaceOutput) {
        val eglSurface = outputs.remove(surfaceOutput)
        if (eglSurface != null) {
            // Never destroy a surface that is still current.
            makeCurrent(tempSurface)
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
        }
        surfaceOutput.close()
    }

    private fun onFrame(surfaceTexture: SurfaceTexture) {
        if (released || !glReady || surfaceTexture !== inputTexture) return
        if (!makeCurrent(tempSurface)) return
        try {
            surfaceTexture.updateTexImage()
        } catch (e: RuntimeException) {
            // The producer can vanish mid-teardown; dropping the frame is enough.
            Log.w(CamerawesomePlugin.TAG, "Colour effect: skipped a frame (${e.message})")
            return
        }
        surfaceTexture.getTransformMatrix(textureTransform)
        val matrix = colorMatrix
        for ((surfaceOutput, eglSurface) in outputs) {
            surfaceOutput.updateTransformMatrix(outputTransform, textureTransform)
            drawFrame(eglSurface, surfaceOutput, matrix, surfaceTexture.timestamp)
        }
    }

    private fun drawFrame(
        eglSurface: EGLSurface,
        surfaceOutput: SurfaceOutput,
        matrix: ColorMatrixUniforms,
        timestampNs: Long,
    ) {
        if (!makeCurrent(eglSurface)) return
        val size = surfaceOutput.size
        GLES20.glViewport(0, 0, size.width, size.height)
        GLES20.glUniformMatrix4fv(texMatrixLoc, 1, false, outputTransform, 0)
        GLES20.glUniformMatrix4fv(colorMatrixLoc, 1, false, matrix.coefficients, 0)
        GLES20.glUniform4fv(colorOffsetLoc, 1, matrix.offsets, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, timestampNs)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun makeCurrent(eglSurface: EGLSurface): Boolean {
        if (!glReady || eglSurface == EGL14.EGL_NO_SURFACE) return false
        return EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
    }

    /// One-shot EGL/GLES bring-up on the GL thread. Returns false if the device
    /// refused us a context — the caller then declines the surface and CameraX
    /// reports the effect as failed rather than showing a black preview.
    private fun ensureGl(): Boolean {
        if (glReady) return true
        if (released) return false
        return try {
            initGl()
            glReady = true
            true
        } catch (e: Exception) {
            Log.e(CamerawesomePlugin.TAG, "Colour effect: GL init failed", e)
            false
        }
    }

    private fun initGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }

        val configs = arrayOfNulls<EGLConfig>(1)
        val configCount = IntArray(1)
        val configAttributes = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        check(
            EGL14.eglChooseConfig(eglDisplay, configAttributes, 0, configs, 0, 1, configCount, 0)
                    && configCount[0] > 0,
        ) { "no suitable EGL config" }
        eglConfig = configs[0]

        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

        // A 1×1 pbuffer to be current on while latching frames and tearing
        // output surfaces down.
        tempSurface = EGL14.eglCreatePbufferSurface(
            eglDisplay, eglConfig,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        check(tempSurface != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }
        check(EGL14.eglMakeCurrent(eglDisplay, tempSurface, tempSurface, eglContext)) { "eglMakeCurrent failed" }

        program = buildProgram()
        GLES20.glUseProgram(program)
        texMatrixLoc = GLES20.glGetUniformLocation(program, "uTexMatrix")
        colorMatrixLoc = GLES20.glGetUniformLocation(program, "uColorMatrix")
        colorOffsetLoc = GLES20.glGetUniformLocation(program, "uColorOffset")
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "sTexture"), 0)

        val positionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        GLES20.glVertexAttribPointer(positionLoc, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)
        GLES20.glEnableVertexAttribArray(positionLoc)
        val texCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        GLES20.glVertexAttribPointer(texCoordLoc, 4, GLES20.GL_FLOAT, false, 0, texCoordBuffer)
        GLES20.glEnableVertexAttribArray(texCoordLoc)

        // Unit 0 stays active for the whole session; SurfaceTexture.updateTexImage
        // binds its own texture to the active unit, so the draw always samples the
        // frame just latched.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    }

    private fun createExternalTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )
        return textures[0]
    }

    private fun buildProgram(): Int {
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val id = GLES20.glCreateProgram()
        check(id != 0) { "glCreateProgram failed" }
        GLES20.glAttachShader(id, vertexShader)
        GLES20.glAttachShader(id, fragmentShader)
        GLES20.glLinkProgram(id)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, linked, 0)
        check(linked[0] == GLES20.GL_TRUE) { "link failed: ${GLES20.glGetProgramInfoLog(id)}" }
        // The program keeps the compiled shaders alive.
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        return id
    }

    private fun compileShader(type: Int, source: String): Int {
        val id = GLES20.glCreateShader(type)
        check(id != 0) { "glCreateShader failed" }
        GLES20.glShaderSource(id, source)
        GLES20.glCompileShader(id)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, compiled, 0)
        check(compiled[0] == GLES20.GL_TRUE) { "shader compile failed: ${GLES20.glGetShaderInfoLog(id)}" }
        return id
    }

    fun release() {
        // quitSafely runs anything already queued (a pending output close, the
        // SurfaceRequest's release callback) before the looper stops.
        glHandler.post {
            if (released) return@post
            released = true
            for ((surfaceOutput, eglSurface) in outputs) {
                makeCurrent(tempSurface)
                EGL14.eglDestroySurface(eglDisplay, eglSurface)
                surfaceOutput.close()
            }
            outputs.clear()
            // May already have been released by CameraX's surface callback.
            inputTexture?.let { runCatching { it.setOnFrameAvailableListener(null) } }
            inputTexture = null
            if (glReady) {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
                EGL14.eglDestroySurface(eglDisplay, tempSurface)
                EGL14.eglDestroyContext(eglDisplay, eglContext)
                EGL14.eglTerminate(eglDisplay)
                glReady = false
            }
            glThread.quitSafely()
        }
    }

    private fun floatBufferOf(vararg values: Float): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }

    companion object {
        private val VERTEX_SHADER = """
            uniform mat4 uTexMatrix;
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = (uTexMatrix * aTextureCoord).xy;
            }
        """.trimIndent()

        /// `uColorMatrix` is the 4×4 coefficient block (column-major, see
        /// [ColorMatrixUniforms]); `uColorOffset` is the 5th column already
        /// rescaled from Flutter's 0–255 domain to the 0..1 the sampler returns.
        private val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            uniform mat4 uColorMatrix;
            uniform vec4 uColorOffset;
            void main() {
                gl_FragColor = uColorMatrix * texture2D(sTexture, vTextureCoord) + uColorOffset;
            }
        """.trimIndent()
    }
}
