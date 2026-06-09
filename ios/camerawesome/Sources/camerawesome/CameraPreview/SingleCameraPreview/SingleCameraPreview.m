//
//  CameraPreview.m
//  camerawesome
//
//  Created by Dimitri Dessus on 23/07/2020.
//

#import "SingleCameraPreview.h"

// KVO context for observing the capture device's adjustingFocus/adjustingExposure
// flags (used to know when AF/AE have settled).
static void * const FocusStableContext = (void *)&FocusStableContext;

@implementation SingleCameraPreview {
  dispatch_queue_t _dispatchQueue;
  // Blocks waiting for focus/exposure to settle, plus whether we currently hold
  // KVO registrations on _captureDevice. Mutated only on _dispatchQueue.
  NSMutableArray<void (^)(void)> *_focusStableCompletions;
  BOOL _observingFocusStable;
  // Zoom bounds latched at device-bind time. Reported to Dart in *Apple-style
  // display ratios* (wide lens = 1.0×, ultra-wide = 0.5×) — the same numbers
  // the native Camera app shows. See -cacheDeviceZoomBounds for the
  // videoZoomFactor → display-ratio conversion: on a virtual dual-wide /
  // triple device videoZoomFactor=1.0 is the ultra-wide constituent (Apple
  // UI "0.5×"), so we multiply by ~0.5 (the FOV ratio of wide-to-ultrawide)
  // before exposing the range.
  CGFloat _cachedMinZoom;
  CGFloat _cachedMaxZoom;
  // Multiplier applied to native videoZoomFactor to get the display ratio.
  // 1.0 for a single-sensor device or a virtual device whose widest
  // constituent is the wide-angle; ~0.5 when the ultra-wide is the widest
  // constituent (dual-wide / triple).
  CGFloat _displayRatioConversion;
}

