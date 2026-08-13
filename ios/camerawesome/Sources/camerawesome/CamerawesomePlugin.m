#import "CamerawesomePlugin.h"
#import "Pigeon.h"
#import "Permissions.h"
#import "SensorsController.h"
#import "SingleCameraPreview.h"
#import "MultiCameraController.h"
#import "AspectRatioUtils.h"
#import "CaptureModeUtils.h"
#import "FlashModeUtils.h"
#import "AnalysisController.h"
#import "CameraPreviewPlatformView.h"

FlutterEventSink orientationEventSink;
FlutterEventSink videoRecordingEventSink;
FlutterEventSink imageStreamEventSink;
FlutterEventSink physicalButtonEventSink;
FlutterEventSink qrCodeEventSink;

/// Current app interface (window) orientation. Used to report the preview size
/// in the displayed orientation so the Flutter box fills the screen when the
/// window rotates (MIN-2437). Must be called on the main thread.
static UIInterfaceOrientation CAMCurrentInterfaceOrientation(void) {
  UIInterfaceOrientation fallback = UIInterfaceOrientationPortrait;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    if (scene.activationState == UISceneActivationStateForegroundActive) {
      return windowScene.interfaceOrientation;
    }
    fallback = windowScene.interfaceOrientation;
  }
  return fallback;
}

@interface CamerawesomePlugin () <CameraInterface, AnalysisImageUtils, CameraPreviewLayerProvider>
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *textureRegistry;
@property NSMutableArray<NSNumber *> *texturesIds;
@property SingleCameraPreview *camera;
@property MultiCameraPreview *multiCamera;
/// MIN-3655: the mounted preview container, weakly held so a filter toggle
/// can request the layout pass that (de)attaches the filtered overlay.
@property(nonatomic, weak, nullable) UIView *previewContainerView;
/// Survives camera (re)setup: storing the override here means a fresh
/// SingleCameraPreview / MultiCameraPreview created by setupCamera can be
/// initialised with the most recently requested value rather than starting
/// at nil and silently dropping the Dart-side request.
@property(nonatomic, strong, nullable) NSNumber *captureOrientationOverride;
/// Boxed AVCaptureVideoOrientation pinning the *preview* connection while the
/// app's orientation lock is active; nil = follow the interface orientation
/// (default). Read by CameraPreviewContainerView via CameraPreviewLayerProvider;
/// lives here so it survives camera re-setup, like captureOrientationOverride.
/// (MIN-2646)
@property(nonatomic, strong, nullable) NSNumber *previewOrientationOverride;
/// Close-range scan bias requested by the Dart side (MIN-3475). The scanner
/// screens set it in initState — usually before setupCamera has created the
/// SingleCameraPreview — so it lives here and is pushed onto every new camera,
/// like captureOrientationOverride. Cleared by the screens on dispose.
@property(nonatomic, assign) BOOL closeRangeScanModeRequested;
- (instancetype)init:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

// TODO: create a protocol to uniformize multi camera & single camera
// TODO: for multi camera, specify sensor position
// TODO: save all controllers here

@implementation CamerawesomePlugin {
  dispatch_queue_t _dispatchQueue;
  dispatch_queue_t _dispatchQueueAnalysis;
}

