package com.apparence.camerawesome.cameraX

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// MIN-6738: the tap geometry that used to focus a quarter-turn away from the
/// finger on a portrait phone.
class TapMeteringMathTest {
    private val eps = 1e-4f

    @Test
    fun `portrait back camera - a tap top-left lands bottom-left of the sensor`() {
        // Back sensors are mounted landscape, 90° clockwise from an upright
        // phone. The upright top-left corner is the sensor's left edge, bottom.
        val (x, y) = TapMeteringMath.displayToSurface(0.1f, 0.2f, 90)
        assertEquals(0.2f, x, eps)
        assertEquals(0.9f, y, eps)
    }

    @Test
    fun `every rotation keeps the centre and round-trips a corner`() {
        for (rotation in listOf(0, 90, 180, 270, -90, 450)) {
            val (cx, cy) = TapMeteringMath.displayToSurface(0.5f, 0.5f, rotation)
            assertEquals(0.5f, cx, eps)
            assertEquals(0.5f, cy, eps)
        }
        assertEquals(0.3f to 0.7f, TapMeteringMath.displayToSurface(0.3f, 0.7f, 0))
        val (x180, y180) = TapMeteringMath.displayToSurface(0.3f, 0.7f, 180)
        assertEquals(0.7f, x180, eps)
        assertEquals(0.3f, y180, eps)
        val (x270, y270) = TapMeteringMath.displayToSurface(0.3f, 0.7f, 270)
        assertEquals(0.3f, x270, eps)
        assertEquals(0.3f, y270, eps)
    }

    @Test
    fun `crop region is the whole array without crop zoom, centred with it`() {
        assertEquals(TapMeteringMath.IntRect(0, 0, 4000, 3000), TapMeteringMath.cropRegion(4000, 3000, 1f))
        assertEquals(TapMeteringMath.IntRect(1000, 750, 3000, 2250), TapMeteringMath.cropRegion(4000, 3000, 2f))
    }

    @Test
    fun `metering rect is centred on the point and sized by the crop`() {
        val crop = TapMeteringMath.IntRect(0, 0, 4000, 3000)
        val r = TapMeteringMath.meteringRect(0.25f, 0.5f, 0.1f, 4.0 / 3.0, crop)
        assertEquals(TapMeteringMath.IntRect(800, 1350, 1200, 1650), r)
    }

    @Test
    fun `a 16x9 surface covers only the middle rows of a 4x3 sensor`() {
        val crop = TapMeteringMath.IntRect(0, 0, 4000, 3000)
        // Top edge of a 16:9 frame is 375 rows into the 3000-row array.
        val top = TapMeteringMath.meteringRect(0.5f, 0f, 0.01f, 16.0 / 9.0, crop)
        assertEquals(375, (top.top + top.bottom) / 2, 2)
        // x is untouched: the surface spans the full width.
        assertEquals(2000, (top.left + top.right) / 2, 2)
    }

    @Test
    fun `a narrower surface covers only the middle columns`() {
        val crop = TapMeteringMath.IntRect(0, 0, 4000, 3000)
        // A 1:1 surface spans columns 500..3500.
        val left = TapMeteringMath.meteringRect(0f, 0.5f, 0.01f, 1.0, crop)
        assertEquals(500, (left.left + left.right) / 2, 2)
    }

    @Test
    fun `metering rect is clamped inside the crop at the edges`() {
        val crop = TapMeteringMath.IntRect(1000, 750, 3000, 2250)
        val r = TapMeteringMath.meteringRect(1f, 1f, 0.2f, 4.0 / 3.0, crop)
        assertTrue(r.left >= crop.left && r.top >= crop.top)
        assertTrue(r.right <= crop.right && r.bottom <= crop.bottom)
        assertTrue(r.width > 0 && r.height > 0)
    }

    @Test
    fun `rotation between orientations`() {
        val identity = floatArrayOf(1f, 0f, 0f, 0f)
        assertEquals(0f, TapMeteringMath.rotationDegreesBetween(identity, identity), 0.01f)
        // 20° about z: (cos 10°, 0, 0, sin 10°).
        val rad = Math.toRadians(10.0)
        val turned = floatArrayOf(Math.cos(rad).toFloat(), 0f, 0f, Math.sin(rad).toFloat())
        assertEquals(20f, TapMeteringMath.rotationDegreesBetween(identity, turned), 0.05f)
        // q and -q are the same orientation.
        val negated = turned.map { -it }.toFloatArray()
        assertEquals(0f, TapMeteringMath.rotationDegreesBetween(turned, negated), 0.05f)
    }

    private fun assertEquals(expected: Int, actual: Int, tolerance: Int) {
        assertTrue("expected $expected ± $tolerance, was $actual", kotlin.math.abs(expected - actual) <= tolerance)
    }
}