- (instancetype)initWithCameraSensor:(PigeonSensorPosition)sensor
                        videoOptions:(nullable CupertinoVideoOptions *)videoOptions
                    recordingQuality:(VideoRecordingQuality)recordingQuality
                        streamImages:(BOOL)streamImages
                   mirrorFrontCamera:(BOOL)mirrorFrontCamera
                enablePhysicalButton:(BOOL)enablePhysicalButton
                     aspectRatioMode:(AspectRatio)aspectRatioMode
                         captureMode:(CaptureModes)captureMode
                          completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion
                       dispatchQueue:(dispatch_queue_t)dispatchQueue {
  self = [super init];
  
  _completion = completion;
  _dispatchQueue = dispatchQueue;
  
  _previewTexture = [[CameraPreviewTexture alloc] init];
  
  _cameraSensorPosition = sensor;
  _aspectRatio = aspectRatioMode;
  _mirrorFrontCamera = mirrorFrontCamera;
  _videoOptions = videoOptions;
  _recordingQuality = recordingQuality;
  
  // Creating capture session
  _captureSession = [[AVCaptureSession alloc] init];
  _captureVideoOutput = [AVCaptureVideoDataOutput new];
  _captureVideoOutput.videoSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
  [_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
  [_captureVideoOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
  [_captureSession addOutputWithNoConnections:_captureVideoOutput];
  
  [self initCameraPreview:sensor];
  
  [_captureConnection setAutomaticallyAdjustsVideoMirroring:NO];
  if (mirrorFrontCamera && [_captureConnection isVideoMirroringSupported]) {
    [_captureConnection setVideoMirrored:mirrorFrontCamera];
  }
  
  _captureMode = captureMode;
  
  // By default enable auto flash mode
  _flashMode = AVCaptureFlashModeOff;
  _torchMode = AVCaptureTorchModeOff;
  
  _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_captureSession];
  _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
  
  // Controllers init
  _videoController = [[VideoController alloc] init];
  _imageStreamController = [[ImageStreamController alloc] initWithStreamImages:streamImages];
  _motionController = [[MotionController alloc] init];
  _locationController = [[LocationController alloc] init];
  _physicalButtonController = [[PhysicalButtonController alloc] init];
  
  [_motionController startMotionDetection];

  // Keep the capture connection locked to portrait so the preview texture
  // never rotates with the device — mimics the native iOS Camera app.
  __weak typeof(self) weakSelf = self;
  _motionController.onOrientationChanged = ^(UIDeviceOrientation newOrientation) {
    if (weakSelf.captureConnection.isVideoOrientationSupported) {
      [weakSelf.captureConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    }
  };

  if (enablePhysicalButton) {
    [_physicalButtonController startListening];
  }
  
  [self setBestPreviewQuality];
  
  return self;
}

- (void)setAspectRatio:(AspectRatio)ratio {
  _aspectRatio = ratio;
}

/// Set image stream Flutter sink
- (void)setImageStreamEvent:(FlutterEventSink)imageStreamEventSink {
  if (_imageStreamController != nil) {
    [_imageStreamController setImageStreamEventSink:imageStreamEventSink];
  }
}

/// Set orientation stream Flutter sink
- (void)setOrientationEventSink:(FlutterEventSink)orientationEventSink {
  if (_motionController != nil) {
    [_motionController setOrientationEventSink:orientationEventSink];
  }
}

/// Set physical button Flutter sink
- (void)setPhysicalButtonEventSink:(FlutterEventSink)physicalButtonEventSink {
  if (_physicalButtonController != nil) {
    [_physicalButtonController setPhysicalButtonEventSink:physicalButtonEventSink];
  }
}

// TODO: move this to a QualityController
/// Assign the default preview qualities
- (void)setBestPreviewQuality {
  NSArray *qualities = [CameraQualities captureFormatsForDevice:_captureDevice];
  PreviewSize *firstPreviewSize = [qualities count] > 0 ? qualities.lastObject : [PreviewSize makeWithWidth:@3840 height:@2160];
  
  CGSize firstSize = CGSizeMake([firstPreviewSize.width floatValue], [firstPreviewSize.height floatValue]);
  [self setCameraPreset:firstSize];
}

/// Save exif preferences when taking picture
- (void)setExifPreferencesGPSLocation:(bool)gpsLocation completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  _saveGPSLocation = gpsLocation;
  
  if (_saveGPSLocation) {
    [_locationController requestWhenInUseAuthorizationOnGranted:^{
      completion(@(YES), nil);
    } declined:^{
      completion(@(NO), nil);
    }];
  } else {
    completion(@(YES), nil);
  }
}

/// Init camera preview with Front or Rear sensor
- (void)initCameraPreview:(PigeonSensorPosition)sensor {
  // Here we set a preset which wont crash the device before switching to front or back
  [_captureSession setSessionPreset:AVCaptureSessionPresetPhoto];
  
  // Drop any focus-stable KVO registration on the outgoing device before we
  // reassign _captureDevice, and abandon pending waiters (a capture/lock in
  // flight is no longer valid across a sensor switch). Run synchronously on
  // _dispatchQueue so it can't race the KVO/timeout blocks that also mutate
  // this state. initCameraPreview is never itself called from _dispatchQueue,
  // so dispatch_sync cannot deadlock here.
  dispatch_sync(_dispatchQueue, ^{
    [self teardownFocusStableObservation];
    [self->_focusStableCompletions removeAllObjects];
  });

  NSError *error;
  _captureDevice = [AVCaptureDevice deviceWithUniqueID:[self selectAvailableCamera:sensor]];
  _captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice error:&error];
  
  if (error != nil) {
    _completion(nil, [FlutterError errorWithCode:@"CANNOT_OPEN_CAMERA" message:@"can't attach device to input" details:[error localizedDescription]]);
    return;
  }
  
  // Create connection
  _captureConnection = [AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
                                                              output:_captureVideoOutput];
  
  // TODO: works but deprecated...
  //  if ([_captureConnection isVideoMinFrameDurationSupported] && [_captureConnection isVideoMaxFrameDurationSupported]) {
  //    CMTime frameDuration = CMTimeMake(1, 12);
  //    [_captureConnection setVideoMinFrameDuration:frameDuration];
  //    [_captureConnection setVideoMaxFrameDuration:frameDuration];
  //  } else {
  //    NSLog(@"Failed to set frame duration");
  //  }
  
  // Attaching to session
  [_captureSession addInputWithNoConnections:_captureVideoInput];
  [_captureSession addConnection:_captureConnection];
  
  // Creating photo output
  _capturePhotoOutput = [AVCapturePhotoOutput new];
  [_capturePhotoOutput setHighResolutionCaptureEnabled:YES];
  // Allow the modern processing pipeline up to "balanced" (Smart HDR / Deep
  // Fusion). Must be set before the session starts running. Per-shot requests
  // in takePictureAtPath must not exceed this ceiling.
  if (@available(iOS 13.0, *)) {
    _capturePhotoOutput.maxPhotoQualityPrioritization = AVCapturePhotoQualityPrioritizationBalanced;
  }
  [_captureSession addOutput:_capturePhotoOutput];
  
  // Mirror the preview only on portrait mode
  [_captureConnection setAutomaticallyAdjustsVideoMirroring:NO];
  [_captureConnection setVideoMirrored:(_cameraSensorPosition == PigeonSensorPositionFront)];
  [_captureConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];

  // Re-register subject-area change observer for the new device.
  // This fires when the scene changes significantly after a tap-to-focus lock,
  // allowing us to reset back to continuous AF so the next tap starts clean.
  [[NSNotificationCenter defaultCenter] removeObserver:self
      name:AVCaptureDeviceSubjectAreaDidChangeNotification
    object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
      selector:@selector(subjectAreaDidChange:)
          name:AVCaptureDeviceSubjectAreaDidChangeNotification
        object:_captureDevice];

  // Default the live preview to smooth continuous autofocus so it converges
  // gently and doesn't visibly "pump" while hunting before the first tap.
  if ([_captureDevice lockForConfiguration:nil]) {
    if ([_captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
      [_captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
    }
    if ([_captureDevice isSmoothAutoFocusSupported]) {
      [_captureDevice setSmoothAutoFocusEnabled:YES];
    }
    [_captureDevice unlockForConfiguration];
  }

  [self cacheDeviceZoomBounds];
}

/// Latch the zoom range and the videoZoomFactor → display-ratio conversion
/// we'll report to Dart and clamp against inside setZoom:. Dart works
/// entirely in Apple-style display ratios (wide lens = 1.0×, ultra-wide =
/// 0.5×), matching what the native Camera app shows; the conversion lives
/// here so the rest of the codebase doesn't have to know which lens is the
/// virtual device's widest constituent.
- (void)cacheDeviceZoomBounds {
  if (_captureDevice == nil) {
    _displayRatioConversion = 1.0;
    _cachedMinZoom = 1.0;
    _cachedMaxZoom = 1.0;
    return;
  }

  _displayRatioConversion = [self computeDisplayRatioConversion];
  if (_displayRatioConversion <= 0) {
    _displayRatioConversion = 1.0;
  }

  CGFloat nativeMin = _captureDevice.minAvailableVideoZoomFactor;
  CGFloat nativeMax = _captureDevice.activeFormat.videoMaxZoomFactor;
  _cachedMinZoom = nativeMin * _displayRatioConversion;
  _cachedMaxZoom = nativeMax * _displayRatioConversion;
}

/// Conversion factor between Apple's UI labels and the device's
/// videoZoomFactor, derived from `virtualDeviceSwitchOverVideoZoomFactors`
/// — the same numbers Apple's Camera app uses for its chip labels. The
/// alternative of computing it from raw FOV is *physically* more accurate
/// (a wider ultra-wide should map to a smaller "0.5×"), but Apple
/// standardises the labeling to 0.5×/1×/etc. via the switchovers, so we
/// match that to keep the chip values consistent with native Camera.
///
/// On a single-sensor device — or a virtual device whose widest
/// constituent is already the wide-angle (BuiltInDualCamera = wide + tele)
/// — videoZoomFactor=1.0 IS the "1×" view and the conversion is 1.0. On
/// BuiltInDualWideCamera / BuiltInTripleCamera the widest constituent is
/// the ultra-wide, so videoZoomFactor=1.0 corresponds to Apple's "0.5×".
/// The vzf at which the device transitions INTO the wide constituent is
/// the first switchover value (2.0 on every iPhone we ship to), and the
/// conversion is therefore `1.0 / switchover`.
- (CGFloat)computeDisplayRatioConversion {
  if (@available(iOS 13.0, *)) {
    NSArray<AVCaptureDevice *> *constituents = _captureDevice.constituentDevices;
    if (constituents.count == 0) {
      return 1.0;
    }

    // `constituentDevices` is documented as ordered widest-to-narrowest FOV.
    // The wide-angle's index in that array tells us whether anything wider
    // (i.e. the ultra-wide) sits below videoZoomFactor=1.0.
    NSUInteger wideIndex = NSNotFound;
    for (NSUInteger i = 0; i < constituents.count; i++) {
      if ([constituents[i].deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
        wideIndex = i;
        break;
      }
    }
    if (wideIndex == NSNotFound || wideIndex == 0) {
      return 1.0;
    }

    NSArray<NSNumber *> *switchovers = _captureDevice.virtualDeviceSwitchOverVideoZoomFactors;
    if (wideIndex - 1 >= switchovers.count) {
      return 1.0;
    }
    CGFloat wideStartVzf = (CGFloat)[switchovers[wideIndex - 1] doubleValue];
    if (wideStartVzf <= 0) {
      return 1.0;
    }
    return (CGFloat)(1.0 / wideStartVzf);
  }
  return 1.0;
}

- (void)dealloc {
  // Direct (not dispatched): every block queued on _dispatchQueue retains self,
  // so if we're in dealloc none can be in-flight touching this state — and a
  // dispatch_sync here could deadlock if the final release happened on
  // _dispatchQueue. So tearing down inline is both race-free and safe.
  [self teardownFocusStableObservation];
  [self.motionController startMotionDetection];
}

/// Set camera preview size
- (void)setCameraPreset:(CGSize)currentPreviewSize {
  CGSize targetSize = currentPreviewSize;

  // Determine the target size based on the current mode and settings
  if (_captureMode == Video || _videoController.isRecording) {
      // If recording video, prioritize the recording quality setting
      // TODO: Need a way to get the CGSize from the _recordingQuality enum or _videoOptions
      // For now, let's assume a helper function or default high quality if direct mapping isn't obvious.
      // Placeholder: If video options exist, try to use them, otherwise fall back.
      // If no direct mapping, maybe use the highest available preset suitable for video?
      // Or just pass CGSizeZero to let selectVideoCapturePreset pick the best for video?
      // For now, let's pass CGSizeZero to select the best default for video capture.
      if (_videoOptions != nil) {
         // Hypothetical: Get size from VideoOptions quality. Needs actual implementation.
         // targetSize = [CameraQualities sizeFromQuality:_recordingQuality];
         // If no direct mapping, maybe use the highest available preset suitable for video?
         // Or just pass CGSizeZero to let selectVideoCapturePreset pick the best for video?
         // For now, let's pass CGSizeZero to select the best default for video capture.
         targetSize = CGSizeZero; 
      } else if (!CGSizeEqualToSize(currentPreviewSize, CGSizeZero)){
         // Use provided size if valid and no video options
         targetSize = currentPreviewSize;
      } else {
         // Fallback to best quality if no specific size or options given
         targetSize = CGSizeZero;
      }
  } else if (_imageStreamController.streamImages) {
      // If only streaming (not recording), force 720p for potential stability (based on commit history)
      targetSize = CGSizeMake(720, 1280);
  } else if (CGSizeEqualToSize(currentPreviewSize, CGSizeZero)) {
      // If neither recording nor streaming, and no size provided, use best quality
      targetSize = CGSizeZero;
  } 
  // else: Use the non-zero currentPreviewSize passed in.

  NSString *presetSelected;
  if (!CGSizeEqualToSize(CGSizeZero, targetSize)) {
    // Try to get the quality requested based on the determined target size
    presetSelected = [CameraQualities selectVideoCapturePreset:targetSize session:_captureSession device:_captureDevice];
  } else {
    // Compute the best quality supported by the camera device if targetSize is Zero
    presetSelected = [CameraQualities selectVideoCapturePreset:_captureSession device:_captureDevice];
  }

  // Check if the preset needs to be changed
  if (![_captureSession.sessionPreset isEqualToString:presetSelected]) {
    // It is safe to set the preset on a running session, and since this method
    // can be called inside a begin/commit configuration block, we must not stop
    // the session here.
    if ([_captureSession canSetSessionPreset:presetSelected]) {
      [_captureSession setSessionPreset:presetSelected];
      _currentPreset = presetSelected;
    }
  } else {
      _currentPreset = _captureSession.sessionPreset;
  }

  // Use the corrected method name
  _currentPreviewSize = [CameraQualities getSizeForPreset:_currentPreset];

  [_videoController setPreviewSize:_currentPreviewSize];
}

/// Get current video prewiew size
- (CGSize)getEffectivPreviewSize {
  return _currentPreviewSize;
}

// Max zoom in **Apple-style display ratios** (wide = 1×, ultra-wide = 0.5×).
// On iPhone 12 dual-wide this returns ~5.0, matching the native Camera app's
// top end; on a Pro triple it returns ~15.0 (further capped by Dart's UI).
- (CGFloat)getMaxZoom {
  return _cachedMaxZoom > 0 ? _cachedMaxZoom : 1.0;
}

// Min zoom in display ratios. 0.5 on dual-wide / triple (ultra-wide present),
// 1.0 on single-sensor or wide+tele devices. See -cacheDeviceZoomBounds.
- (CGFloat)getMinZoom {
  return _cachedMinZoom > 0 ? _cachedMinZoom : 1.0;
}

/// Dispose camera inputs & outputs
- (void)dispose {
  [self stop];
  [self.physicalButtonController stopListening];
  // Synchronously on _dispatchQueue so teardown can't race in-flight KVO/timeout
  // blocks. dispose runs on the platform thread, never on _dispatchQueue.
  dispatch_sync(_dispatchQueue, ^{
    [self teardownFocusStableObservation];
    [self->_focusStableCompletions removeAllObjects];
  });
  [[NSNotificationCenter defaultCenter] removeObserver:self
      name:AVCaptureDeviceSubjectAreaDidChangeNotification
    object:nil];
  
  for (AVCaptureInput *input in [_captureSession inputs]) {
    [_captureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_captureSession outputs]) {
    [_captureSession removeOutput:output];
  }
}

/// Set preview size resolution
- (void)setPreviewSize:(CGSize)previewSize error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (_videoController.isRecording) {
    *error = [FlutterError errorWithCode:@"PREVIEW_SIZE" message:@"impossible to change preview size, video already recording" details:@""];
    return;
  }
  BOOL sessionIsRunning = _captureSession.isRunning;
  if (sessionIsRunning) {
      [_captureSession stopRunning];
  }
  [self setCameraPreset:previewSize];
  if (sessionIsRunning) {
    dispatch_async(_dispatchQueue, ^{
      [self->_captureSession startRunning];
    });
  }
}

/// Start camera preview
- (void)start {
  dispatch_async(_dispatchQueue, ^{
    [self->_captureSession startRunning];
  });
}

/// Stop camera preview
- (void)stop {
  [_captureSession stopRunning];
}

/// Set sensor between Front & Rear camera
- (void)setSensor:(PigeonSensor *)sensor {
  // Check if the session is running before changing the preset
  BOOL sessionIsRunning = _captureSession.isRunning;
  if (sessionIsRunning) {
      [_captureSession stopRunning];
  }
  // First remove all input & output
  [_captureSession beginConfiguration];
  
  // Only remove camera channel but keep audio
  for (AVCaptureInput *input in [_captureSession inputs]) {
    for (AVCaptureInputPort *port in input.ports) {
      if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
        [_captureSession removeInput:input];
        break;
      }
    }
  }
  // FIX: Changed from setAudioIsDisconnected to setVideoIsDisconnected.
  // VIDEO is what's being switched (brief gap while new camera initializes),
  // not audio. Setting the wrong flag caused audio timestamps to be offset
  // while video timestamps weren't compensated for the gap, causing desync.
  // The videoIsDisconnected flag triggers proper timestamp gap compensation
  // in VideoController.m's captureOutput method.
  [_videoController setVideoIsDisconnected:YES];

  [_captureSession removeOutput:_capturePhotoOutput];
  [_captureSession removeConnection:_captureConnection];
  
  _cameraSensorPosition = sensor.position;
  _captureDeviceId = sensor.deviceId;
  
  // Init the camera preview with the selected sensor
  [self initCameraPreview:sensor.position];

  // Update VideoController with new capture device to re-apply custom FPS if recording
  // This fixes audio/video desync when switching cameras during recording with custom FPS
  [_videoController updateCaptureDevice:_captureDevice];

  [self setBestPreviewQuality];
  
  [_captureSession commitConfiguration];
  if (sessionIsRunning) {
    dispatch_async(_dispatchQueue, ^{
      [self->_captureSession startRunning];
    });
  }
}

/// Set zoom level. `value` is the **Apple-style display ratio** the caller
/// wants (wide lens = 1.0×, ultra-wide = 0.5×, etc.) — the same numbers
/// the native Camera app shows. We translate to the device's native
/// `videoZoomFactor` via the latched conversion (see -cacheDeviceZoomBounds)
/// and clamp to the device's actual reachable range.
///
/// A non-positive `value` is treated as "no zoom requested" and snaps to
/// 1.0× (the wide lens). This preserves the legacy Dart-side default
/// (camerawesome seeds `SensorConfig.currentZoom = 0.0` and pushes it down
/// on every state transition); without the snap the absolute clamp would
/// land it on getMinZoom (0.5× on a dual-wide / triple), opening the
/// camera at ultra-wide instead of the normal wide view.
- (void)setZoom:(float)value error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  CGFloat displayRatio = value > 0 ? (CGFloat)value : 1.0;
  CGFloat conversion = _displayRatioConversion > 0 ? _displayRatioConversion : 1.0;
  CGFloat nativeRequest = displayRatio / conversion;
  CGFloat nativeMin = _captureDevice.minAvailableVideoZoomFactor;
  CGFloat nativeMax = _captureDevice.activeFormat.videoMaxZoomFactor;
  CGFloat clamped = MAX(nativeMin, MIN(nativeRequest, nativeMax));

  NSError *zoomError;
  if ([_captureDevice lockForConfiguration:&zoomError]) {
    @try {
      _captureDevice.videoZoomFactor = clamped;
    } @catch (NSException *exception) {
      // AVFoundation raises NSInvalidArgumentException if a runtime constraint
      // (e.g. distortion correction toggling) momentarily tightens the floor
      // past our clamp. Swallow — the next setZoom: will retry against a
      // value the device accepts, and crashing the camera here would be
      // strictly worse than a single frame at the previous zoom.
    }
    [_captureDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"ZOOM_NOT_SET" message:@"can't set the zoom value" details:[zoomError localizedDescription]];
  }
}