- (instancetype)init:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  
  _textureRegistry = registrar.textures;
  
  if (_dispatchQueue == nil) {
    _dispatchQueue = dispatch_queue_create("camerawesome.dispatchqueue", NULL);
  }
  
  if (_dispatchQueueAnalysis == nil) {
    _dispatchQueueAnalysis = dispatch_queue_create("camerawesome.dispatchqueue.analysis", NULL);
  }
  
  return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  CamerawesomePlugin *instance = [[CamerawesomePlugin alloc] init:registrar];
  FlutterEventChannel *orientationChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/orientation"
                                                                      binaryMessenger:[registrar messenger]];
  FlutterEventChannel *imageStreamChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/images"
                                                                      binaryMessenger:[registrar messenger]];
  FlutterEventChannel *physicalButtonChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/physical_button"
                                                                         binaryMessenger:[registrar messenger]];
  // Decoded QR strings from the hardware AVCaptureMetadataOutput reader
  // (MIN-3077). iOS-only; the Android side never registers this channel and
  // keeps its own MLKit analysis-stream path.
  FlutterEventChannel *qrCodesChannel = [FlutterEventChannel eventChannelWithName:@"camerawesome/qrcodes"
                                                                  binaryMessenger:[registrar messenger]];
  [orientationChannel setStreamHandler:instance];
  [imageStreamChannel setStreamHandler:instance];
  [physicalButtonChannel setStreamHandler:instance];
  [qrCodesChannel setStreamHandler:instance];
  
  CameraInterfaceSetup(registrar.messenger, instance);
  AnalysisImageUtilsSetup(registrar.messenger, instance);

  // Native preview path (MIN-2406): host the capture session's
  // AVCaptureVideoPreviewLayer in a PlatformView for a GPU-composited, sharp,
  // full-sensor preview decoupled from the small analysis data output. The Dart
  // preview widget mounts a `UiKitView(viewType: "camerawesome/preview")` on iOS.
  CameraPreviewPlatformViewFactory *previewFactory =
      [[CameraPreviewPlatformViewFactory alloc] initWithProvider:instance];
  [registrar registerViewFactory:previewFactory withId:@"camerawesome/preview"];

  // Preview-orientation lock (MIN-2646): a plain method channel (kept out of
  // pigeon to avoid regenerating the interface for one iOS-only setter). The
  // app pins the preview when its orientation lock is active and clears it for
  // follow-the-window behaviour.
  FlutterMethodChannel *previewOrientationChannel =
      [FlutterMethodChannel methodChannelWithName:@"camerawesome/preview_orientation"
                                  binaryMessenger:[registrar messenger]];
  __weak CamerawesomePlugin *weakInstance = instance;
  [previewOrientationChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if ([call.method isEqualToString:@"setPreviewOrientationOverride"]) {
      [weakInstance setPreviewOrientationOverrideFromString:call.arguments];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];

  // Close-range scan bias for the field-scanner screens (MIN-3475). A plain
  // method channel for the same reason as preview_orientation above: one
  // iOS-only setter isn't worth regenerating the pigeon interface across
  // three platforms. Stored on the plugin so a call arriving before
  // setupCamera still lands on the camera it eventually creates.
  FlutterMethodChannel *closeRangeScanChannel =
      [FlutterMethodChannel methodChannelWithName:@"camerawesome/close_range_scan"
                                  binaryMessenger:[registrar messenger]];
  [closeRangeScanChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if ([call.method isEqualToString:@"setCloseRangeScanMode"]) {
      BOOL enabled = [call.arguments boolValue];
      weakInstance.closeRangeScanModeRequested = enabled;
      [weakInstance.camera setCloseRangeScanMode:enabled];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];
}

/// Maps "portrait"/"landscape" to the AVCaptureVideoOrientation the preview is
/// pinned to; anything else (nil/NSNull) clears the pin. "landscape" maps to
/// LandscapeLeft — the interface orientation the app's landscape window lock
/// allows — so the pinned preview and the locked window agree. Applied to the
/// live connection immediately; the platform view's layoutSubviews keeps
/// enforcing it afterwards. (MIN-2646)
- (void)setPreviewOrientationOverrideFromString:(nullable id)orientation {
  NSNumber *boxed = nil;
  if ([orientation isKindOfClass:[NSString class]]) {
    NSString *lowered = [(NSString *)orientation lowercaseString];
    if ([lowered isEqualToString:@"portrait"]) {
      boxed = @(AVCaptureVideoOrientationPortrait);
    } else if ([lowered isEqualToString:@"landscape"]) {
      boxed = @(AVCaptureVideoOrientationLandscapeLeft);
    }
  }
  self.previewOrientationOverride = boxed;
  if (boxed == nil) {
    // Cleared: the next layout pass (the unlock rotates the window whenever the
    // device disagrees, which triggers one) resumes following the interface.
    return;
  }
  AVCaptureConnection *connection = self.camera.previewLayer.connection;
  if (connection != nil && connection.isVideoOrientationSupported) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    connection.videoOrientation = (AVCaptureVideoOrientation)boxed.integerValue;
    [CATransaction commit];
  }
}

#pragma mark - CameraPreviewLayerProvider

/// The live preview layer for the PlatformView. Single-camera only — the
/// multi-camera path still renders through Flutter textures (floating previews).
- (nullable AVCaptureVideoPreviewLayer *)currentPreviewLayer {
  return self.camera.previewLayer;
}

#pragma mark - Camera engine methods

