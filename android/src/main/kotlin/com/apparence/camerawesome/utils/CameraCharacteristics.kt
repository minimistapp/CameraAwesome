package com.apparence.camerawesome.utils

import android.hardware.camera2.CameraCharacteristics

fun CameraCharacteristics.hasFlashUnit(): Boolean {
    return this.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false
} 