- (void)setBrightness:(NSNumber *)brightness error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  NSError *brightnessError = nil;
  if ([_captureDevice lockForConfiguration:&brightnessError]) {
    AVCaptureExposureMode exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    if ([_captureDevice isExposureModeSupported:exposureMode]) {
      [_captureDevice setExposureMode:exposureMode];
    }
    
    // Map the normalised [0,1] slider value onto a fixed, bounded EV window
    // centred on neutral (0.5 -> 0 EV) instead of spreading it across the
    // device's full [minExposureTargetBias, maxExposureTargetBias] (~+/-8 EV),
    // which is far too steep over the short slider track. This keeps fine
    // adjustment comfortable and gives iOS/Android parity: the same normalised
    // value yields the same EV compensation on both platforms. Keep
    // kBrightnessEvWindow in sync with the Android CameraAwesomeX.setCorrection
    // EV window. See MIN-2312.
    const CGFloat kBrightnessEvWindow = 2.0f; // +/- EV around neutral
    CGFloat targetEv = ([brightness floatValue] - 0.5f) * 2.0f * kBrightnessEvWindow;
    // Clamp to what the device actually supports.
    CGFloat exposureTargetBias = MAX(_captureDevice.minExposureTargetBias,
                                     MIN(_captureDevice.maxExposureTargetBias, targetEv));
    
    [_captureDevice setExposureTargetBias:exposureTargetBias completionHandler:nil];
    [_captureDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"BRIGHTNESS_NOT_SET" message:@"can't set the brightness value" details:[brightnessError localizedDescription]];
  }
}