- (void)setupCameraSensors:(nonnull NSArray<PigeonSensor *> *)sensors aspectRatio:(nonnull NSString *)aspectRatio zoom:(nonnull NSNumber *)zoom mirrorFrontCamera:(nonnull NSNumber *)mirrorFrontCamera enablePhysicalButton:(nonnull NSNumber *)enablePhysicalButton flashMode:(nonnull NSString *)flashMode captureMode:(nonnull NSString *)captureMode enableImageStream:(nonnull NSNumber *)enableImageStream exifPreferences:(nonnull ExifPreferences *)exifPreferences videoOptions:(nullable VideoOptions *)videoOptions completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  
  CaptureModes captureModeType = [CaptureModeUtils captureModeFromCaptureModeType:captureMode];
  if (![CameraPermissionsController checkAndRequestPermission]) {
    completion(nil, [FlutterError errorWithCode:@"MISSING_PERMISSION" message:@"you got to accept all permissions" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0) {
    completion(nil, [FlutterError errorWithCode:@"SENSOR_ERROR" message:@"empty sensors provided, please provide at least 1 sensor" details:nil]);
    return;
  }
  
  // If camera preview exist, dispose it
  if (self.camera != nil) {
    [self.camera dispose];
    self.camera = nil;
  }
  if (self.multiCamera != nil) {
    [self.multiCamera dispose];
    self.multiCamera = nil;
  }
  
  _texturesIds = [NSMutableArray new];
  
  AspectRatio aspectRatioMode = [AspectRatioUtils convertAspectRatio:aspectRatio];
  
  bool multiSensors = [sensors count] > 1;
  if (multiSensors) {
    if (![MultiCameraController isMultiCamSupported]) {
      completion(nil, [FlutterError errorWithCode:@"MULTI_CAM_NOT_SUPPORTED" message:@"multi camera feature is not supported" details:nil]);
      return;
    }
    
    self.multiCamera = [[MultiCameraPreview alloc] initWithSensors:sensors
                                                 mirrorFrontCamera:[mirrorFrontCamera boolValue]
                                              enablePhysicalButton:[enablePhysicalButton boolValue]
                                                   aspectRatioMode:aspectRatioMode
                                                       captureMode:captureModeType
                                                     dispatchQueue:dispatch_queue_create("camerawesome.multi_preview.dispatchqueue", NULL)];
    
    for (int i = 0; i < [sensors count]; i++) {
      int64_t textureId = [self->_textureRegistry registerTexture:self.multiCamera.textures[i]];
      [_texturesIds addObject:[NSNumber numberWithLongLong:textureId]];
    }
    
    __weak typeof(self) weakSelf = self;
    self.multiCamera.onPreviewFrameAvailable = ^(NSNumber * _Nullable i) {
      if (i == nil) {
        return;
      }
      
      NSNumber *textureNumber = weakSelf.texturesIds[[i intValue]];
      [weakSelf.textureRegistry textureFrameAvailable:[textureNumber longLongValue]];
    };
  } else {
    PigeonSensor *firstSensor = sensors.firstObject;
    self.camera = [[SingleCameraPreview alloc] initWithCameraSensor:firstSensor.position
                                                       videoOptions:videoOptions != nil ? videoOptions.ios : nil
                                                   recordingQuality:videoOptions != nil ? videoOptions.quality : VideoRecordingQualityHighest
                                                       streamImages:[enableImageStream boolValue]
                                                  mirrorFrontCamera:[mirrorFrontCamera boolValue]
                                               enablePhysicalButton:[enablePhysicalButton boolValue]
                                                    aspectRatioMode:aspectRatioMode
                                                        captureMode:captureModeType
                                                         completion:completion
                                                      dispatchQueue:dispatch_queue_create("camerawesome.single_preview.dispatchqueue", NULL)];

    // The scanner screens request scan mode before setupCamera runs (their
    // initState precedes camera init) — push the stored request onto the
    // fresh camera (MIN-3475). No-op when it was never set.
    [self.camera setCloseRangeScanMode:self.closeRangeScanModeRequested];

    int64_t textureId = [self->_textureRegistry registerTexture:self.camera.previewTexture];
    
    __weak typeof(self) weakSelf = self;
    self.camera.onPreviewFrameAvailable = ^{
      [weakSelf.textureRegistry textureFrameAvailable:textureId];
    };
    
    [self->_textureRegistry textureFrameAvailable:textureId];

    [self.texturesIds addObject:[NSNumber numberWithLongLong:textureId]];
  }

  // Re-apply any previously requested capture orientation override onto the
  // freshly-built camera(s). Without this the override would be lost across
  // every setupCamera call (e.g. when the user reopens the camera screen)
  // since the property lives on the per-instance preview, not the plugin.
  self.camera.captureOrientationOverride = self.captureOrientationOverride;
  self.multiCamera.captureOrientationOverride = self.captureOrientationOverride;

  // Same race for the EventChannel sinks: onListenWithArguments stores the
  // sink in a file-level global and only forwards it onto the camera if one
  // already exists. On the FIRST camera-screen open, Dart subscribes before
  // setupCamera completes, so the sink dangles in the global and the new
  // camera's MotionController / ImageStreamController / PhysicalButton
  // controller never get it. Seed them from the saved globals here so the
  // first-open subscription receives events too. (ObjC `nil` messaging is a
  // no-op, so this is safe when no listener is active.)
  [self.camera setOrientationEventSink:orientationEventSink];
  [self.camera setImageStreamEvent:imageStreamEventSink];
  [self.camera setPhysicalButtonEventSink:physicalButtonEventSink];
  [self.camera setQrCodeEventSink:qrCodeEventSink];
  [self.multiCamera setOrientationEventSink:orientationEventSink];
  [self.multiCamera setPhysicalButtonEventSink:physicalButtonEventSink];

  completion(@(YES), nil);
}

- (nullable NSNumber *)startWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @(NO);
  }
  
  dispatch_async(_dispatchQueue, ^{
    if (self.multiCamera != nil) {
      [self->_multiCamera start];
    } else {
      [self->_camera start];
    }
  });
  
  return @(YES);
}

