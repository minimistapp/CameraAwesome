//
//  CameraPreviewPlatformView.m
//  camerawesome
//
//  See CameraPreviewPlatformView.h. MIN-2406.
//

#import "CameraPreviewPlatformView.h"

/// Maps the app's interface (window) orientation to the matching capture video
/// orientation. This is a DIRECT mapping — UIInterfaceOrientation and
/// AVCaptureVideoOrientation share raw values for the landscape cases
/// (LandscapeLeft=4, LandscapeRight=3), so they must NOT be crossed (crossing is
/// only correct for UIDeviceOrientation, and here produced a 180°-flipped /
/// upside-down preview). Defaults to portrait for unknown/face-up. (MIN-2437)
static AVCaptureVideoOrientation CAMVideoOrientationFromInterface(UIInterfaceOrientation interfaceOrientation) {
  switch (interfaceOrientation) {
    case UIInterfaceOrientationPortraitUpsideDown:
      return AVCaptureVideoOrientationPortraitUpsideDown;
    case UIInterfaceOrientationLandscapeLeft:
      return AVCaptureVideoOrientationLandscapeLeft;
    case UIInterfaceOrientationLandscapeRight:
      return AVCaptureVideoOrientationLandscapeRight;
    case UIInterfaceOrientationPortrait:
    case UIInterfaceOrientationUnknown:
    default:
      return AVCaptureVideoOrientationPortrait;
  }
}

#pragma mark - Container view

/// UIView that hosts the camera's AVCaptureVideoPreviewLayer as a sublayer and
/// keeps its frame pinned to the view's bounds. We host the camera-owned layer
/// (rather than +layerClass) because the layer is owned by SingleCameraPreview,
/// shared with focus-point conversion, and recreated on every setupCamera —
/// the view simply (re)attaches the current one.
@interface CameraPreviewContainerView : UIView
@property(nonatomic, weak) id<CameraPreviewLayerProvider> provider;
@property(nonatomic, weak) AVCaptureVideoPreviewLayer *attachedLayer;
@property(nonatomic, weak) AVSampleBufferDisplayLayer *attachedFilteredLayer;
@end

@implementation CameraPreviewContainerView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    // The preview must never swallow touches: the app composites its own
    // gesture detectors (tap-to-focus, custom pinch-to-zoom) in Flutter on top
    // of this view. A non-interactive UIView lets every touch fall through to
    // Flutter's gesture arena.
    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor blackColor];
  }
  return self;
}

/// Attach the current preview layer once it's available. Called from
/// layoutSubviews so we recover if the view mounts a frame before the camera
/// session is wired up (the Dart side mounts only after preview-size load, so
/// this is a defensive retry rather than the common path).
- (void)attachPreviewLayerIfNeeded {
  AVCaptureVideoPreviewLayer *layer = [self.provider currentPreviewLayer];
  if (layer == self.attachedLayer) {
    return;
  }
  // The camera (and its preview layer) can be rebuilt across a re-setup while
  // this view persists — the Dart UiKitView is kept alive by a GlobalKey — so
  // swap to the new layer instead of staying stuck on a stale/black one.
  if (self.attachedLayer != nil && self.attachedLayer.superlayer == self.layer) {
    [self.attachedLayer removeFromSuperlayer];
  }
  if (layer == nil) {
    self.attachedLayer = nil;
    return;
  }
  // previewFit: contain on the Dart side → letterbox the full frame so the
  // preview is WYSIWYG and lines up with the geometry the overlays compute
  // from getEffectivPreviewSize. The Flutter box is already sized to the
  // preview's aspect ratio, so ResizeAspect fills it exactly.
  layer.videoGravity = AVLayerVideoGravityResizeAspect;
  // Re-parent defensively in case a previous (remounted) view still hosts it.
  [layer removeFromSuperlayer];
  layer.frame = self.bounds;
  [self.layer addSublayer:layer];
  self.attachedLayer = layer;
}

/// MIN-3655: (de)composites the filtered-preview overlay. Attached above the
/// raw preview layer — which is hidden while filtered so unfiltered pixels
/// can't bleed through the letterbox — and detached (raw preview restored)
/// the moment the provider reports no filter.
- (void)attachFilteredLayerIfNeeded {
  AVSampleBufferDisplayLayer *layer = [self.provider currentFilteredPreviewLayer];
  if (layer == self.attachedFilteredLayer) {
    return;
  }
  if (self.attachedFilteredLayer != nil && self.attachedFilteredLayer.superlayer == self.layer) {
    [self.attachedFilteredLayer removeFromSuperlayer];
  }
  self.attachedFilteredLayer = layer;
  if (layer == nil) {
    self.attachedLayer.hidden = NO;
    return;
  }
  [layer removeFromSuperlayer];
  [self.layer addSublayer:layer];
  self.attachedLayer.hidden = YES;
}