- (void)setMirrorFrontCamera:(bool)value error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  _mirrorFrontCamera = value;
  
  if ([_captureConnection isVideoMirroringSupported]) {
      [_captureConnection setVideoMirrored:value];
  }
}

/// Set flash mode
- (void)setFlashMode:(CameraFlashMode)flashMode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (![_captureDevice hasFlash]) {
    *error = [FlutterError errorWithCode:@"FLASH_UNSUPPORTED" message:@"flash is not supported on this device" details:@""];
    return;
  }
  
  if (_cameraSensorPosition == PigeonSensorPositionFront) {
    *error = [FlutterError errorWithCode:@"FLASH_UNSUPPORTED" message:@"can't set flash for portrait mode" details:@""];
    return;
  }
  
  NSError *lockError;
  [_captureDevice lockForConfiguration:&lockError];
  if (lockError != nil) {
    *error = [FlutterError errorWithCode:@"FLASH_ERROR" message:@"impossible to change configuration" details:@""];
    return;
  }
  
  switch (flashMode) {
    case None:
      _torchMode = AVCaptureTorchModeOff;
      _flashMode = AVCaptureFlashModeOff;
      break;
    case On:
      _torchMode = AVCaptureTorchModeOff;
      _flashMode = AVCaptureFlashModeOn;
      break;
    case Auto:
      _torchMode = AVCaptureTorchModeAuto;
      _flashMode = AVCaptureFlashModeAuto;
      break;
    case Always:
      _torchMode = AVCaptureTorchModeOn;
      _flashMode = AVCaptureFlashModeOn;
      break;
    default:
      _torchMode = AVCaptureTorchModeAuto;
      _flashMode = AVCaptureFlashModeAuto;
      break;
  }
  [_captureDevice setTorchMode:_torchMode];
  [_captureDevice unlockForConfiguration];
}