- (nullable NSNumber *)stopWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @(NO);
  }

  for (NSNumber *textureId in self->_texturesIds) {
    [self->_textureRegistry unregisterTexture:[textureId longLongValue]];
  }

  // Fully tear down the camera on stop instead of leaving it resident until
  // the next setupCameraSensors: the AVCaptureSession + photo output +
  // preview layer and the 5 Hz CMMotionManager otherwise stay alive the
  // whole time the camera screen is closed (MIN-3057). Safe because start()
  // is always preceded by a fresh setup (see PreparingCameraState on the
  // Dart side), so nothing revives a stopped camera without recreating it.
  // dispose must run on this (platform) thread — it dispatch_syncs onto
  // _dispatchQueue internally, same as the setupCameraSensors teardown path.
  if (self.multiCamera != nil) {
    [self.multiCamera dispose];
    self.multiCamera = nil;
  } else if (self.camera != nil) {
    [self.camera dispose];
    self.camera = nil;
  }

  return @(YES);
}

- (void)refreshWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera refresh];
  } else {
    [self.camera refresh];
  }
}

- (nullable NSNumber *)getPreviewTextureIdCameraPosition:(nonnull NSNumber *)cameraPosition error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  int cameraIndex = [cameraPosition intValue];
  
  if (_texturesIds != nil && [_texturesIds count] >= cameraIndex) {
    return [_texturesIds objectAtIndex:cameraIndex];
  }
  
  return nil;
}

#pragma mark - Event sink methods

- (FlutterError *)onListenWithArguments:(NSString *)arguments eventSink:(FlutterEventSink)eventSink {
  if ([arguments  isEqual: @"orientationChannel"]) {
    orientationEventSink = eventSink;
    
    if (self.camera != nil) {
      [self.camera setOrientationEventSink:orientationEventSink];
    }
    
  } else if ([arguments  isEqual: @"imagesChannel"]) {
    imageStreamEventSink = eventSink;
    
    if (self.camera != nil) {
      [self.camera setImageStreamEvent:imageStreamEventSink];
    }
  } else if ([arguments  isEqual: @"physicalButtonChannel"]) {
    physicalButtonEventSink = eventSink;

    if (self.camera != nil) {
      [self.camera setPhysicalButtonEventSink:physicalButtonEventSink];
    }
  } else if ([arguments  isEqual: @"qrCodesChannel"]) {
    qrCodeEventSink = eventSink;

    if (self.camera != nil) {
      [self.camera setQrCodeEventSink:qrCodeEventSink];
    }
  }

  return nil;
}

- (FlutterError *)onCancelWithArguments:(NSString *)arguments {
  if ([arguments  isEqual: @"orientationChannel"]) {
    orientationEventSink = nil;
    
    if (self.camera != nil && self.camera.motionController != nil) {
      [self.camera setOrientationEventSink:orientationEventSink];
    }
  } else if ([arguments  isEqual: @"imagesChannel"]) {
    imageStreamEventSink = nil;
    
    if (self.camera != nil) {
      [self.camera setImageStreamEvent:imageStreamEventSink];
    }
  } else if ([arguments  isEqual: @"physicalButtonChannel"]) {
    physicalButtonEventSink = nil;

    if (self.camera != nil) {
      [self.camera setPhysicalButtonEventSink:physicalButtonEventSink];
    }
  } else if ([arguments  isEqual: @"qrCodesChannel"]) {
    qrCodeEventSink = nil;

    if (self.camera != nil) {
      [self.camera setQrCodeEventSink:qrCodeEventSink];
    }
  }
  return nil;
}

#pragma mark - Permissions methods

- (void)requestPermissionsSaveGpsLocation:(nonnull NSNumber *)saveGpsLocation completion:(nonnull void (^)(NSArray<NSString *> * _Nullable, FlutterError * _Nullable))completion {
  NSMutableArray *permissions = [NSMutableArray new];
  
  const BOOL cameraGranted = [CameraPermissionsController checkAndRequestPermission];
  if (cameraGranted) {
    [permissions addObject:@"camera"];
  }
  
  bool needToSaveGPSLocation = [saveGpsLocation boolValue];
  if (needToSaveGPSLocation) {
    // TODO: move this to permissions object
    [self.camera.locationController requestWhenInUseAuthorizationOnGranted:^{
      [permissions addObject:@"location"];
      
      completion(permissions, nil);
    } declined:^{
      completion(permissions, nil);
    }];
  }
}