/// The video-data output delivers PORTRAIT-oriented buffers: its connection
/// keeps the default portrait orientation (see initCameraPreview's "lock the
/// preview to portrait like the data-output connection", MIN-2409) — verified
/// on-device: an unrotated filtered layer matches the raw preview in
/// portrait. So no transform is needed while the interface is portrait; the
/// landscape cases (tablets — phones are portrait-locked, MIN-2967) rotate by
/// the device's physical rotation from portrait.
- (void)layoutFilteredLayer {
  AVSampleBufferDisplayLayer *layer = self.attachedFilteredLayer;
  if (layer == nil) {
    return;
  }
  AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
  NSNumber *forced = [self.provider previewOrientationOverride];
  if (forced != nil) {
    orientation = (AVCaptureVideoOrientation)forced.integerValue;
  } else if (self.window.windowScene != nil) {
    orientation = CAMVideoOrientationFromInterface(self.window.windowScene.interfaceOrientation);
  }
  CGFloat angle;
  BOOL quarterTurn;
  switch (orientation) {
    case AVCaptureVideoOrientationLandscapeRight:
      // Interface LandscapeRight = device rotated 90° counter-clockwise from
      // portrait; the portrait-oriented buffer content counter-rotates.
      angle = -M_PI_2;
      quarterTurn = YES;
      break;
    case AVCaptureVideoOrientationLandscapeLeft:
      angle = M_PI_2;
      quarterTurn = YES;
      break;
    case AVCaptureVideoOrientationPortraitUpsideDown:
      angle = M_PI;
      quarterTurn = NO;
      break;
    case AVCaptureVideoOrientationPortrait:
    default:
      angle = 0;
      quarterTurn = NO;
      break;
  }
  CGRect bounds = self.bounds;
  layer.bounds = quarterTurn ? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds;
  layer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
  [layer setAffineTransform:CGAffineTransformMakeRotation(angle)];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self attachPreviewLayerIfNeeded];
  [self attachFilteredLayerIfNeeded];
  if (self.attachedLayer != nil) {
    // Keep the preview layer pinned to our bounds across resize/rotation, with
    // the implicit CALayer animation disabled so it tracks layout instantly.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.attachedLayer.frame = self.bounds;
    // Follow the app's interface orientation so the preview is upright + fills
    // the screen when the window rotates (tablets), and stays portrait when the
    // window is portrait-locked (phones). layoutSubviews fires on every rotation
    // and runs on the main thread, where reading interfaceOrientation is safe.
    // (MIN-2437)
    //
    // Unless the app pinned the preview: under an orientation lock, transient
    // interface-orientation excursions (native croppers/pickers presented above
    // the app) must not re-orient the preview, so the override always wins over
    // the ambient read. (MIN-2646)
    AVCaptureConnection *connection = self.attachedLayer.connection;
    if (connection != nil && connection.isVideoOrientationSupported) {
      NSNumber *forced = [self.provider previewOrientationOverride];
      if (forced != nil) {
        connection.videoOrientation = (AVCaptureVideoOrientation)forced.integerValue;
      } else if (self.window.windowScene != nil) {
        connection.videoOrientation = CAMVideoOrientationFromInterface(self.window.windowScene.interfaceOrientation);
      }
    }
    // Pin + rotate the filtered overlay inside the same no-animation
    // transaction so it tracks resize/rotation in lockstep (MIN-3655).
    [self layoutFilteredLayer];
    [CATransaction commit];
  }
}

- (void)dealloc {
  // Detach the shared layer so it's not left parented to a dead view. The layer
  // itself is owned by SingleCameraPreview and torn down with the session.
  if (_attachedLayer != nil && _attachedLayer.superlayer == self.layer) {
    [_attachedLayer removeFromSuperlayer];
  }
  if (_attachedFilteredLayer != nil && _attachedFilteredLayer.superlayer == self.layer) {
    [_attachedFilteredLayer removeFromSuperlayer];
  }
}

@end

#pragma mark - Platform view

@interface CameraPreviewPlatformView : NSObject <FlutterPlatformView>
- (instancetype)initWithProvider:(id<CameraPreviewLayerProvider>)provider;
@end

@implementation CameraPreviewPlatformView {
  CameraPreviewContainerView *_view;
}

- (instancetype)initWithProvider:(id<CameraPreviewLayerProvider>)provider {
  self = [super init];
  if (self) {
    _view = [[CameraPreviewContainerView alloc] initWithFrame:CGRectZero];
    _view.provider = provider;
    // Filter toggles re-attach layers via layoutSubviews — register so the
    // provider can request that layout when nothing else triggers one.
    [provider registerPreviewContainerView:_view];
  }
  return self;
}

- (UIView *)view {
  return _view;
}

@end

#pragma mark - Factory

@implementation CameraPreviewPlatformViewFactory {
  __weak id<CameraPreviewLayerProvider> _provider;
}

- (instancetype)initWithProvider:(id<CameraPreviewLayerProvider>)provider {
  self = [super init];
  if (self) {
    _provider = provider;
  }
  return self;
}

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id _Nullable)args {
  return [[CameraPreviewPlatformView alloc] initWithProvider:_provider];
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

@end