/// Map a tap on the preview to AVFoundation's focus/exposure point-of-interest
/// space.
///
/// The incoming [point] is normalised (0..1, origin top-left) over the
/// portrait-oriented preview the user sees. AVFoundation, however, defines
/// `focusPointOfInterest` relative to the sensor's native landscape readout —
/// {0,0} top-left, {1,1} bottom-right with the home button on the right
/// (UIDeviceOrientationLandscapeLeft) — and that space does NOT rotate with the
/// device or the connection's videoOrientation.
///
/// Because we lock the capture connection to portrait (see
/// initWithCameraSensor:), the preview is always the landscape-reference image
/// rotated 90°, so the inverse is the fixed mapping (px, py) -> (py, 1 - px).
/// This matches the portrait case of AVFoundation's own
/// `captureDevicePointOfInterestForPoint:`. The front camera preview is
/// additionally mirrored horizontally, which we undo first so the point lands
/// in the un-mirrored sensor space.
- (CGPoint)focusPointOfInterestForPreviewPoint:(CGPoint)point {
  CGFloat px = point.x;
  CGFloat py = point.y;

  if (_captureConnection != nil && _captureConnection.isVideoMirrored) {
    px = 1.0 - px;
  }

  CGPoint poi = CGPointMake(py, 1.0 - px);
  poi.x = MAX(0.0, MIN(1.0, poi.x));
  poi.y = MAX(0.0, MIN(1.0, poi.y));
  return poi;
}

