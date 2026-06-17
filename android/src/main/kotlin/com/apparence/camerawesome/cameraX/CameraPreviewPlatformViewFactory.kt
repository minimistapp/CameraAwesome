package com.apparence.camerawesome.cameraX

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/// Registered for the `camerawesome/preview` view type (see
/// [CameraAwesomeX.onAttachedToEngine]). Android analogue of iOS's
/// `CameraPreviewPlatformViewFactory`: holds the [PreviewViewProvider] (the
/// plugin) and hands each platform view a way to fetch the current native
/// [androidx.camera.view.PreviewView]. MIN-2406.
class CameraPreviewPlatformViewFactory(
    private val provider: PreviewViewProvider,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return CameraPreviewPlatformView(context, provider)
    }
}
