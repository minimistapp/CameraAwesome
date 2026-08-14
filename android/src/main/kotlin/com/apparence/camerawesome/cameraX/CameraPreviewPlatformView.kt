package com.apparence.camerawesome.cameraX

import android.content.Context
import android.graphics.Color
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.camera.view.PreviewView
import io.flutter.plugin.platform.PlatformView

/// Android port of iOS's `CameraPreviewPlatformView` (MIN-2406): a thin, native
/// host for the camera-owned [PreviewView], mounted by Flutter as the
/// `camerawesome/preview` platform view. The preview is OS-composited (the
/// PreviewView's own SurfaceView/TextureView), decoupled from Flutter's
/// compositor — matching the iOS `AVCaptureVideoPreviewLayer` approach.
///
/// The [PreviewView] is owned by [CameraXState] (recreated on each setupCamera),
/// not by this view; we only (re)attach the current one, mirroring iOS's
/// `attachPreviewLayerIfNeeded`. An Android `View` has exactly one parent, so we
/// re-parent defensively across remounts.
class CameraPreviewPlatformView(
    context: Context,
    private val provider: PreviewViewProvider,
) : PlatformView {

    /// Non-interactive container so touches fall through to Flutter's gesture
    /// arena (the app composites its own tap-to-focus / pinch-to-zoom detectors
    /// on top). Mirrors iOS `userInteractionEnabled = NO`. Retries the attach on
    /// `onAttachedToWindow` like iOS's `layoutSubviews`, in case the view mounts
    /// before the camera session is wired up.
    private inner class CameraPreviewContainerView(context: Context) : FrameLayout(context) {
        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            attachPreviewViewIfNeeded()
            // Now that the PreviewView has a real display, let the camera rebind
            // so the preview picks up the correct rotation instead of the
            // bind-time (display-less, portrait) one. (MIN-2437)
            provider.onPreviewViewAttached()
        }
    }

    private val container = CameraPreviewContainerView(context).apply {
        setBackgroundColor(Color.BLACK)
        isClickable = false
        isFocusable = false
        isFocusableInTouchMode = false
    }

    init {
        attachPreviewViewIfNeeded()
        // MIN-3655: colour-filter toggles recreate the PreviewView at runtime
        // (TextureView while filtered, SurfaceView otherwise) — re-attach the
        // fresh instance when that happens.
        provider.setOnPreviewViewRecreated { attachPreviewViewIfNeeded() }
    }

    private fun attachPreviewViewIfNeeded() {
        val previewView = provider.currentPreviewView() ?: return
        // Already showing exactly this PreviewView — nothing to do.
        if (container.childCount == 1 && container.getChildAt(0) === previewView) {
            return
        }
        // A new PreviewView instance (e.g. after a fresh setupCamera) — drop any
        // stale child so we don't leave old views/surfaces parented here.
        container.removeAllViews()
        // An Android View has exactly one parent — detach from any prior
        // (remounted) host before re-parenting. Defensive, like iOS's
        // removeFromSuperlayer.
        (previewView.parent as? ViewGroup)?.removeView(previewView)
        container.addView(
            previewView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    override fun getView(): View {
        // Defensive re-attach in case the camera was set up after this view was
        // created (timing parity with iOS's layoutSubviews retry).
        attachPreviewViewIfNeeded()
        return container
    }

    override fun dispose() {
        provider.setOnPreviewViewRecreated(null)
        // Detach the shared PreviewView so it isn't held by a dead container; it
        // is owned by CameraXState and torn down with the camera session.
        val previewView = provider.currentPreviewView()
        if (previewView != null && previewView.parent === container) {
            container.removeView(previewView)
        }
    }
}
