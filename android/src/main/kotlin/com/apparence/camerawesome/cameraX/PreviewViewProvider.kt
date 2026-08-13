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

    /// Called when the preview's platform view attaches to the window. By this
    /// point the PreviewView has a real display, so CameraX can resolve the
    /// correct preview rotation — the implementation rebinds once on first open
    /// so the preview isn't stuck at the bind-time (display-less, portrait)
    /// rotation. (MIN-2437)
    fun onPreviewViewAttached() {}

    /// MIN-3655: registers a main-thread callback fired whenever the provider
    /// swaps to a NEW PreviewView instance at runtime (colour-filter toggles
    /// recreate it in the matching implementation mode), so the mounted
    /// container can re-attach. Single-slot — the single-camera path mounts one
    /// preview platform view at a time; pass null to unregister.
    fun setOnPreviewViewRecreated(listener: (() -> Unit)?) {}
}
