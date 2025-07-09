#import <Flutter/Flutter.h>
#import "CamerawesomePlugin.h"
#import "Pigeon.h"
#import "Permissions.h"
#import "SensorsController.h"
#import "SingleCameraPreview.h"
#import "MultiCameraController.h"
#import "Utils/AspectRatio/AspectRatioUtils.h"
#import "Utils/CaptureMode/CaptureModeUtils.h"
#import "Utils/FlashMode/FlashModeUtils.h"
#import "AnalysisController.h"

FlutterEventSink orientationEventSink;
FlutterEventSink videoRecordingEventSink;
FlutterEventSink imageStreamEventSink;
FlutterEventSink physicalButtonEventSink;

@interface CamerawesomePlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *textureRegistry;
@property NSMutableArray<NSNumber *> *texturesIds;
@property SingleCameraPreview *camera;
@property MultiCameraPreview *multiCamera;
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
  [orientationChannel setStreamHandler:instance];
  [imageStreamChannel setStreamHandler:instance];
  [physicalButtonChannel setStreamHandler:instance];
  
  CACameraInterfaceSetup(registrar.messenger, instance);
  CAAnalysisImageUtilsSetup(registrar.messenger, instance);
}

#pragma mark - Camera engine methods

- (void)setupCameraSensors:(NSArray<CAPigeonSensor *> *)sensors aspectRatio:(NSString *)aspectRatio zoom:(NSNumber *)zoom mirrorFrontCamera:(NSNumber *)mirrorFrontCamera enablePhysicalButton:(NSNumber *)enablePhysicalButton flashMode:(NSString *)flashMode captureMode:(NSString *)captureMode enableImageStream:(NSNumber *)enableImageStream exifPreferences:(CAExifPreferences *)exifPreferences videoOptions:(nullable CAVideoOptions *)videoOptions completion:(void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  
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
                                                       captureMode:captureMode
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
    CAPigeonSensor *firstSensor = sensors.firstObject;
    self.camera = [[SingleCameraPreview alloc] initWithCameraSensor:firstSensor.position
                                                       videoOptions:videoOptions != nil ? videoOptions.ios : nil
                                                   recordingQuality:videoOptions != nil ? videoOptions.quality : CAVideoRecordingQualityHighest
                                                       streamImages:[enableImageStream boolValue]
                                                  mirrorFrontCamera:[mirrorFrontCamera boolValue]
                                               enablePhysicalButton:[enablePhysicalButton boolValue]
                                                    aspectRatioMode:aspectRatioMode
                                                        captureMode:captureMode
                                                         completion:completion
                                                      dispatchQueue:dispatch_queue_create("camerawesome.single_preview.dispatchqueue", NULL)];
    
    int64_t textureId = [self->_textureRegistry registerTexture:self.camera.previewTexture];
    
    __weak typeof(self) weakSelf = self;
    self.camera.onPreviewFrameAvailable = ^{
      [weakSelf.textureRegistry textureFrameAvailable:textureId];
    };
    
    [self->_textureRegistry textureFrameAvailable:textureId];
    
    [self.texturesIds addObject:[NSNumber numberWithLongLong:textureId]];
  }
  
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
    dispatch_async(_dispatchQueue, ^{
      if (self.multiCamera != nil) {
        [self->_multiCamera stop];
      } else {
        [self->_camera stop];
      }
    });
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
  }
  return nil;
}

#pragma mark - Permissions methods

- (void)requestPermissionsSaveGpsLocation:(nonnull NSNumber *)saveGpsLocation completion:(nonnull void (^)(NSArray<NSString *> * _Nullable, FlutterError * _Nullable))completion {
  return [CameraPermissionsController requestPermissions:[saveGpsLocation boolValue] completion:completion];
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

- (void)focusOnPointPreviewSize:(nonnull CAPreviewSize *)previewSize x:(nonnull NSNumber *)x y:(nonnull NSNumber *)y androidFocusSettings:(nullable CAAndroidFocusSettings *)androidFocusSettings error:(FlutterError *_Nullable __autoreleasing *_Nonnull)error {
  if (previewSize.width <= 0 || previewSize.height <= 0) {
    *error = [FlutterError errorWithCode:@"INVALID_PREVIEW" message:@"preview size width and height must be set" details:nil];
    return;
  }
  
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) error:error];
  } else {
    [self.camera focusOnPoint:CGPointMake([x floatValue], [y floatValue]) preview:CGSizeMake([previewSize.width floatValue], [previewSize.height floatValue]) error:error];
  }
}

- (void)handleAutoFocusWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  // TODO: to remove ?
}

#pragma mark - Video recording methods

