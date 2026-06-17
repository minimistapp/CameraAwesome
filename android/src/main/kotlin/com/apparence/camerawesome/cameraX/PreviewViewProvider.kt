package com.apparence.camerawesome.cameraX

import androidx.camera.view.PreviewView

/// Lets the preview [io.flutter.plugin.platform.PlatformView] read the CURRENT
/// native [PreviewView] on demand without owning it — the Android analogue of
/// iOS's `CameraPreviewLayerProvider` (which vends the current
/// `AVCaptureVideoPreviewLayer`). The PreviewView is owned by [CameraXState] and
/// recreated on each setupCamera, so the platform view must always fetch the
/// live one rather than hold a stale reference. See MIN-2406 (iOS) for the
/// architecture this mirrors.
interface PreviewViewProvider {
    fun currentPreviewView(): PreviewView?
}
