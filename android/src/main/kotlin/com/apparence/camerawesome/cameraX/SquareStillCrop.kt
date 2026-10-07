package com.apparence.camerawesome.cameraX

import android.graphics.Bitmap
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.os.Build
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.apparence.camerawesome.CamerawesomePlugin
import java.io.File
import java.io.FileOutputStream
import kotlin.math.min

/// Turns a saved 4:3 still into the 1:1 photo: its centred square, keeping the
/// sensor's whole short side — the same crop iOS applies
/// (CameraPictureController -cropRectForWidth:) and the native camera apps make,
/// since the sensor itself is 4:3. 1:1 binds the 4:3 camera so switching between
/// the two never restarts the preview; the crop happens here instead.
internal object SquareStillCrop {
    private const val JPEG_QUALITY = 95

    /// Crops [file] in place. Returns false (leaving the 4:3 photo untouched) if
    /// the JPEG can't be read or written. Blocking — call off the main thread.
    fun cropInPlace(file: File): Boolean {
        val path = file.path
        return try {
            // Read before rewriting: the EXIF (orientation, capture metadata)
            // carries over onto the cropped pixels. A centred square is the same
            // region whatever the orientation tag says, so no rotation is needed.
            val exif = ExifInterface(path)
            val decoder = newRegionDecoder(path)
            val side: Int
            val square: Bitmap
            try {
                if (decoder.width == decoder.height) return true
                side = min(decoder.width, decoder.height)
                val left = (decoder.width - side) / 2
                val top = (decoder.height - side) / 2
                // Decodes only the square, not the whole frame.
                square = decoder.decodeRegion(Rect(left, top, left + side, top + side), null) ?: return false
            } finally {
                decoder.recycle()
            }
            FileOutputStream(path).use { out -> square.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out) }
            square.recycle()
            for (tag in listOf(
                ExifInterface.TAG_IMAGE_WIDTH,
                ExifInterface.TAG_IMAGE_LENGTH,
                ExifInterface.TAG_PIXEL_X_DIMENSION,
                ExifInterface.TAG_PIXEL_Y_DIMENSION,
            )) {
                exif.setAttribute(tag, side.toString())
            }
            exif.saveAttributes()
            true
        } catch (e: Exception) {
            Log.e(CamerawesomePlugin.TAG, "Could not crop the 1:1 photo; keeping the 4:3 still", e)
            false
        }
    }

    private fun newRegionDecoder(path: String): BitmapRegionDecoder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            BitmapRegionDecoder.newInstance(path)
        } else {
            @Suppress("DEPRECATION")
            BitmapRegionDecoder.newInstance(path, false)!!
        }
}