- (nullable NSArray<NSString *> *)checkPermissionsPermissions:(nonnull NSArray<NSString *> *)permissions error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  bool isMicrophonePermissionRequired = [permissions containsObject:@"microphone"];
  bool isCameraPermissionRequired = [permissions containsObject:@"camera"];
  
  bool cameraPermission = isCameraPermissionRequired ? [CameraPermissionsController checkPermission] : NO;
  bool microphonePermission = isMicrophonePermissionRequired ? [MicrophonePermissionsController checkPermission] : NO;
  
  NSMutableArray *grantedPermissions = [NSMutableArray new];
  if (cameraPermission) {
    [grantedPermissions addObject:@"camera"];
  }
  
  if (microphonePermission) {
    [grantedPermissions addObject:@"record_audio"];
  }
  
  return grantedPermissions;
}

- (nullable NSArray<NSString *> *)requestPermissionsWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return @[];
}

#pragma mark - Focus methods

- (void)focusOnPointPreviewSize:(nonnull PreviewSize *)previewSize x:(nonnull NSNumber *)x y:(nonnull NSNumber *)y androidFocusSettings:(nullable AndroidFocusSettings *)androidFocusSettings iosFocusSettings:(nullable IOSFocusSettings *)iosFocusSettings error:(FlutterError *_Nullable __autoreleasing *_Nonnull)error {
  if (previewSize.width <= 0 || previewSize.height <= 0) {
    *error = [FlutterError errorWithCode:@"INVALID_PREVIEW" message:@"preview size width and height must be set" details:nil];
    return;
  }

  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }

  if (self.multiCamera != nil) {
    [self.multiCamera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) iosFocusSettings:iosFocusSettings error:error];
  } else {
    [self.camera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) iosFocusSettings:iosFocusSettings error:error];
  }
}

- (void)handleAutoFocusWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  // TODO: to remove ?
}

#pragma mark - Video recording methods

- (void)pauseVideoRecordingWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera pauseVideoRecording];
}

- (void)recordVideoSensors:(nonnull NSArray<PigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion([FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion([FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0 || paths == nil || [paths count] <= 0) {
    completion([FlutterError errorWithCode:@"PATH_NOT_SET" message:@"at least one path must be set" details:nil]);
    return;
  }
  
  if ([sensors count] != [paths count]) {
    completion([FlutterError errorWithCode:@"PATH_INVALID" message:@"sensors & paths list seems to be different" details:nil]);
    return;
  }
  
  [self.camera recordVideoAtPath:[paths firstObject] completion:completion];
}

- (void)resumeVideoRecordingWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera resumeVideoRecording];
}

- (void)setRecordingAudioModeEnableAudio:(NSNumber *)enableAudio completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion(nil, [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  [self.camera setRecordingAudioMode:[enableAudio boolValue] completion:completion];
}

- (void)stopRecordingVideoWithCompletion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.camera == nil) {
    completion(nil, [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil]);
    return;
  }
  
  dispatch_async(_dispatchQueue, ^{
    [self->_camera stopRecordingVideo:completion];
  });
}

#pragma mark - General methods

- (void)takePhotoSensors:(nonnull NSArray<PigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (sensors == nil || [sensors count] <= 0 || paths == nil || [paths count] <= 0) {
    completion(0, [FlutterError errorWithCode:@"PATH_NOT_SET" message:@"at least one path must be set" details:nil]);
    return;
  }
  
  if ([sensors count] != [paths count]) {
    completion(0, [FlutterError errorWithCode:@"PATH_INVALID" message:@"sensors & paths list seems to be different" details:nil]);
    return;
  }
  
  dispatch_async(_dispatchQueue, ^{
    if (self.multiCamera != nil) {
      [self->_multiCamera takePhotoSensors:sensors paths:paths completion:completion];
    } else {
      [self->_camera takePictureAtPath:[paths firstObject] completion:completion];
    }
  });
}

- (void)setMirrorFrontCameraMirror:(nonnull NSNumber *)mirror error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  BOOL mirrorFrontCamera = [mirror boolValue];
  if (self.multiCamera != nil) {
    [self.multiCamera setMirrorFrontCamera:mirrorFrontCamera error:error];
  } else {
    [self.camera setMirrorFrontCamera:mirrorFrontCamera error:error];
  }
}