/// Run `completion` once focus AND exposure have stopped adjusting, or after
/// `timeout` seconds — whichever comes first. If the device is already steady it
/// runs immediately. All bookkeeping happens on _dispatchQueue so the KVO
/// callback and the timeout fallback can't race each other.
- (void)whenFocusStableWithTimeout:(NSTimeInterval)timeout completion:(void (^)(void))completion {
  dispatch_async(_dispatchQueue, ^{
    if (self->_captureDevice == nil ||
        (!self->_captureDevice.isAdjustingFocus && !self->_captureDevice.isAdjustingExposure)) {
      completion();
      return;
    }

    if (self->_focusStableCompletions == nil) {
      self->_focusStableCompletions = [NSMutableArray array];
    }
    [self->_focusStableCompletions addObject:[completion copy]];

    if (!self->_observingFocusStable) {
      self->_observingFocusStable = YES;
      [self->_captureDevice addObserver:self forKeyPath:@"adjustingFocus" options:0 context:FocusStableContext];
      [self->_captureDevice addObserver:self forKeyPath:@"adjustingExposure" options:0 context:FocusStableContext];

      // Safety net: a low-contrast scene may never fully converge, so never
      // block the shutter (or a focus lock) indefinitely.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                     self->_dispatchQueue, ^{
        [self drainFocusStableCompletions];
      });
    }
  });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
  if (context != FocusStableContext) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }
  // KVO fires on AVFoundation's internal thread — hop onto our serial queue so
  // teardown and the timeout fallback are serialized.
  dispatch_async(_dispatchQueue, ^{
    if (self->_captureDevice == nil ||
        (!self->_captureDevice.isAdjustingFocus && !self->_captureDevice.isAdjustingExposure)) {
      [self drainFocusStableCompletions];
    }
  });
}

/// Remove the KVO registrations from the current _captureDevice, if any. Must be
/// called before _captureDevice is reassigned (sensor switch / dispose) so we
/// never removeObserver: from the wrong device.
- (void)teardownFocusStableObservation {
  if (!_observingFocusStable) return;
  _observingFocusStable = NO;
  @try {
    [_captureDevice removeObserver:self forKeyPath:@"adjustingFocus" context:FocusStableContext];
    [_captureDevice removeObserver:self forKeyPath:@"adjustingExposure" context:FocusStableContext];
  } @catch (NSException *exception) { /* already removed */ }
}

/// Tear down observation and fire every pending completion exactly once.
/// Idempotent: the KVO callback and the timeout fallback may both call it.
- (void)drainFocusStableCompletions {
  if (!_observingFocusStable && _focusStableCompletions.count == 0) {
    return;
  }
  [self teardownFocusStableObservation];

  NSArray<void (^)(void)> *pending = [_focusStableCompletions copy];
  [_focusStableCompletions removeAllObjects];
  for (void (^completion)(void) in pending) {
    completion();
  }
}

