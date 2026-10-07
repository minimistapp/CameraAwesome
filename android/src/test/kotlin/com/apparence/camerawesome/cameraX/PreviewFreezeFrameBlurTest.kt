package com.apparence.camerawesome.cameraX

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewFreezeFrameBlurTest {
    private fun argb(a: Int, r: Int, g: Int, b: Int) = (a shl 24) or (r shl 16) or (g shl 8) or b

    private fun blurRow(row: IntArray, radius: Int): IntArray {
        val out = IntArray(row.size)
        PreviewFreezeFrame.boxBlur(row, out, row.size, 1, radius, horizontal = true)
        return out
    }

    @Test
    fun `a flat colour is unchanged`() {
        val grey = argb(255, 120, 130, 140)
        assertArrayEquals(IntArray(5) { grey }, blurRow(IntArray(5) { grey }, radius = 2))
    }

    @Test
    fun `a single bright pixel spreads evenly over the window`() {
        val black = argb(255, 0, 0, 0)
        val row = IntArray(7) { black }.also { it[3] = argb(255, 250, 250, 250) }
        val out = blurRow(row, radius = 1)
        // Window of 3: the spike's three neighbours get a third each, the rest stay black.
        val third = argb(255, 83, 83, 83)
        assertArrayEquals(intArrayOf(black, black, third, third, third, black, black), out)
    }

    @Test
    fun `edges clamp instead of darkening`() {
        val white = argb(255, 255, 255, 255)
        // A clamped edge repeats the border pixel, so a white row stays white at both ends.
        val out = blurRow(IntArray(4) { white }, radius = 3)
        assertEquals(white, out.first())
        assertEquals(white, out.last())
    }

    @Test
    fun `channels blur independently, alpha included`() {
        val row = intArrayOf(argb(255, 255, 0, 0), argb(0, 0, 0, 255))
        val out = blurRow(row, radius = 1)
        // Clamped window for index 0 is [p0, p0, p1].
        assertEquals(argb(170, 170, 0, 85), out[0])
        // Clamped window for index 1 is [p0, p1, p1].
        assertEquals(argb(85, 85, 0, 170), out[1])
    }

    @Test
    fun `vertical pass walks columns`() {
        val black = argb(255, 0, 0, 0)
        val white = argb(255, 255, 255, 255)
        // 2 wide x 3 tall: column 0 is black/white/black, column 1 all white.
        val src = intArrayOf(black, white, white, white, black, white)
        val out = IntArray(src.size)
        PreviewFreezeFrame.boxBlur(src, out, width = 2, height = 3, radius = 1, horizontal = false)
        val third = argb(255, 85, 85, 85)
        assertArrayEquals(intArrayOf(third, white, third, white, third, white), out)
    }
}