- (void)setCaptureModeMode:(nonnull NSString *)mode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  CaptureModes captureMode = [CaptureModeUtils captureModeFromCaptureModeType:mode];
  if (self.multiCamera != nil) {
    if (captureMode == Video) {
      *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"impossible to set video mode when multi camera" details:nil];
      return;
    }
    
    [self.camera setCaptureMode:captureMode error:error];
  } else {
    [self.camera setCaptureMode:captureMode error:error];
  }
}

- (void)setCorrectionBrightness:(nonnull NSNumber *)brightness error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  if (self.multiCamera != nil) {
    [self.multiCamera setBrightness:brightness error:error];
  } else {
    [self.camera setBrightness:brightness error:error];
  }
}

- (void)setExifPreferencesExifPreferences:(ExifPreferences *)exifPreferences completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  if (self.camera == nil && self.multiCamera == nil) {
    completion(nil, [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }

  if (self.multiCamera != nil) {
    [self.multiCamera setExifPreferencesGPSLocation: exifPreferences.saveGPSLocation completion:completion];
  } else {
    [self.camera setExifPreferencesGPSLocation: exifPreferences.saveGPSLocation completion:completion];
  }
}

/// Mirror of CameraAwesomeX.setCaptureOrientationOverride on Android. Maps
/// "portrait" → UIDeviceOrientationPortrait (top-up), "landscape" →
/// UIDeviceOrientationLandscapeRight (home button on the left), anything
/// else (including nil/empty) → clear the override.
///
/// The parsed value is stashed on the plugin itself so it survives any
/// future setupCamera call (which constructs a brand-new
/// SingleCameraPreview / MultiCameraPreview). The value is also applied to
/// whichever camera is already up so callers can flip the override at any
/// time, not only before camera setup.
- (void)setCaptureOrientationOverrideOrientation:(nullable NSString *)orientation error:(FlutterError *_Nullable *_Nonnull)error {
  NSNumber *boxed = nil;
  if ([orientation isKindOfClass:[NSString class]]) {
    NSString *lowered = [orientation lowercaseString];
    if ([lowered isEqualToString:@"portrait"]) {
      boxed = @(UIDeviceOrientationPortrait);
    } else if ([lowered isEqualToString:@"landscape"]) {
      boxed = @(UIDeviceOrientationLandscapeRight);
    }
  }
  self.captureOrientationOverride = boxed;
  // Apply to whichever camera is currently set up; harmless when both are nil
  // (the override is requested ahead of setupCamera — setupCamera will then
  // pick it up from self.captureOrientationOverride).
  self.camera.captureOrientationOverride = boxed;
  self.multiCamera.captureOrientationOverride = boxed;
}

- (void)setFlashModeMode:(nonnull NSString *)mode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (mode == nil || mode.length <= 0) {
    *error = [FlutterError errorWithCode:@"FLASH_MODE_ERROR" message:@"a flash mode NONE, AUTO, ALWAYS must be provided" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  CameraFlashMode flash = [FlashModeUtils flashFromString:mode];
  if (self.multiCamera != nil) {
    [self.multiCamera setFlashMode:flash error:error];
  } else {
    [self.camera setFlashMode:flash error:error];
  }
}

- (void)setPhotoSizeSize:(nonnull PreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (size.width <= 0 || size.height <= 0) {
    *error = [FlutterError errorWithCode:@"NO_SIZE_SET" message:@"width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera setCameraPreset:CGSizeMake([size.width floatValue], [size.height floatValue])];
}

- (void)setAspectRatioAspectRatio:(nonnull NSString *)aspectRatio error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (aspectRatio == nil || aspectRatio.length <= 0) {
    *error = [FlutterError errorWithCode:@"RATIO_NOT_SET" message:@"a ratio must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  AspectRatio aspectRatioMode = [AspectRatioUtils convertAspectRatio:aspectRatio];
  if (self.multiCamera != nil) {
    [self.multiCamera setAspectRatio:aspectRatioMode];
  } else {
    [self.camera setAspectRatio:aspectRatioMode];
  }
}

#pragma mark - Preview methods

- (nullable NSArray<PreviewSize *> *)availableSizesWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return @[];
  }
  
  if (self.multiCamera != nil) {
    return [CameraQualities captureFormatsForDevice:self.multiCamera.devices.firstObject.device];
  } else {
    return [CameraQualities captureFormatsForDevice:self.camera.captureDevice];
  }
}

- (void)setPreviewSizeSize:(nonnull PreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (size.width <= 0 || size.height <= 0) {
    *error = [FlutterError errorWithCode:@"NO_SIZE_SET" message:@"width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera setPreviewSize:CGSizeMake([size.width floatValue], [size.height floatValue]) error:error];
  } else {
    [self.camera setPreviewSize:CGSizeMake([size.width floatValue], [size.height floatValue]) error:error];
  }
}

- (nullable PreviewSize *)getEffectivPreviewSizeIndex:(nonnull NSNumber *)index error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
  }
  
  CGSize previewSize;
  if (self.multiCamera != nil) {
    previewSize = [self.multiCamera getEffectivPreviewSize];
  } else {
    previewSize = [self.camera getEffectivPreviewSize];
  }
  
  // height & width are inverted because the sensor reads out landscape while the
  // preview is portrait. When the interface is landscape the preview follows it
  // (MIN-2437), so report the un-swapped landscape size — otherwise the Flutter
  // box stays a portrait strip and letterboxes instead of filling the screen.
  //
  // When the app pinned the preview (MIN-2646), the connection renders in the
  // pinned orientation no matter what the interface reports — a native cropper
  // above the app can leave the ambient read transiently (or stubbornly) wrong
  // — so the swap decision must follow the pin, keeping the Flutter box in
  // agreement with what the connection actually renders.
  BOOL landscape;
  if (self.previewOrientationOverride != nil) {
    AVCaptureVideoOrientation pinned = (AVCaptureVideoOrientation)self.previewOrientationOverride.integerValue;
    landscape = pinned == AVCaptureVideoOrientationLandscapeLeft || pinned == AVCaptureVideoOrientationLandscapeRight;
  } else {
    landscape = UIInterfaceOrientationIsLandscape(CAMCurrentInterfaceOrientation());
  }
  if (landscape) {
    return [PreviewSize makeWithWidth:@(previewSize.width) height:@(previewSize.height)];
  }
  return [PreviewSize makeWithWidth:@(previewSize.height) height:@(previewSize.width)];
}

#pragma mark - Zoom methods

- (nullable NSNumber *)getMaxZoomWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
  }
  
  if (self.multiCamera != nil) {
    return @([self.multiCamera getMaxZoom]);
  } else {
    return @([self.camera getMaxZoom]);
  }
}

