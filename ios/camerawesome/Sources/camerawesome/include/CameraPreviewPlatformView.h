//
//  CameraPreviewPlatformView.h
//  camerawesome
//
//  Native preview path (MIN-2406): hosts the capture session's
//  AVCaptureVideoPreviewLayer inside a Flutter PlatformView (UiKitView) so the
//  on-screen preview is GPU-composited and full-sensor sharp — decoupled from
//  the small AVCaptureVideoDataOutput that feeds MLKit analysis. Replaces the
//  Flutter Texture for the *display* of the main preview on iOS; the texture
//  is still registered (cheap now that the data output is downscaled) for the
//  filter-selector thumbnail, floating/multicam previews and readiness gating.
//

#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Supplies the live preview layer to a platform view on demand. Implemented by
/// CamerawesomePlugin so the factory/view stay decoupled from camera ownership
/// and always read the *current* layer (SingleCameraPreview recreates it on
/// every setupCamera).
@protocol CameraPreviewLayerProvider <NSObject>
- (nullable AVCaptureVideoPreviewLayer *)currentPreviewLayer;

/// MIN-3655: the filtered-preview overlay while a colour filter is active
/// (an AVSampleBufferDisplayLayer fed CIColorMatrix-filtered frames), or nil
/// when no filter is applied. The container composites it over — and hides —
/// the raw preview layer so the on-screen image carries the filter without
/// ever leaving the native display path.
- (nullable AVSampleBufferDisplayLayer *)currentFilteredPreviewLayer;

/// MIN-3655: lets the provider poke the mounted container (setNeedsLayout)
/// when the filter toggles — attachment happens in layoutSubviews, and a
/// filter change on its own triggers no layout. Weakly held; the container
/// registers itself on creation.
- (void)registerPreviewContainerView:(UIView *)containerView;

/// When non-nil (a boxed AVCaptureVideoOrientation), the preview connection is
/// pinned to this orientation instead of following the window's interface
/// orientation. Driven by the app's camera orientation lock: native controllers
/// presented above the app (image cropper, pickers) rotate the scene under
/// their own masks, and those transient interface-orientation excursions must
/// not be able to re-orient a locked preview. (MIN-2646)
- (nullable NSNumber *)previewOrientationOverride;
@end

/// Factory registered under the "camerawesome/preview" viewType. Flutter calls
/// -createWithFrame:viewIdentifier:arguments: each time a
/// `UiKitView(viewType: "camerawesome/preview")` mounts.
@interface CameraPreviewPlatformViewFactory : NSObject <FlutterPlatformViewFactory>
- (instancetype)initWithProvider:(id<CameraPreviewLayerProvider>)provider;
@end

NS_ASSUME_NONNULL_END
