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

    /// Crops [file] in place. All-or-nothing: on any failure it returns false and
    /// [file] is still the untouched 4:3 still — the original is only replaced
    /// once the cropped JPEG is fully written and its EXIF saved. Blocking —
    /// call off the main thread.
    fun cropInPlace(file: File): Boolean {
        // Suffixes distinct from ExifInterface's own "<name>.tmp" backup.
        val cropped = File(file.path + ".square")
        val original = File(file.path + ".original")
        var swapped = false
        return try {
            // Read before rewriting: the EXIF (orientation, capture metadata)
            // carries over onto the cropped pixels. A centred square is the same
            // region whatever the orientation tag says, so no rotation is needed.
            val exif = ExifInterface(file.path)
            // Already square: nothing to crop.
            val side = writeCenteredSquare(file, cropped) ?: return true
            // Swap the crop in, keeping the original until its EXIF is saved.
            // (ExifInterface writes back to the path it read, so the cached tags
            // have to land on the cropped bytes at [file]'s own path.)
            if (!file.renameTo(original)) return false
            if (!cropped.renameTo(file)) {
                original.renameTo(file)
                return false
            }
            swapped = true
            for (tag in listOf(
                ExifInterface.TAG_IMAGE_WIDTH,
                ExifInterface.TAG_IMAGE_LENGTH,
                ExifInterface.TAG_PIXEL_X_DIMENSION,
                ExifInterface.TAG_PIXEL_Y_DIMENSION,
            )) {
                exif.setAttribute(tag, side.toString())
            }
            exif.saveAttributes()
            original.delete()
            true
        } catch (e: Exception) {
            Log.e(CamerawesomePlugin.TAG, "Could not crop the 1:1 photo", e)
            if (swapped) {
                // Put the untouched original back over the half-done crop.
                file.delete()
                original.renameTo(file)
            }
            false
        } finally {
            cropped.delete()
        }
    }

    /// Writes [source]'s centred square to [target]. Returns its side, null if
    /// [source] is already square (nothing to do), or throws.
    private fun writeCenteredSquare(source: File, target: File): Int? {
        val decoder = newRegionDecoder(source.path)
        val side: Int
        val square: Bitmap
        try {
            if (decoder.width == decoder.height) return null
            side = min(decoder.width, decoder.height)
            val left = (decoder.width - side) / 2
            val top = (decoder.height - side) / 2
            // Decodes only the square, not the whole frame.
            square = decoder.decodeRegion(Rect(left, top, left + side, top + side), null)
                ?: throw IllegalStateException("decodeRegion returned null")
        } finally {
            decoder.recycle()
        }
        try {
            val written = FileOutputStream(target).use { out -> square.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out) }
            check(written) { "JPEG encode failed" }
        } finally {
            square.recycle()
        }
        return side
    }

    private fun newRegionDecoder(path: String): BitmapRegionDecoder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            BitmapRegionDecoder.newInstance(path)
        } else {
            @Suppress("DEPRECATION")
            BitmapRegionDecoder.newInstance(path, false)!!
        }
}