/// Trigger focus on device at the specific point of the preview
- (void)focusOnPoint:(CGPoint)position preview:(CGSize)preview iosFocusSettings:(nullable IOSFocusSettings *)settings error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  CGPoint poi = [self focusPointOfInterestForPreviewPoint:position];
  NSError *lockError;
  if ([_captureDevice lockForConfiguration:&lockError]) {
    // Focus point
    if ([_captureDevice isFocusPointOfInterestSupported]) {
      [_captureDevice setFocusPointOfInterest:poi];
    }

    // Smooth (gradual) autofocus so continuous AF makes small corrections
    // instead of full lens racks — stops the visible "pumping" on re-taps and
    // matches the native Camera app. Only affects continuous AF.
    if ([_captureDevice isSmoothAutoFocusSupported]) {
      [_captureDevice setSmoothAutoFocusEnabled:YES];
    }

    // Native tap-to-focus has two flavours, selected by IOSFocusSettings:
    //   lockFocus == YES  → one-shot AF + AE that we pin once it settles
    //                       (matches the native Camera app's long-press AE/AF lock).
    //   lockFocus == NO   → focus + meter at the point but stay continuous so
    //                       the lens keeps re-converging as the subject moves
    //                       closer, and the virtual (triple/dual) back camera
    //                       can switch to its ultra-wide/macro constituent. This
    //                       is the native single-tap behaviour and the only one
    //                       that focuses reliably on close-up / macro subjects —
    //                       a hard lock can freeze a still-soft frame (MIN-1556).
    BOOL lockFocus = settings != nil && [settings.lockFocus boolValue];
    BOOL setExposure = settings != nil && [settings.setExposurePoint boolValue];

    // Focus range restriction — apply BEFORE the focus mode so the AF scan
    // honours it from its first frame (matters most for the near/macro range).
    int rangeRestriction = settings != nil ? [settings.autoFocusRangeRestriction intValue] : 0;
    if ([_captureDevice isAutoFocusRangeRestrictionSupported]) {
      if (rangeRestriction == 1) {
        [_captureDevice setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNear];
      } else if (rangeRestriction == 2) {
        [_captureDevice setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionFar];
      } else {
        [_captureDevice setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNone];
      }
    }

    // Focus mode: one-shot lock vs continuous (native single tap)
    if (lockFocus && [_captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
      [_captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
    } else if ([_captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
      [_captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
    }

    // Exposure adjustment (only when requested). In the continuous case keep
    // metering at the point (ContinuousAutoExposure) instead of a one-shot
    // AutoExpose-then-lock, so brightness tracks the subject as focus changes.
    if (setExposure) {
      if ([_captureDevice isExposurePointOfInterestSupported]) {
        [_captureDevice setExposurePointOfInterest:poi];
      }
      if (lockFocus) {
        if ([_captureDevice isExposureModeSupported:AVCaptureExposureModeAutoExpose]) {
          [_captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
        }
      } else if ([_captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        [_captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
      }
    }

    // Subject-area change monitoring in BOTH modes: when the scene at the
    // tapped point changes significantly, subjectAreaDidChange: resets us to
    // centered continuous AF/AE — matching the native Camera app, which drops
    // the focus square and returns to full-scene auto.
    [_captureDevice setSubjectAreaChangeMonitoringEnabled:YES];

    [_captureDevice unlockForConfiguration];

    // Only the lock flavour pins the lens/exposure once the one-shot scan
    // settles. Continuous mode never pins, so it can never freeze a still-soft
    // (e.g. too-close macro) frame the way the old tap-to-lock did. The
    // subject-area observer flips a lock back to centered continuous AF when
    // the scene changes — matching native tap-to-focus.
    if (lockFocus) {
      [self whenFocusStableWithTimeout:1.0 completion:^{
        NSError *pinError;
        if ([self->_captureDevice lockForConfiguration:&pinError]) {
          if ([self->_captureDevice isFocusModeSupported:AVCaptureFocusModeLocked]) {
            [self->_captureDevice setFocusMode:AVCaptureFocusModeLocked];
          }
          if (setExposure && [self->_captureDevice isExposureModeSupported:AVCaptureExposureModeLocked]) {
            [self->_captureDevice setExposureMode:AVCaptureExposureModeLocked];
          }
          [self->_captureDevice unlockForConfiguration];
        }
      }];
    }
  } else {
    *error = [FlutterError errorWithCode:@"FOCUS_ERROR" message:@"impossible to set focus point" details:[lockError localizedDescription]];
  }
}

/// Called by AVFoundation when the scene changes significantly after a tap-to-focus
/// (enabled for both the continuous and the locked flavours).
/// Resets focus and exposure back to continuous auto at the center so the next
/// tap-to-focus starts from a clean state (matching native Camera app behaviour).
- (void)subjectAreaDidChange:(NSNotification *)notification {
  dispatch_async(_dispatchQueue, ^{
    NSError *lockError;
    if ([self->_captureDevice lockForConfiguration:&lockError]) {
      // The device can report focus POI unsupported here (e.g. while the
      // session is re-establishing after an interruption such as a screen
      // lock); setting it unguarded throws NSInvalidArgumentException and
      // kills the app (MIN-2213). Guard like focusOnPoint: does.
      if ([self->_captureDevice isFocusPointOfInterestSupported]) {
        [self->_captureDevice setFocusPointOfInterest:CGPointMake(0.5, 0.5)];
      }
      if ([self->_captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        [self->_captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
      }
      if ([self->_captureDevice isExposurePointOfInterestSupported]) {
        [self->_captureDevice setExposurePointOfInterest:CGPointMake(0.5, 0.5)];
      }
      if ([self->_captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        [self->_captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
      }
      [self->_captureDevice setSubjectAreaChangeMonitoringEnabled:NO];
      [self->_captureDevice unlockForConfiguration];
    }
  });
}

- (void)receivedImageFromStream {
  [self.imageStreamController receivedImageFromStream];
}

/// Get the first available camera on device (front or rear).
///
/// For the back position we prefer the broadest virtual multi-camera device
/// available — triple → dual-wide → dual — so the AVCaptureSession can cross
/// 1× (wide ↔ ultra-wide) and any optical step internally via
/// `setVideoZoomFactor` without rebinding inputs. Rebinds produce a ~150–300 ms
/// black frame plus an auto-exposure re-settle on every crossing; staying on a
/// single virtual device removes both. Falls back to the individual wide-angle
/// for older single-sensor phones, and unconditionally for `.front` (no
/// virtual front-facing equivalents exist).
- (NSString *)selectAvailableCamera:(PigeonSensorPosition)sensor {
  if (_captureDeviceId != nil) {
    return _captureDeviceId;
  }

  AVCaptureDevicePosition cameraPosition = (sensor == PigeonSensorPositionFront)
      ? AVCaptureDevicePositionFront
      : AVCaptureDevicePositionBack;

  NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray array];
  if (cameraPosition == AVCaptureDevicePositionBack) {
    [types addObject:AVCaptureDeviceTypeBuiltInTripleCamera];
    [types addObject:AVCaptureDeviceTypeBuiltInDualWideCamera];
    [types addObject:AVCaptureDeviceTypeBuiltInDualCamera];
  }
  [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];

  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                                                       discoverySessionWithDeviceTypes:types
                                                       mediaType:AVMediaTypeVideo
                                                       position:cameraPosition];

  // Iterate `types` explicitly rather than relying on the discovery session's
  // ordering so the preference is unambiguous regardless of how AVFoundation
  // chooses to sort its devices array.
  for (AVCaptureDeviceType preferredType in types) {
    for (AVCaptureDevice *device in discoverySession.devices) {
      if ([device.deviceType isEqualToString:preferredType]) {
        return [device uniqueID];
      }
    }
  }
  return nil;
}

/// Set capture mode between Photo & Video mode
- (void)setCaptureMode:(CaptureModes)captureMode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  if (_videoController.isRecording) {
    *error = [FlutterError errorWithCode:@"CAPTURE_MODE" message:@"impossible to change capture mode, video already recording" details:@""];
    return;
  }
  
  _captureMode = captureMode;
  
  if (captureMode == Video) {
    [self setUpCaptureSessionForAudioError:^(NSError *audioError) {
      *error = [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"error when trying to setup audio" details:[audioError localizedDescription]];
    }];
  }
}

- (void)refresh {
  if ([_captureSession isRunning]) {
    [self stop];
  }
  [self start];
}

# pragma mark - Camera picture

/// Take the picture into the given path
- (void)takePictureAtPath:(NSString *)path completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  // Don't fire the shutter mid-hunt. If AF/AE are still converging (common right
  // after a tap, or after the scene changes under continuous AF), wait for them
  // to settle — bounded by a short timeout so the shutter stays responsive. This
  // is what prevents the "looked focused a moment later, soft in the shot".
  [self whenFocusStableWithTimeout:0.6 completion:^{
    [self capturePictureAtPath:path completion:completion];
  }];
}

- (void)capturePictureAtPath:(NSString *)path completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  // Use the override if the caller set one via setCaptureOrientationOverride;
  // otherwise fall back to the device's physical orientation as reported by
  // the motion sensor.
  UIDeviceOrientation captureOrientation = _captureOrientationOverride != nil
      ? (UIDeviceOrientation)[_captureOrientationOverride integerValue]
      : _motionController.deviceOrientation;

  // Instanciate camera picture obj
  CameraPictureController *cameraPicture = [[CameraPictureController alloc] initWithPath:path
                                                                             orientation:captureOrientation
                                                                          sensorPosition:_cameraSensorPosition
                                                                         saveGPSLocation:_saveGPSLocation
                                                                       mirrorFrontCamera:_mirrorFrontCamera
                                                                             aspectRatio:_aspectRatio
                                                                              completion:completion
                                                                                callback:^{
    // If flash mode is always on, restore it back after photo is taken
    if (self->_torchMode == AVCaptureTorchModeOn) {
      [self->_captureDevice lockForConfiguration:nil];
      [self->_captureDevice setTorchMode:AVCaptureTorchModeOn];
      [self->_captureDevice unlockForConfiguration];
    }
    
    completion(@(YES), nil);
  }];
  
  // Create settings instance
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
  [settings setFlashMode:_flashMode];
  [settings setHighResolutionPhotoEnabled:YES];

  // Opt into the modern processing pipeline (Smart HDR / Deep Fusion). Balanced
  // keeps shutter latency low while still gaining most of the quality — see
  // maxPhotoQualityPrioritization set on the output in initCameraPreview.
  if (@available(iOS 13.0, *)) {
    settings.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationBalanced;
  }

  [_capturePhotoOutput capturePhotoWithSettings:settings
                                       delegate:cameraPicture];
  
}

# pragma mark - Camera video
/// Record video into the given path
- (void)recordVideoAtPath:(NSString *)path completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (!_videoController.isRecording) {
    [_videoController recordVideoAtPath:path captureDevice:_captureDevice orientation:_motionController.deviceOrientation audioSetupCallback:^{
      [self setUpCaptureSessionForAudioError:^(NSError *error) {
        completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"error when trying to setup audio" details:[error localizedDescription]]);
      }];
    } videoWriterCallback:^{
      if (self->_videoController.isAudioEnabled) {
        [self->_audioOutput setSampleBufferDelegate:self queue:self->_dispatchQueue];
      }
      [self->_captureVideoOutput setSampleBufferDelegate:self queue:self->_dispatchQueue];
      
      completion(nil);
    } options:_videoOptions quality: _recordingQuality completion:completion];
  } else {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"already recording video" details:@""]);
  }
}