- (nullable NSNumber *)getMinZoomWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return nil;
  }

  // multiCamera doesn't expose a structural min; its first device is treated
  // as the main one (matching getMaxZoom) so fall back to the live floor on
  // that device. The single-camera path below is the one that matters for
  // virtual-device sub-1× zoom.
  if (self.multiCamera != nil) {
    AVCaptureDevice *mainDevice = self.multiCamera.devices.firstObject.device;
    // setSensors: ignores addSensor:'s BOOL result, which can be NO when
    // selectAvailableCamera: returns nil — leaving devices empty. Reading
    // minAvailableVideoZoomFactor off a nil device yields 0.0, which would
    // be reported to Dart as the minimum zoom. Fall back to 1.0× (no
    // sub-1× zoom) when there's no device to query.
    if (mainDevice == nil) {
      return @(1.0);
    }
    return @(mainDevice.minAvailableVideoZoomFactor);
  }
  return @([self.camera getMinZoom]);
}

- (void)setZoomZoom:(nonnull NSNumber *)zoom error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera setZoom:[zoom floatValue] error:error];
  } else {
    [self.camera setZoom:[zoom floatValue] error:error];
  }
}

#pragma mark - Image stream methods

- (void)receivedImageFromStreamWithError:(FlutterError *_Nullable *_Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera receivedImageFromStream];
}

- (void)setupImageAnalysisStreamFormat:(nonnull NSString *)format width:(nonnull NSNumber *)width maxFramesPerSecond:(nullable NSNumber *)maxFramesPerSecond autoStart:(nonnull NSNumber *)autoStart error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:autoStart];

  // Honor the stream's requested pixel format (MIN-3084). Historically iOS
  // ignored [format] and always delivered 32BGRA; "nv21" now switches the
  // data output to biplanar YUV so only the luma plane crosses the bridge.
  // Anything else (including the "bgra8888" the MLKit screens rely on) keeps
  // the 32BGRA behavior.
  InputAnalysisImageFormat requestedFormat = [format isEqualToString:@"nv21"] ? nv21 : bgra8888;
  [self.camera updateRequestedAnalysisFormat:requestedFormat];

  // Honor the stream's requested resolution too (MIN-3475): [width] always
  // arrived over the pigeon bridge but was ignored on iOS, pinning analysis
  // buffers to the built-in 1024 long-edge cap. 0 (the Dart default) keeps
  // that cap; the field scanners ask for 1920 so small 1D barcodes retain
  // enough pixels per module to decode.
  [self.camera updateRequestedAnalysisWidth:[width intValue]];

  // Force a frame rate to improve performance
  [self.camera.imageStreamController setMaxFramesPerSecond:[maxFramesPerSecond floatValue]];

  // Keep the sensor rate pinned across stream (re)configuration — a stopped
  // analysis stream must not leave the session uncapped (MIN-3056).
  [self.camera applyFrameRateCapAsync];
  // Feed the video-data output only when the stream is actually on (MIN-3077).
  [self.camera updateAnalysisConnectionState];
}