- (nullable FlutterError *)pauseVideoRecording {
  if (self.camera == nil && self.multiCamera == nil) {
    return [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
  }
  
  if (self.camera == nil) {
    return [FlutterError errorWithCode:@"MULTI_CAMERA_UNSUPPORTED" message:@"this feature is currently not supported with multi camera feature" details:nil];
  }
  
  [self.camera pauseVideoRecording];
  return nil;
}

- (void)recordVideoSensors:(nonnull NSArray<CAPigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths withReply:(nonnull void (^)(FlutterError * _Nullable))reply {
  if (self.camera == nil && self.multiCamera == nil) {
    reply([FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera recordVideo:paths completion:reply];
  } else {
    [self.camera recordVideoAtPath:paths.firstObject completion:reply];
  }
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

- (void)setRecordingAudioModeEnableAudio:(nonnull NSNumber *)enableAudio completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
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

- (void)takePhotoSensors:(nonnull NSArray<CAPigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
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
      [self->_camera takePictureAtPath:paths.firstObject completion:completion];
    }
  });
}

- (void)recordVideoSensors:(nonnull NSArray<CAPigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths withReply:(nonnull void (^)(FlutterError * _Nullable))reply {
  if (self.camera == nil && self.multiCamera == nil) {
    reply([FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil]);
    return;
  }
  
  if (self.multiCamera != nil) {
    [self.multiCamera recordVideo:paths completion:reply];
  } else {
    [self.camera recordVideoAtPath:paths.firstObject completion:reply];
  }
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

- (void)setExifPreferencesExifPreferences:(nonnull CAExifPreferences *)exifPreferences completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
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

- (void)setPhotoSizeSize:(nonnull CAPreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
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
  
  [self.camera setPhotoSize:size];
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

- (nonnull NSArray<CAPreviewSize *> *)availableSizesWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil && self.multiCamera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return [NSArray new];
  }
  
  if (self.multiCamera != nil) {
    return [self.multiCamera availableSizes];
  }
  
  return [self.camera availableSizes];
}

- (void)setPreviewSizeSize:(nonnull CAPreviewSize *)size error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
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

- (nullable CAPreviewSize *)getEffectivPreviewSizeIndex:(nonnull NSNumber *)index error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera == nil) {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before start" details:nil];
    return nil;
  }
  return [self.camera getEffectivPreviewSize];
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
  return @(0);
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

- (nullable FlutterError *)receivedImageFromStream {
  [self.camera receivedImageFromStream];
  return nil;
}

- (void)setupImageAnalysisStreamFormat:(nonnull NSString *)format width:(nonnull NSNumber *)width maxFramesPerSecond:(nullable NSNumber *)maxFramesPerSecond autoStart:(nonnull NSNumber *)autoStart {
  [self.camera setupImageAnalysisStream:format width:[width longValue] maxFramesPerSecond:[maxFramesPerSecond doubleValue] autoStart: [autoStart boolValue]];
}

- (void)startAnalysis {
  if (self.camera == nil) {
    return;
  }
  [self.camera startAnalysis];
}

- (void)stopAnalysis {
  if (self.camera == nil) {
    return;
  }
  [self.camera stopAnalysis];
}

- (void)setFilterMatrix:(nonnull NSArray<NSNumber *> *)matrix {
  [self.camera setFilter:matrix];
}

- (void)setFilterMatrix:(nonnull FlutterStandardTypedData *)matrix error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera != nil) {
    [self.camera setFilter:matrix.data];
  } else if (self.multiCamera != nil) {
    [self.multiCamera setFilter:matrix.data];
  }
}

#pragma mark - Sensors methods

- (nonnull NSArray<CAPigeonSensorTypeDevice *> *)getFrontSensorsWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionFront];
}

- (nonnull NSArray<CAPigeonSensorTypeDevice *> *)getBackSensorsWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [SensorsController getSensors:AVCaptureDevicePositionBack];
}

- (void)setSensorSensors:(nonnull NSArray<CAPigeonSensor *> *)sensors {
  if (self.multiCamera != nil) {
    [self.multiCamera setSensors:sensors];
  } else {
    [self.camera setSensors:sensors];
  }
}

#pragma mark - Filter methods

- (void)setFilter:(nonnull ColorMatrix *)matrix error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (self.camera != nil) {
    [self.camera setFilter:matrix.matrix];
  } else if (self.multiCamera != nil) {
    [self.multiCamera setFilter:matrix.matrix];
  } else {
    *error = [FlutterError errorWithCode:@"CAMERA_MUST_BE_INIT" message:@"init must be call before setFilter" details:nil];
  }
}

#pragma mark - Multi camera methods

- (nonnull NSNumber *)isMultiCamSupportedWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [NSNumber numberWithBool:[MultiCameraController isMultiCamSupported]];
}

- (nonnull CAAnalysisImageWrapper *)nv21toJpegNv21Image:(nonnull CAAnalysisImageWrapper *)nv21Image jpegQuality:(nonnull NSNumber *)jpegQuality error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [AnalysisController nv21toJpeg:nv21Image withQuality:[jpegQuality intValue]];
}

- (nonnull CAAnalysisImageWrapper *)yuv420toJpegYuvImage:(nonnull CAAnalysisImageWrapper *)yuvImage jpegQuality:(nonnull NSNumber *)jpegQuality error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [AnalysisController yuv420toJpeg:yuvImage withQuality:[jpegQuality intValue]];
}

- (nonnull CAAnalysisImageWrapper *)yuv420toNv21YuvImage:(nonnull CAAnalysisImageWrapper *)yuvImage error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [AnalysisController yuv420toNv21:yuvImage];
}

- (nonnull CAAnalysisImageWrapper *)bgra8888toJpegBgra8888image:(nonnull CAAnalysisImageWrapper *)bgra8888image jpegQuality:(nonnull NSNumber *)jpegQuality error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [AnalysisController bgra8888toJpeg:bgra8888image withQuality:[jpegQuality intValue]];
}

- (nonnull NSNumber *)isVideoRecordingAndImageAnalysisSupportedSensor:(CAPigeonSensorPosition)sensor error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  return [NSNumber numberWithBool:[self.camera isVideoRecordingAndImageAnalysisSupported:sensor]];
}

@end