/// Pause video recording
- (void)pauseVideoRecording {
  [_videoController pauseVideoRecording];
}

/// Resume video recording after being paused
- (void)resumeVideoRecording {
  [_videoController resumeVideoRecording];
}

/// Stop recording video
- (void)stopRecordingVideo:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (_videoController.isRecording) {
    [_videoController stopRecordingVideo:completion];
  } else {
    completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"video is not recording" details:@""]);
  }
}

/// Set audio recording mode
- (void)setRecordingAudioMode:(bool)isAudioEnabled completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  if (_videoController.isRecording) {
    completion(@(NO), [FlutterError errorWithCode:@"CHANGE_AUDIO_MODE" message:@"impossible to change audio mode, video already recording" details:@""]);
    return;
  }
  
  [_captureSession beginConfiguration];
  [_videoController setIsAudioEnabled:isAudioEnabled];
  [_videoController setIsAudioSetup:NO];
  [_videoController setAudioIsDisconnected:YES];
  
  // Only remove audio channel input but keep video
  for (AVCaptureInput *input in [_captureSession inputs]) {
    for (AVCaptureInputPort *port in input.ports) {
      if ([[port mediaType] isEqual:AVMediaTypeAudio]) {
        [_captureSession removeInput:input];
        break;
      }
    }
  }
  // Only remove audio channel output but keep video
  [_captureSession removeOutput:_audioOutput];
  
  if (_videoController.isRecording) {
    [self setUpCaptureSessionForAudioError:^(NSError *error) {
      completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"error when trying to setup audio" details:[error localizedDescription]]);
    }];
  }
  
  [_captureSession commitConfiguration];
  completion(@(YES), nil);
}

# pragma mark - Audio
/// Setup audio channel to record audio
- (void)setUpCaptureSessionForAudioError:(nonnull void (^)(NSError *))error {
  NSError *audioError = nil;
  // Create a device input with the device and add it to the session.
  // Setup the audio input.
  AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice
                                                                           error:&audioError];
  if (audioError) {
    error(audioError);
  }
  
  // Setup the audio output.
  _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
  
  if ([_captureSession canAddInput:audioInput]) {
    [_captureSession addInput:audioInput];
    
    if ([_captureSession canAddOutput:_audioOutput]) {
      [_captureSession addOutput:_audioOutput];
      [_videoController setIsAudioSetup:YES];
    } else {
      [_videoController setIsAudioSetup:NO];
    }
  }
}

# pragma mark - Camera Delegates

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  if (output == _captureVideoOutput) {
    [self.previewTexture updateBuffer:sampleBuffer];
    if (_onPreviewFrameAvailable) {
      _onPreviewFrameAvailable();
    }

    // Send to image stream controller if enabled
    if (_imageStreamController.streamImages) {
        [_imageStreamController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection orientation:_motionController.deviceOrientation];
    }

    // Send to video recording controller if recording
    if (_videoController.isRecording) {
      // Ensure VideoController's captureOutput can handle being called multiple times for the same timestamp (once for video, once for audio)
      // or ensure it only processes the video buffer here.
      // Assuming it can differentiate based on 'output' or buffer type.
      [_videoController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection captureVideoOutput:_captureVideoOutput];
    }
  } else if (output == _audioOutput) {
    // Send audio buffers only to video recording controller if recording & audio enabled
    if (_videoController.isRecording && _videoController.isAudioEnabled) {
      [_videoController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection captureVideoOutput:nil]; // Pass nil for video output for audio
    }
  }
}

@end