- (void)startAnalysisWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:true];

  // Re-pin the frame-rate cap now that the stream is live (MIN-3056).
  [self.camera applyFrameRateCapAsync];
  // Start feeding the video-data output now that analysis is on (MIN-3077).
  [self.camera updateAnalysisConnectionState];
}

- (void)stopAnalysisWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
    return;
  }
  
  [self.camera.imageStreamController setStreamImages:false];

  // Keep the cap applied while only the preview runs — stopping analysis must
  // not release the sensor back to the format's max rate (MIN-3056).
  [self.camera applyFrameRateCapAsync];
  // Stop feeding the video-data output now that analysis is off (MIN-3077).
  [self.camera updateAnalysisConnectionState];
}

- (void)isVideoRecordingAndImageAnalysisSupportedSensor:(PigeonSensorPosition)sensor completion:(void (^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  completion(@(YES), nil);
}

#pragma mark - Sensors methods

- (nullable NSArray<PigeonSensorTypeDevice *> *)getFrontSensorsWithError:(FlutterError *_Nullable *_Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionFront];
}

- (nullable NSArray<PigeonSensorTypeDevice *> *)getBackSensorsWithError:(FlutterError *_Nullable *_Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionBack];
}

- (void)setSensorSensors:(nonnull NSArray<PigeonSensor *> *)sensors error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (sensors != nil && [sensors count] > 1 && self.multiCamera != nil) {
    if ([self.multiCamera.sensors count] != [sensors count]) {
      *error = [FlutterError errorWithCode:@"SENSORS_COUNT_INVALID" message:@"sensors count seems to be different, you can only update current sensors, adding or deleting is impossible for now" details:nil];
      return;
    }
    
    [self.multiCamera setSensors:sensors];
  } else {
    [self.camera setSensor:sensors.firstObject];
  }
}

#pragma mark - Filter methods

/// MIN-3655: iOS doesn't bake the matrix natively (FilterHandler does that in
/// Dart), but the *preview* is filtered natively — the platform view overlays
/// an AVSampleBufferDisplayLayer showing CIColorMatrix-filtered frames while a
/// non-identity matrix is active, so the display never leaves the native path.
- (void)setFilterMatrix:(NSArray<NSNumber *> *)matrix error:(FlutterError *_Nullable *_Nonnull)error {
  BOOL identity = YES;
  if (matrix.count == 20) {
    for (NSUInteger i = 0; i < 20; i++) {
      // Diagonal entries of a 4×5 row-major matrix sit at 0, 6, 12, 18.
      double expected = (i % 6 == 0) ? 1.0 : 0.0;
      if (fabs(matrix[i].doubleValue - expected) > 1e-9) {
        identity = NO;
        break;
      }
    }
  }
  // Single-sensor only: the multicam path already displays Flutter textures,
  // which Dart's ColorFiltered tints directly.
  [self.camera setPreviewColorMatrix:identity ? nil : matrix];
  // Attachment happens in the container's layoutSubviews; a filter toggle on
  // its own triggers no layout, so request one.
  [self.previewContainerView setNeedsLayout];
}

- (nullable AVSampleBufferDisplayLayer *)currentFilteredPreviewLayer {
  return self.camera.previewFilterActive ? self.camera.filteredPreviewLayer : nil;
}

- (void)registerPreviewContainerView:(UIView *)containerView {
  self.previewContainerView = containerView;
}

#pragma mark - Multi camera methods

- (nullable NSNumber *)isMultiCamSupportedWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [NSNumber numberWithBool: [MultiCameraController isMultiCamSupported]];
}

- (void)bgra8888toJpegBgra8888image:(nonnull AnalysisImageWrapper *)bgra8888image jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  dispatch_async(_dispatchQueueAnalysis, ^{
    [AnalysisController bgra8888toJpegBgra8888image:bgra8888image jpegQuality:jpegQuality completion:completion];
  });
}

- (void)nv21toJpegNv21Image:(nonnull AnalysisImageWrapper *)nv21Image jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController nv21toJpegNv21Image:nv21Image jpegQuality:jpegQuality completion:completion];
}

- (void)yuv420toJpegYuvImage:(nonnull AnalysisImageWrapper *)yuvImage jpegQuality:(nonnull NSNumber *)jpegQuality completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController yuv420toJpegYuvImage:yuvImage jpegQuality:jpegQuality completion:completion];
}

- (void)yuv420toNv21YuvImage:(nonnull AnalysisImageWrapper *)yuvImage completion:(nonnull void (^)(AnalysisImageWrapper * _Nullable, FlutterError * _Nullable))completion {
  [AnalysisController yuv420toNv21YuvImage:yuvImage completion:completion];
}

@end
