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

@interface SingleCameraPreview ()
/// Safely applies the analysis pixel format (optionally at a fixed
/// width/height) to the analysis data output — 32BGRA by default, or the
/// 420f/420v luma-friendly YUV formats when the stream requested nv21
/// (MIN-3084) — guarded so an unsupported pixel format / aspect never crashes
/// the camera (MIN-2667). See the implementation for details.
- (void)applyAnalysisPixelFormatWithWidth:(int32_t)width height:(int32_t)height;
/// Enables QR detection on the hardware metadata output when the connection
/// offers it (MIN-3077). See the implementation for the mid-configuration guard.
- (void)applyQrMetadataTypes;
/// Enables the analysis (video-data) connection only while it's consumed
/// (analysis stream on, or recording) — otherwise the idle session stops
/// producing dropped frames (MIN-3077). See the implementation.
- (void)updateAnalysisConnectionState;
/// Re-asserts smooth continuous autofocus (+ the MIN-3071 constituent-switching
/// restriction). Must run after every -activeFormat/preset change, which resets
/// focusMode to the format default — otherwise the scan preview loses AF
/// (MIN-3316). See the implementation.
- (void)applyContinuousAutoFocusPolicy;
@end

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
  // Connection feeding the native AVCaptureVideoPreviewLayer (MIN-2406). The
  // session adds inputs/outputs with -addOutputWithNoConnections, so the
  // preview layer never auto-connects — we wire it explicitly and rebuild it
  // on every sensor switch (initCameraPreview:), parallel to _captureConnection.
  AVCaptureConnection *_previewConnection;
  // Hardware QR reader (MIN-3077). AVFoundation's ISP-accelerated
  // machine-readable-code detector, added alongside the photo output in
  // initCameraPreview: and torn down / recreated on every sensor switch. Lets
  // us scan QR codes without running the CPU image-analysis stream.
  AVCaptureMetadataOutput *_metadataOutput;
  // While recording, the analysis output must deliver 32BGRA regardless of the
  // requested analysis format: VideoController appends these same buffers
  // through an AVAssetWriterInputPixelBufferAdaptor pinned to 32BGRA, so a YUV
  // buffer would fail the writer (MIN-3084). Set for the duration of a
  // recording; the nv21 format is restored when recording stops.
  BOOL _forceBGRAAnalysisForRecording;
  // Whether Dart last asked the session to run (set in -start, cleared in
  // -stop). Gates the MIN-3440 session-death recovery so an auto-restart can
  // never resurrect a deliberately stopped session (dispose, screen closed).
  BOOL _shouldBeRunning;
  // Close-range scan bias (MIN-3475), set only by the field-scanner screens.
  // Flips applyContinuousAutoFocusPolicy from the MIN-3071 restricted
  // constituent switching to `.auto`, so a triple-camera device can do its
  // focus-driven hop to the ultra-wide/macro constituent — without it the
  // wide lens (min focus ~20cm on the Pros) can never sharpen a small code
  // held close, and the scanner sits permanently defocused.
  BOOL _closeRangeScanMode;
  // Long edge (px) the Dart analysis stream requested (MIN-3475); 0 means
  // "no request" and keeps applyAnalysisOutputDownscale's built-in 1024 cap.
  int32_t _requestedAnalysisLongEdge;
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

  // Session-death recovery (MIN-3440): a running session can die out from
  // under the app — mediaserverd crashing (media services reset), a thermal
  // system-pressure shutdown, or another foreground app claiming the camera —
  // and AVFoundation reports it only through these notifications. Without
  // observers the native preview freezes on its last frame forever (turning
  // black on the next connection change) and only killing the app recovers.
  // Delivered on an arbitrary thread; handlers hop to _dispatchQueue.
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(sessionRuntimeError:)
                                               name:AVCaptureSessionRuntimeErrorNotification
                                             object:_captureSession];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(sessionWasInterrupted:)
                                               name:AVCaptureSessionWasInterruptedNotification
                                             object:_captureSession];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(sessionInterruptionEnded:)
                                               name:AVCaptureSessionInterruptionEndedNotification
                                             object:_captureSession];

  _captureVideoOutput = [AVCaptureVideoDataOutput new];
  // Default analysis format. Must be set explicitly BEFORE the baseline
  // pixel-format call below: the enum's zero value is yuv_420_888, so a
  // zero-initialized ivar would silently request YUV for every camera that
  // never calls setupImageAnalysisStream — i.e. all the MLKit QR screens,
  // which require 32BGRA on iOS (MIN-3084).
  _requestedAnalysisFormat = bgra8888;
  // Baseline analysis pixel format. -setVideoSettings: throws
  // NSInvalidArgumentException ("Unsupported pixel format type") if the format
  // is not currently in the output's availableVideoCVPixelFormatTypes, so
  // guard it and never let camera setup crash (MIN-2667).
  [self applyAnalysisPixelFormatWithWidth:0 height:0];
  [_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
  // Deliver frames on the serial capture queue, NOT the main queue (MIN-2747):
  // with the delegate on main, the analysis stream's per-frame BGRA copy +
  // event-channel serialization all ran on the UI thread. Every consumer is
  // queue-agnostic — ImageStreamController hops to the main queue itself for
  // the Flutter sink, and recording already swapped the delegate to this same
  // queue (see recordVideoAtPath).
  [_captureVideoOutput setSampleBufferDelegate:self queue:_dispatchQueue];
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
  
  // Native preview layer (MIN-2406). Created WITHOUT an automatic connection —
  // the session uses -addInputWithNoConnections, so we form the preview
  // connection explicitly in -attachPreviewLayerConnection. videoGravity is
  // ResizeAspect to match the app's `previewFit: contain` (WYSIWYG, letterboxed)
  // so the Flutter overlays line up with getEffectivPreviewSize.
  _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSessionWithNoConnection:_captureSession];
  _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  [self attachPreviewLayerConnection];
  
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

  // Don't feed the video-data output while nothing consumes it (MIN-3077).
  [self updateAnalysisConnectionState];

  return self;
}

- (void)setAspectRatio:(AspectRatio)ratio {
  if (_aspectRatio == ratio) {
    return;
  }
  _aspectRatio = ratio;
  // The 4:3 and 16:9 session configs differ (tuned 4:3 device format vs 1080p
  // preset — MIN-3098), so re-pick the config when the ratio actually changes.
  // This also catches the app's initial ratio push right after setup (init runs
  // with the enum default 4:3 before Dart sends the persisted ratio). Skip
  // while recording: the writer is pinned to the current format, matching
  // setPreviewSize's recording guard.
  if (!_videoController.isRecording) {
    [self setBestPreviewQuality];
  }
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
  // Pre-iOS-16 still-resolution ceiling. On iOS 16+ the ceiling is raised to the
  // active format's full sensor size per-format in -applyMaxPhotoDimensions
  // (MIN-3066); this flag stays as the fallback for older iOS.
  [_capturePhotoOutput setHighResolutionCaptureEnabled:YES];
  // Ceiling for the modern processing pipeline (Smart HDR / Deep Fusion). Must
  // be set before the session starts running, and per-shot requests in
  // takePictureAtPath must not exceed it. Memory-gated: constrained iPads cap at
  // Speed to avoid the full-sensor Deep-Fusion jetsam (MIN-3176) — see
  // -preferredPhotoQualityPrioritization.
  if (@available(iOS 13.0, *)) {
    _capturePhotoOutput.maxPhotoQualityPrioritization = [self preferredPhotoQualityPrioritization];
  }
  [_captureSession addOutput:_capturePhotoOutput];

  // Hardware QR reader (MIN-3077). Added like the photo output: the video input
  // above was added with -addInputWithNoConnections, but -addOutput: still forms
  // the metadata connection to the video port (the photo output relies on the
  // same auto-connection). Detection runs on AVFoundation's ISP-accelerated
  // machine-readable-code path — no per-frame CPU pixel work — so the app no
  // longer needs the image-analysis stream running just to scan QR codes.
  // Recreated on every sensor switch (torn down in setSensor: / dispose).
  _metadataOutput = [[AVCaptureMetadataOutput alloc] init];
  if ([_captureSession canAddOutput:_metadataOutput]) {
    [_captureSession addOutput:_metadataOutput];
    [_metadataOutput setMetadataObjectsDelegate:self queue:_dispatchQueue];
    [self applyQrMetadataTypes];
  } else {
    _metadataOutput = nil;
  }

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

  // Default the live preview to smooth continuous autofocus. Setting
  // -activeFormat later (in -setCameraPreset) resets focusMode to the format
  // default, so this policy must be re-applied after every format/preset change
  // — otherwise the scan preview can't focus on a QR/barcode (MIN-3316).
  [self applyContinuousAutoFocusPolicy];

  [self cacheDeviceZoomBounds];

  // Rebuild the native preview-layer connection for the (possibly new) input.
  // On the very first call _previewLayer doesn't exist yet (it's created right
  // after, in initWithCameraSensor:) so this is a no-op then; on a sensor
  // switch it reconnects the layer to the new device's video port.
  [self attachPreviewLayerConnection];
}

#pragma mark - QR metadata delegate (MIN-3077)

/// Enable QR detection on the metadata output when the live connection offers
/// it. Guarded because -setMetadataObjectTypes: throws if a type isn't in
/// availableMetadataObjectTypes, and that set can be transiently empty while a
/// sensor switch is mid-configuration — so this is also re-applied after the
/// commit in setSensor:.
- (void)applyQrMetadataTypes {
  if (_metadataOutput == nil) {
    return;
  }
  if ([_metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
    _metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
  }
}

/// Delivered by the hardware machine-readable-code reader on _dispatchQueue.
/// Forwards the first decoded QR string to Dart over the "camerawesome/qrcodes"
/// event channel. The sink is only ever touched on the main thread (matching
/// the analysis stream's contract), so hop there before calling it.
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection {
  // Only touch qrCodeEventSink on the main queue (it's set/cleared there): this
  // delegate runs on _dispatchQueue, so the sink nil-check lives inside the
  // main-queue block below, not here (CodeRabbit, MIN-3077).
  if (metadataObjects.count == 0) {
    return;
  }
  NSString *value = nil;
  for (AVMetadataObject *object in metadataObjects) {
    if (![object isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
      continue;
    }
    AVMetadataMachineReadableCodeObject *code = (AVMetadataMachineReadableCodeObject *)object;
    if ([code.type isEqualToString:AVMetadataObjectTypeQRCode] && code.stringValue.length > 0) {
      value = code.stringValue;
      break;
    }
  }
  if (value == nil) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterEventSink sink = self.qrCodeEventSink;
    if (sink != nil) {
      sink(value);
    }
  });
}

/// Wire (or rewire) the native AVCaptureVideoPreviewLayer to the current video
/// input port (MIN-2406). The session is built with -addInputWithNoConnections
/// / -addOutputWithNoConnections, so no preview connection is formed
/// automatically; we create one explicitly. Idempotent and safe to call on
/// every sensor switch — any stale connection is removed first (and is in any
/// case auto-removed by the session when its input is removed).
- (void)attachPreviewLayerConnection {
  if (_previewLayer == nil || _captureVideoInput == nil) {
    return;
  }

  if (_previewConnection != nil) {
    if ([_captureSession.connections containsObject:_previewConnection]) {
      [_captureSession removeConnection:_previewConnection];
    }
    _previewConnection = nil;
  }

  AVCaptureInputPort *videoPort = nil;
  for (AVCaptureInputPort *port in _captureVideoInput.ports) {
    if ([port.mediaType isEqual:AVMediaTypeVideo]) {
      videoPort = port;
      break;
    }
  }
  if (videoPort == nil) {
    return;
  }

  AVCaptureConnection *connection = [AVCaptureConnection connectionWithInputPort:videoPort
                                                              videoPreviewLayer:_previewLayer];
  if ([_captureSession canAddConnection:connection]) {
    [_captureSession addConnection:connection];
    _previewConnection = connection;

    // Lock the preview to portrait like the data-output connection so it never
    // reorients with the device — the overlay UI rotates in place instead
    // (MIN-2409 "rotate only the UI, not the view").
    if (connection.isVideoOrientationSupported) {
      connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    // Mirror the front-camera preview only when mirroring is enabled, and keep
    // it in sync with setMirrorFrontCamera: (which also updates this connection).
    if (connection.isVideoMirroringSupported) {
      connection.automaticallyAdjustsVideoMirroring = NO;
      connection.videoMirrored = (_cameraSensorPosition == PigeonSensorPositionFront) && _mirrorFrontCamera;
    }
  }
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
  // Stop, don't start (MIN-2747): the upstream code called startMotionDetection
  // here, and the CMMotionManager handler strongly retains the MotionController
  // — so every camera teardown leaked a permanent 5 Hz device-motion (gyro)
  // subscription. Stopping releases the handler and breaks that retain cycle.
  [self.motionController stopMotionDetection];
}

/// Ceiling (sensor-native width, px) for the 4:3 preview device format.
///
/// MIN-2406 decouples the streams: the on-screen preview is the GPU-composited
/// AVCaptureVideoPreviewLayer (no CPU pixel buffers, and the iOS preview Texture
/// is no longer fed — see captureOutput:), while the analysis data output is
/// capped independently via -applyAnalysisOutputDownscale. The GPU layer renders
/// the session's active format, so a higher format = a sharper preview at no CPU
/// cost.
///
/// 1920 (~2.7MP, ≈1080p) is well above the old 1280 stopgap for a noticeably
/// sharper 4:3 preview, while staying bounded: even if a device ignores the
/// data-output downscale, the analysis stream tops out at this format size
/// rather than the full ~12MP sensor. Raise further (toward full sensor /
/// AVCaptureSessionPresetPhoto) only after confirming with Instruments that the
/// downscale holds the analysis buffers small on the target device.
static const int32_t kPreviewFourThreeMaxWidth = 1920;

/// Between two same-sized formats, prefer the lower-power variant: sensor-binned
/// readout first, then the lowest max frame rate. iOS lists several formats per
/// resolution (binned/unbinned, 30/60fps variants); picking by width alone can
/// land on a variant whose default rate doubles the sensor/ISP work for an
/// identical-looking stream (MIN-2747).
static BOOL SCPFormatIsLowerPower(AVCaptureDeviceFormat *a, AVCaptureDeviceFormat *b) {
  if (a.isVideoBinned != b.isVideoBinned) {
    return a.isVideoBinned;
  }
  double aMaxFps = a.videoSupportedFrameRateRanges.firstObject.maxFrameRate;
  double bMaxFps = b.videoSupportedFrameRateRanges.firstObject.maxFrameRate;
  return aMaxFps < bMaxFps;
}

/// The widest still photo the format can capture, in pixels. Full-sensor stills
/// come from formats whose photo pipeline reaches the sensor's native size;
/// binned / low-power streaming formats cap it well below (e.g. ~2016 wide).
/// iOS 16+ gives the definitive set via -supportedMaxPhotoDimensions (we take
/// the largest entry); older iOS uses the deprecated
/// -highResolutionStillImageDimensions. Used to pick a streaming format that can
/// still deliver a full-resolution photo (MIN-3066).
static int32_t SCPFormatMaxPhotoWidth(AVCaptureDeviceFormat *format) {
  if (@available(iOS 16.0, *)) {
    int32_t widest = 0;
    for (NSValue *value in format.supportedMaxPhotoDimensions) {
      CMVideoDimensions d = {0, 0};
      [value getValue:&d size:sizeof(d)];
      if (d.width > widest) {
        widest = d.width;
      }
    }
    if (widest > 0) {
      return widest;
    }
  }
  return format.highResolutionStillImageDimensions.width;
}

/// The 4:3 device format that drives the streaming preview + analysis. Ranked:
///   1. largest still-capture width — so the still isn't capped below the
///      sensor while this format is active (MIN-3066); binned/low-power formats
///      lose here because they can't reach full sensor,
///   2. largest video width up to [kPreviewFourThreeMaxWidth] for a sharp
///      preview layer,
///   3. lower-power variant among otherwise-equal formats (MIN-2747) — so the
///      thermal preference survives as a tiebreak, not a hard rule.
/// Video width stays capped at [kPreviewFourThreeMaxWidth] (streaming/analysis
/// memory + heat); only the still ceiling is allowed to reach the sensor, via
/// -applyMaxPhotoDimensions. Returns nil if the device exposes no 4:3 format in
/// range, in which case the caller falls back to the 640x480 preset.
- (AVCaptureDeviceFormat *)bestStreamingFourThreeFormat {
  AVCaptureDeviceFormat *best = nil;
  int32_t bestVideoWidth = 0;
  int32_t bestStillWidth = 0;
  for (AVCaptureDeviceFormat *format in _captureDevice.formats) {
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    if (dims.width * 3 != dims.height * 4) continue;                       // 4:3 only
    if (dims.width <= 640 || dims.width > kPreviewFourThreeMaxWidth) continue;

    int32_t stillWidth = SCPFormatMaxPhotoWidth(format);
    BOOL better;
    if (best == nil) {
      better = YES;
    } else if (stillWidth != bestStillWidth) {
      better = stillWidth > bestStillWidth;
    } else if (dims.width != bestVideoWidth) {
      better = dims.width > bestVideoWidth;
    } else {
      better = SCPFormatIsLowerPower(format, best);
    }
    if (better) {
      best = format;
      bestVideoWidth = dims.width;
      bestStillWidth = stillWidth;
    }
  }
  return best;
}

static int32_t SCPGreatestCommonDivisor(int32_t a, int32_t b) {
  a = (a < 0) ? -a : a;
  b = (b < 0) ? -b : b;
  while (b != 0) {
    int32_t t = b;
    b = a % b;
    a = t;
  }
  return a == 0 ? 1 : a;
}

/// Cap the AVCaptureVideoDataOutput's delivered buffers — independent of the
/// (now higher-res) session format that feeds the preview layer (MIN-2406).
/// This is what keeps MLKit cheap and prevents the open/capture OOM: the GPU
/// preview can be full-sensor sharp while analysis frames stay small.
///
/// CRITICAL: -setVideoSettings: throws (NSInvalidArgumentException) unless the
/// width/height EXACTLY maintain the device's *current* activeFormat aspect
/// ratio. The requested capture ratio (_aspectRatio) is NOT a safe proxy — a
/// preset/format set can fail or lag, leaving the device on a different-aspect
/// format. So we read the real activeFormat, reduce its dimensions to lowest
/// terms, and emit an integer multiple of that ratio: the aspect then matches
/// by construction, whatever format is actually active. Sensor-native
/// (landscape) dims; the portrait capture connection rotates them on delivery,
/// as before. We only downscale (never upscale), so a format already smaller
/// than the target long edge (e.g. the 640x480 fallback) is left untouched.
- (void)applyAnalysisOutputDownscale {
  if (_captureVideoOutput == nil || _captureDevice == nil) {
    return;
  }
  AVCaptureDeviceFormat *format = _captureDevice.activeFormat;
  if (format == nil) {
    return;
  }
  CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
  if (dims.width <= 0 || dims.height <= 0) {
    return;
  }

  // Long-edge cap for the analysis buffers. 1024 for Android parity — the app
  // requests nv21 analysis frames at width 1024 there — so both platforms feed
  // the same-sized frames downstream (MIN-3056). A stream that asked for more
  // via setupImageAnalysisStream's width (small 1D barcodes need ~2x the
  // detail a QR does, MIN-3475) raises the cap; the active format is still
  // the hard ceiling since we only ever downscale.
  const int32_t kTargetLongEdge = 1024;
  int32_t targetLongEdge = _requestedAnalysisLongEdge > 0 ? _requestedAnalysisLongEdge : kTargetLongEdge;
  int32_t g = SCPGreatestCommonDivisor(dims.width, dims.height);
  int32_t ratioW = dims.width / g;   // aspect in lowest terms
  int32_t ratioH = dims.height / g;
  int32_t longRatio = MAX(ratioW, ratioH);
  int32_t multiple = (longRatio > 0) ? (targetLongEdge / longRatio) : 0;
  int32_t scaledW = ratioW * multiple;
  int32_t scaledH = ratioH * multiple;

  BOOL willDownscale = multiple >= 1 && scaledW < dims.width && scaledH < dims.height;
  // Trace the downscale decision (requested vs delivered buffer size). Runs on
  // preset/format changes only, never per frame.
  NSLog(@"applyAnalysisOutputDownscale: long-edge cap %d, requested %dx%d, delivering %dx%d (active format %dx%d)",
        targetLongEdge, scaledW, scaledH,
        willDownscale ? scaledW : dims.width,
        willDownscale ? scaledH : dims.height,
        dims.width, dims.height);
  if (willDownscale) {
    // Exact-aspect downscale (scaledW:scaledH == dims.width:dims.height).
    [self applyAnalysisPixelFormatWithWidth:scaledW height:scaledH];
  } else {
    // Already small enough (or no clean multiple) — don't scale; the format
    // ceiling keeps memory bounded on its own.
    [self applyAnalysisPixelFormatWithWidth:0 height:0];
  }
}

/// Max sustained capture rate for preview/streaming sessions. 30fps matches
/// the native Camera app's photo-mode preview rate and halves the sensor/ISP
/// duty cycle vs the 60fps default of many formats (MIN-2747, MIN-3098; a
/// 24fps trial felt choppier than native, so 30 is the floor we ship). Video
/// recording manages its own rate and is exempt (see applyFrameRateCap).
static const int32_t kStreamingMaxFps = 30;

/// Pin the capture frame rate whenever video recording isn't driving the
/// session (MIN-2747, MIN-3056). Setting activeFormat (the 4:3 InputPriority
/// path) — or a preset switch changing the format — resets
/// activeVideoMin/MaxFrameDuration to the format's defaults, and nothing
/// re-pinned them (VideoController only sets fps while recording), so the
/// sensor was free to run at the format's max rate. The cap used to apply only
/// while the analysis stream was enabled; it is now unconditional when not
/// recording, because a stopped analysis stream must not leave the session
/// uncapped (MIN-3056) — the preview keeps running either way. Capping the
/// *min* duration bounds the rate while leaving the max duration free, so
/// auto-exposure can still drop the rate in low light. Video recording manages
/// fps itself and must not be clamped here.
- (void)applyFrameRateCap {
  if (_captureDevice == nil) {
    return;
  }
  if (_captureMode == Video || _videoController.isRecording) {
    return;
  }
  AVFrameRateRange *range = _captureDevice.activeFormat.videoSupportedFrameRateRanges.firstObject;
  if (range == nil) {
    return;
  }
  // Clamp inside the format's supported range (a high-speed-only format can
  // have minFrameRate above the cap). When the format can't exceed the cap
  // anyway, reuse its own native minFrameDuration — frame durations must fall
  // exactly inside the supported range or AVFoundation throws.
  double cappedFps = MIN((double)kStreamingMaxFps, range.maxFrameRate);
  cappedFps = MAX(cappedFps, range.minFrameRate);
  CMTime minFrameDuration = (cappedFps >= range.maxFrameRate)
      ? range.minFrameDuration
      : CMTimeMake(1, (int32_t)cappedFps);
  NSError *error = nil;
  if (![_captureDevice lockForConfiguration:&error]) {
    NSLog(@"applyFrameRateCap: lockForConfiguration failed: %@", error.localizedDescription);
    return;
  }
  @try {
    _captureDevice.activeVideoMinFrameDuration = minFrameDuration;
  } @catch (NSException *exception) {
    // Same defensive stance as the analysis pixel-format set (MIN-2667): a
    // rejected duration must never crash camera setup — worst case we keep the
    // format's default rate.
    NSLog(@"applyFrameRateCap: rejected frame duration: %@", exception.reason);
  } @finally {
    [_captureDevice unlockForConfiguration];
  }
}

/// Video-HDR policy (MIN-3098). automaticallyAdjustsVideoHDREnabled defaults
/// to YES, so left alone the device may run video-HDR processing on the
/// preview stream — a cost the native Camera app doesn't pay in photo mode.
/// Turn it off whenever video recording isn't driving the session; restore the
/// system default (auto) for video so recordings keep HDR. Stills are
/// unaffected either way: photo HDR is owned by AVCapturePhotoOutput, not the
/// device's video-HDR flag. Must re-run after every activeFormat/preset change
/// (videoHDREnabled is only settable when the active format supports it) and
/// after a sensor switch (fresh device, fresh defaults).
- (void)applyVideoHDRPolicy {
  if (_captureDevice == nil) {
    return;
  }
  BOOL wantsAutoHDR = _captureMode == Video || _videoController.isRecording;
  NSError *error = nil;
  if (![_captureDevice lockForConfiguration:&error]) {
    NSLog(@"applyVideoHDRPolicy: lockForConfiguration failed: %@", error.localizedDescription);
    return;
  }
  @try {
    if (wantsAutoHDR) {
      _captureDevice.automaticallyAdjustsVideoHDREnabled = YES;
    } else if (_captureDevice.activeFormat.videoHDRSupported) {
      // Order matters: setting videoHDREnabled throws while the automatic
      // flag is YES.
      _captureDevice.automaticallyAdjustsVideoHDREnabled = NO;
      _captureDevice.videoHDREnabled = NO;
    }
  } @catch (NSException *exception) {
    // Same defensive stance as applyFrameRateCap (MIN-2667): a rejected HDR
    // flag must never crash camera setup.
    NSLog(@"applyVideoHDRPolicy: rejected: %@", exception.reason);
  } @finally {
    [_captureDevice unlockForConfiguration];
  }
}

/// Async variant of applyFrameRateCap for platform-thread callers (the pigeon
/// analysis handlers): hops onto the serial capture queue so the device lock
/// never runs on — and can never briefly block — the main thread.
- (void)applyFrameRateCapAsync {
  dispatch_async(_dispatchQueue, ^{
    [self applyFrameRateCap];
  });
}

/// Enable the analysis (video-data) connection only when something actually
/// consumes its frames — the Dart image-analysis stream or video recording
/// (MIN-3077). Otherwise the session keeps producing a full-rate stream of
/// downscaled BGRA buffers that the delegate immediately drops (see
/// -captureOutput:didOutputSampleBuffer:), which is pure ISP + memory-bandwidth
/// heat while the scanner just previews. The native Camera app has no such data
/// output; disabling the connection makes our idle session behave the same. The
/// preview layer has its own connection (_previewConnection) and is unaffected.
- (void)updateAnalysisConnectionState {
  BOOL shouldFeed = _imageStreamController.streamImages || _videoController.isRecording;
  if (_captureConnection != nil && _captureConnection.isEnabled != shouldFeed) {
    _captureConnection.enabled = shouldFeed;
  }
}

/// Applies the analysis pixel format to the analysis data output, optionally
/// pinned to [width]x[height] when both are > 0. The format is 32BGRA (the
/// MLKit requirement) unless the analysis stream requested nv21 (MIN-3084) —
/// then we prefer biplanar YUV so ImageStreamController can ship just the luma
/// (Y) plane to Dart: 420f (full-range, matches Android's nv21 luma) first,
/// 420v (video-range, slightly compressed luma — ArUco's adaptive threshold
/// tolerates it) as fallback, 32BGRA last. Recording overrides all of this back
/// to 32BGRA because the video writer consumes these same buffers
/// (_forceBGRAAnalysisForRecording).
///
/// Centralises the crash-safety that opening the QR scanner needs (MIN-2667):
/// -setVideoSettings: throws NSInvalidArgumentException if the pixel format is
/// not currently in the output's availableVideoCVPixelFormatTypes, or if the
/// width/height don't preserve the active format's exact aspect. In an
/// analysis-only / previewOnly session (no photo output) the session is driven
/// off an InputPriority forced activeFormat, and on some devices/iOS versions
/// a format is momentarily absent from availableVideoCVPixelFormatTypes at this
/// point in setup — setting it then threw and crashed the app on open.
///
/// So we: (a) pick the first candidate format that is actually offered and skip
/// entirely when none is — the output keeps whatever settings it already had;
/// and (b) guard every set, falling back from pixel-format+dimensions to
/// pixel-format-only, so a rejection degrades to "no downscale this pass"
/// (bounded by the format ceiling) instead of crashing.
- (void)applyAnalysisPixelFormatWithWidth:(int32_t)width height:(int32_t)height {
  if (_captureVideoOutput == nil) {
    return;
  }

  NSArray<NSNumber *> *candidates;
  if (_requestedAnalysisFormat == nv21 && !_forceBGRAAnalysisForRecording) {
    candidates = @[
      @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      @(kCVPixelFormatType_32BGRA),
    ];
  } else {
    candidates = @[ @(kCVPixelFormatType_32BGRA) ];
  }

  NSNumber *chosen = nil;
  NSArray<NSNumber *> *available = _captureVideoOutput.availableVideoCVPixelFormatTypes;
  for (NSNumber *candidate in candidates) {
    if ([available containsObject:candidate]) {
      chosen = candidate;
      break;
    }
  }
  if (chosen == nil) {
    return;
  }
  if (candidates.count > 1 && ![chosen isEqualToNumber:candidates.firstObject]) {
    // The nv21 stream is running on a lesser format: 420v (video-range luma)
    // or, worst case, BGRA — the Dart side keeps working either way
    // (ImageStreamController emits the dict shape matching the actual buffer),
    // the ~4x payload win is just partially/fully lost on this device.
    NSLog(@"applyAnalysisPixelFormat: 420f unavailable, using %@ (MIN-3084)", chosen);
  }

  NSMutableDictionary *settings =
      [NSMutableDictionary dictionaryWithDictionary:_captureVideoOutput.videoSettings ?: @{}];
  settings[(NSString *)kCVPixelBufferPixelFormatTypeKey] = chosen;
  if (width > 0 && height > 0) {
    settings[(NSString *)kCVPixelBufferWidthKey] = @(width);
    settings[(NSString *)kCVPixelBufferHeightKey] = @(height);
  } else {
    [settings removeObjectForKey:(NSString *)kCVPixelBufferWidthKey];
    [settings removeObjectForKey:(NSString *)kCVPixelBufferHeightKey];
  }

  @try {
    _captureVideoOutput.videoSettings = settings;
  } @catch (NSException *exception) {
    // A width/height that doesn't match the active format's exact aspect is
    // rejected — retry pixel-format-only (still guarded) so we drop the
    // downscale rather than crash; the format ceiling keeps memory bounded.
    @try {
      _captureVideoOutput.videoSettings =
          @{(NSString *)kCVPixelBufferPixelFormatTypeKey : chosen};
    } @catch (NSException *inner) {
      // Leave videoSettings untouched; analysis frames stay at the format size.
    }
  }
}

/// Store the analysis format the Dart stream requested (MIN-3084) and re-apply
/// the output's pixel format + aspect-exact downscale against the live
/// activeFormat. Called from the plugin's setupImageAnalysisStream handler; the
/// ivar persists across sensor switches (setSensor → setCameraPreset →
/// applyAnalysisOutputDownscale re-applies it) and resets naturally with the
/// camera instance on reopen (Dart re-runs setup then).
- (void)updateRequestedAnalysisFormat:(InputAnalysisImageFormat)format {
  if (_requestedAnalysisFormat == format) {
    return;
  }
  _requestedAnalysisFormat = format;
  [self applyAnalysisOutputDownscale];
}

/// Store the analysis long edge the Dart stream requested (MIN-3475) and
/// re-apply the downscale. Same lifecycle as -updateRequestedAnalysisFormat:
/// — persists across sensor switches, resets with the camera instance.
- (void)updateRequestedAnalysisWidth:(int)width {
  int32_t requested = width > 0 ? (int32_t)width : 0;
  if (_requestedAnalysisLongEdge == requested) {
    return;
  }
  _requestedAnalysisLongEdge = requested;
  [self applyAnalysisOutputDownscale];
}

- (void)setCloseRangeScanMode:(BOOL)enabled {
  if (_closeRangeScanMode == enabled) {
    return;
  }
  _closeRangeScanMode = enabled;
  [self applyContinuousAutoFocusPolicy];
}

/// Undo the recording-time BGRA override (MIN-3084): restore the requested
/// nv21 (YUV) analysis format once the video writer no longer consumes the
/// data-output buffers. No-op for BGRA streams (the flag is only set for nv21).
- (void)clearForceBGRAAnalysisForRecording {
  if (!_forceBGRAAnalysisForRecording) {
    return;
  }
  _forceBGRAAnalysisForRecording = NO;
  [self applyAnalysisOutputDownscale];
}

/// Raise the still-capture ceiling to the sensor's full size for the format now
/// active, decoupling photo resolution from the (deliberately small) streaming/
/// analysis format (MIN-3066). While the scanner streams, the session runs on a
/// ≤ kPreviewFourThreeMaxWidth activeFormat; without this, AVCapturePhotoOutput
/// inherits that format's still ceiling (~2016×1512, → 1512² once 1:1-cropped)
/// instead of the sensor. iOS 16+ lets the photo output produce stills larger
/// than the video resolution via maxPhotoDimensions, and bestStreamingFourThree
/// Format already prefers a format that can reach the sensor. The value must be
/// one of the active format's supportedMaxPhotoDimensions (we take the largest,
/// so it is valid by construction) and must be re-applied on every activeFormat/
/// preset change. Pre-iOS-16 falls back to highResolutionCaptureEnabled/
/// highResolutionPhotoEnabled, set on the output and per shot elsewhere.
- (void)applyMaxPhotoDimensions {
  if (@available(iOS 16.0, *)) {
    if (_capturePhotoOutput == nil || _captureDevice == nil) {
      return;
    }
    AVCaptureDeviceFormat *format = _captureDevice.activeFormat;
    if (format == nil) {
      return;
    }
    CMVideoDimensions maxDims = {0, 0};
    for (NSValue *value in format.supportedMaxPhotoDimensions) {
      CMVideoDimensions d = {0, 0};
      [value getValue:&d size:sizeof(d)];
      if ((int64_t)d.width * d.height > (int64_t)maxDims.width * maxDims.height) {
        maxDims = d;
      }
    }
    if (maxDims.width <= 0 || maxDims.height <= 0) {
      return;
    }
    _capturePhotoOutput.maxPhotoDimensions = maxDims;

    CMVideoDimensions videoDims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    NSLog(@"applyMaxPhotoDimensions: active format video %dx%d (binned=%@), still ceiling %dx%d (MIN-3066)",
          videoDims.width, videoDims.height, format.isVideoBinned ? @"YES" : @"NO",
          maxDims.width, maxDims.height);
  }
}

/// The computational-photography quality tier to request, adapted to device RAM.
/// `Balanced` opts into Smart HDR / Deep Fusion, which fuses several full-sensor
/// frames (full-sensor since MIN-3066) and does extra *face-aware* processing.
/// That transient spike is both large and face-content-sensitive, and on 2–3 GB
/// iPads it jetsams the capture session mid-shot — the preview freezes until the
/// app is relaunched (MIN-3176; cf. the 2 GB-iPad jetsam guard in
/// CameraPictureController's capture finalize, MIN-3057). Reducing "Media
/// Quality" only shrank the *post*-capture file, so it merely relieved the
/// downstream footprint enough to dodge the spike — the spike itself lives here.
/// Constrained devices therefore fall back to `Speed` (single frame, no Deep
/// Fusion), trading a little still quality for a capture that stays within
/// budget; devices with headroom keep `Balanced` so MIN-3066's quality stands.
- (AVCapturePhotoQualityPrioritization)preferredPhotoQualityPrioritization API_AVAILABLE(ios(13.0)) {
  // ~3.5 GiB splits the 2/3 GB "constrained iPad" class (→ Speed) from the
  // 4 GB+ fleet (→ Balanced). Tune here if the quality trade-off needs shifting.
  const unsigned long long lowMemoryCeiling = (unsigned long long)(3.5 * 1024 * 1024 * 1024);
  if (NSProcessInfo.processInfo.physicalMemory <= lowMemoryCeiling) {
    return AVCapturePhotoQualityPrioritizationSpeed;
  }
  return AVCapturePhotoQualityPrioritizationBalanced;
}

/// Set camera preview size
/// Re-assert the live-preview autofocus policy: smooth continuous autofocus,
/// plus the MIN-3071 primary-constituent switching restriction. Setting
/// -activeFormat (or a session preset) resets the device's focusMode to the
/// format default — so, like -applyVideoHDRPolicy and -applyFrameRateCap, this
/// must run again after every format/preset change. Without it the tuned
/// low-power preview format (MIN-3098) leaves the scan preview without continuous
/// AF, and it can't focus on a QR/barcode held close (MIN-3316).
- (void)applyContinuousAutoFocusPolicy {
  if (_captureDevice == nil) {
    return;
  }
  NSError *error = nil;
  if (![_captureDevice lockForConfiguration:&error]) {
    NSLog(@"applyContinuousAutoFocusPolicy: lockForConfiguration failed: %@", error.localizedDescription);
    return;
  }
  if ([_captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
    [_captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
  }
  if ([_captureDevice isSmoothAutoFocusSupported]) {
    // Smooth AF trades convergence speed for cinematic lens moves — right for
    // the capture preview, wrong for a scanner racing to sharpen a held-up
    // code, so scan mode takes the fast racks (MIN-3475).
    [_captureDevice setSmoothAutoFocusEnabled:_closeRangeScanMode ? NO : YES];
  }
  if ([_captureDevice isAutoFocusRangeRestrictionSupported]) {
    // Codes are always held near the device; keeping AF out of the far range
    // halves the hunt. Written in both directions so toggling scan mode off
    // actively clears the near-only bias — a camera that inherited the
    // plugin-stored request and later had it withdrawn must not stay stuck
    // near (CodeRabbit, PR #33). Tap-to-focus (focusOnPoint:) still applies
    // its per-tap IOSFocusSettings value on top afterwards.
    [_captureDevice setAutoFocusRangeRestriction:_closeRangeScanMode
                                                     ? AVCaptureAutoFocusRangeRestrictionNear
                                                     : AVCaptureAutoFocusRangeRestrictionNone];
  }

  // MIN-3071: restrict automatic primary-constituent switching to zoom changes
  // only. On a virtual multi-camera back device the default `.auto` behavior lets
  // AVFoundation do a focus/exposure-driven "fallback" switch — e.g. hop wide ->
  // ultra-wide when continuous AF meets a subject closer than the wide's minimum
  // focus distance — a visible FOV jump at a constant 1x zoom. `.restricted` with
  // only `.videoZoomChanged` keeps the explicit zoom presets switching while
  // suppressing the focus/exposure-driven fallbacks. The setter throws on devices
  // without constituent switching, so gate on the behavior not being `.unsupported`.
  //
  // Close-range scan mode (MIN-3475) is the deliberate exception: that fallback
  // hop IS the macro mode a triple-camera device needs to focus a code held
  // closer than the wide lens's ~20cm minimum — and a scanner screen has no
  // framing to protect from the FOV jump. `.auto` requires the conditions
  // argument to be `.none` (the API contract when not `.restricted`).
  if (@available(iOS 15.0, *)) {
    if (_captureDevice.activePrimaryConstituentDeviceSwitchingBehavior !=
        AVCapturePrimaryConstituentDeviceSwitchingBehaviorUnsupported) {
      if (_closeRangeScanMode) {
        [_captureDevice
            setPrimaryConstituentDeviceSwitchingBehavior:AVCapturePrimaryConstituentDeviceSwitchingBehaviorAuto
                   restrictedSwitchingBehaviorConditions:AVCapturePrimaryConstituentDeviceRestrictedSwitchingBehaviorConditionNone];
      } else {
        [_captureDevice
            setPrimaryConstituentDeviceSwitchingBehavior:AVCapturePrimaryConstituentDeviceSwitchingBehaviorRestricted
                   restrictedSwitchingBehaviorConditions:AVCapturePrimaryConstituentDeviceRestrictedSwitchingBehaviorConditionVideoZoomChanged];
      }
    }
  }

  [_captureDevice unlockForConfiguration];
}

- (void)setCameraPreset:(CGSize)currentPreviewSize {
  CGSize targetSize = currentPreviewSize;
  // Overrides for the streaming preview shape (see the streaming branch).
  // [forcedFormat] wins when set: it drives the session from a chosen 4:3
  // AVCaptureDeviceFormat — the only way to a 4:3 stream sharper than 640x480,
  // since iOS has no 4:3 HD preset. [forcedPreset] is the 640x480 fallback.
  NSString *forcedPreset = nil;
  AVCaptureDeviceFormat *forcedFormat = nil;

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
  } else {
      // Any live-preview session — streaming analysis or idle (MIN-3098). This
      // tuned branch used to apply only while the analysis stream ran; with the
      // stream off (the iOS prod default since MIN-3077 moved QR to the
      // hardware detector) init fell through to the largest device format →
      // the 4K preset: an unbinned 4K/30 sensor readout feeding a phone-sized
      // preview. That is near-recording sustained load, far above the native
      // Camera app's binned ~2MP photo-mode preview, and was the dominant idle
      // heat source. Idle now gets the exact streaming session config, so a
      // session that isn't recording always runs the low-power format. This
      // deliberately overrides explicit setPreviewSize requests for non-video
      // sessions — the session shape is owned by the aspect ratio + this
      // policy (the app never calls setPreviewSize).
      //
      // NOTE: this sizes the *preview + analysis* stream, NOT the still. Setting
      // an InputPriority activeFormat pins AVCapturePhotoOutput to that format's
      // still ceiling too — the earlier assumption that stills stayed full-sensor
      // "regardless" was wrong and shipped ~2016×1512 stills (→ 1512² at 1:1)
      // (MIN-3066). Two things now keep stills full-resolution independently of
      // this small streaming format: bestStreamingFourThreeFormat prefers a 4:3
      // format that can still reach the sensor, and -applyMaxPhotoDimensions
      // raises the photo output's maxPhotoDimensions to that format's max (iOS
      // 16+). Memory still matters here: the full-sensor Photo *preset*
      // OOM-crashes on open (~12MP frames to the preview + MLKit). iOS has no
      // 4:3 HD *preset* (only 640x480 / 352x288 / Photo), so for 4:3 we pick a
      // ~1280–1920-wide 4:3 device *format* (far lighter than the Photo preset)
      // and fall back to the 640x480 preset if none is exposed.
      if (_aspectRatio == Ratio4_3) {
        forcedFormat = [self bestStreamingFourThreeFormat];
        if (forcedFormat == nil) {
          forcedPreset = AVCaptureSessionPreset640x480;
        }
      } else {
        // 16:9: iOS has HD 16:9 presets, so drive the GPU preview layer at 1080p
        // for a sharp preview (the data output is capped back down in
        // -applyAnalysisOutputDownscale). Same memory caveat as
        // kPreviewFourThreeMaxWidth above.
        targetSize = CGSizeMake(1080, 1920);
      }
  }

  if (forcedFormat != nil) {
    // Drive the stream from a chosen 4:3 device format. InputPriority tells the
    // session to honour [activeFormat] rather than override it with a preset.
    if ([_captureSession canSetSessionPreset:AVCaptureSessionPresetInputPriority]) {
      [_captureSession setSessionPreset:AVCaptureSessionPresetInputPriority];
    }
    NSError *formatError = nil;
    if ([_captureDevice lockForConfiguration:&formatError]) {
      _captureDevice.activeFormat = forcedFormat;
      [_captureDevice unlockForConfiguration];
      _currentPreset = _captureSession.sessionPreset;
      CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(forcedFormat.formatDescription);
      _currentPreviewSize = CGSizeMake(dims.width, dims.height);
    } else {
      // Lock failed — don't leave the session on InputPriority with no format
      // applied; fall back to the 640x480 preset path below.
      forcedPreset = AVCaptureSessionPreset640x480;
      forcedFormat = nil;
    }
  }

  if (forcedFormat == nil) {
    NSString *presetSelected;
    if (forcedPreset != nil && [_captureSession canSetSessionPreset:forcedPreset]) {
      // A specific preset was requested (e.g. the 4:3 640x480 streaming fallback).
      presetSelected = forcedPreset;
    } else if (!CGSizeEqualToSize(CGSizeZero, targetSize)) {
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
  }

  [_videoController setPreviewSize:_currentPreviewSize];

  // Decouple analysis resolution from the (now higher-res) preview format:
  // cap the data output's buffers so MLKit + the offscreen texture stay light
  // and the session can't OOM on open/capture (MIN-2406).
  [self applyAnalysisOutputDownscale];

  // The format/preset change above reset the device's frame durations to the
  // format defaults — re-pin the rate cap (MIN-2747).
  [self applyFrameRateCap];

  // The active format bounds the still resolution too — raise the photo output's
  // ceiling to this format's full sensor size so stills aren't capped to the
  // small streaming/analysis format (MIN-3066).
  [self applyMaxPhotoDimensions];

  // HDR is a per-mode policy, not a per-format default — re-assert it after
  // the format/preset change (MIN-3098).
  [self applyVideoHDRPolicy];

  // Setting -activeFormat above reset focusMode to the format default — re-assert
  // smooth continuous autofocus so the preview keeps focusing (MIN-3316).
  [self applyContinuousAutoFocusPolicy];
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
  // Deterministic counterpart to the dealloc stop (MIN-2747) — dealloc timing
  // depends on the last reference, dispose is the plugin's explicit teardown.
  [self.motionController stopMotionDetection];
  // Synchronously on _dispatchQueue so teardown can't race in-flight KVO/timeout
  // blocks. dispose runs on the platform thread, never on _dispatchQueue.
  dispatch_sync(_dispatchQueue, ^{
    [self teardownFocusStableObservation];
    [self->_focusStableCompletions removeAllObjects];
  });
  // Drops the subject-area observation and the MIN-3440 session-health
  // observers in one go — self observes nothing else via NSNotificationCenter
  // (focus-stable tracking is KVO, torn down above).
  [[NSNotificationCenter defaultCenter] removeObserver:self];

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
  _shouldBeRunning = YES;
  dispatch_async(_dispatchQueue, ^{
    [self->_captureSession startRunning];
  });
}

/// Stop camera preview
- (void)stop {
  _shouldBeRunning = NO;
  [_captureSession stopRunning];
}

#pragma mark - Session-death recovery (MIN-3440)

/// The session stopped because of an error. AVErrorMediaServicesWereReset
/// (mediaserverd died) is the recoverable case Apple documents: the app must
/// call -startRunning itself or the preview stays frozen forever. Other codes
/// are only logged — blindly restarting can loop on unrecoverable errors
/// (hardware fault, camera access revoked).
- (void)sessionRuntimeError:(NSNotification *)notification {
  NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
  NSLog(@"CamerAwesome: capture session runtime error: %@", error);
  if (error.code == AVErrorMediaServicesWereReset) {
    [self restartSessionIfNeeded];
  }
}

/// Interruption began. Log the reason (system pressure, camera claimed by
/// another foreground app, backgrounding, …) so field reports of a frozen
/// camera come with evidence in the device log.
- (void)sessionWasInterrupted:(NSNotification *)notification {
  NSNumber *reason = notification.userInfo[AVCaptureSessionInterruptionReasonKey];
  NSLog(@"CamerAwesome: capture session interrupted, reason %@", reason);
}

/// Interruption over. AVFoundation resumes the session by itself in the common
/// cases (backgrounding); the explicit restart covers the ones where it
/// doesn't, e.g. recovery after a system-pressure shutdown.
- (void)sessionInterruptionEnded:(NSNotification *)notification {
  NSLog(@"CamerAwesome: capture session interruption ended");
  [self restartSessionIfNeeded];
}

/// Restart the session on the session queue if Dart still expects it running.
/// -startRunning on an already-running session is a no-op, and _shouldBeRunning
/// is re-checked on _dispatchQueue so a concurrent -stop wins over a queued
/// recovery.
- (void)restartSessionIfNeeded {
  dispatch_async(_dispatchQueue, ^{
    if (!self->_shouldBeRunning || self->_captureSession.isRunning) {
      return;
    }
    NSLog(@"CamerAwesome: restarting capture session");
    [self->_captureSession startRunning];
  });
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
  // Drop the QR metadata output too; initCameraPreview: recreates it for the
  // new device (MIN-3077).
  if (_metadataOutput != nil) {
    [_captureSession removeOutput:_metadataOutput];
    _metadataOutput = nil;
  }
  [_captureSession removeConnection:_captureConnection];
  // Drop the preview-layer connection too (it's tied to the outgoing input);
  // initCameraPreview: → attachPreviewLayerConnection rebuilds it for the new
  // device. Removing the video input above may already have auto-removed it, so
  // guard before removing.
  if (_previewConnection != nil && [_captureSession.connections containsObject:_previewConnection]) {
    [_captureSession removeConnection:_previewConnection];
  }
  _previewConnection = nil;

  _cameraSensorPosition = sensor.position;
  _captureDeviceId = sensor.deviceId;
  
  // Init the camera preview with the selected sensor
  [self initCameraPreview:sensor.position];

  // Update VideoController with new capture device to re-apply custom FPS if recording
  // This fixes audio/video desync when switching cameras during recording with custom FPS
  [_videoController updateCaptureDevice:_captureDevice];

  [self setBestPreviewQuality];
  
  [_captureSession commitConfiguration];
  // Re-pin the fps cap after the commit: a preset set inside the
  // begin/commit block only takes effect now, and the format switch it
  // triggers resets the device's frame durations (MIN-2747).
  [self applyFrameRateCap];
  // Same for the HDR policy: the new device's activeFormat is only final after
  // the commit, and the in-block run saw the outgoing format (MIN-3098).
  [self applyVideoHDRPolicy];
  // Re-apply QR types after the commit too — availableMetadataObjectTypes can
  // be empty while the session is mid-configuration (MIN-3077).
  [self applyQrMetadataTypes];
  // The connection was rebuilt for the new device (defaults to enabled); gate
  // it on actual consumption again (MIN-3077).
  [self updateAnalysisConnectionState];
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

  // Keep the native preview layer's mirroring in sync (MIN-2406): the preview is
  // its own connection, so a toggle here must update it too, gated on the front
  // sensor so the back-camera preview is never mirrored.
  if (_previewConnection != nil && [_previewConnection isVideoMirroringSupported]) {
    [_previewConnection setVideoMirrored:(_cameraSensorPosition == PigeonSensorPositionFront) && value];
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
/// The incoming [point] is normalised (0..1, origin top-left) over the preview
/// the user sees. We delegate to the preview layer's
/// `captureDevicePointOfInterestForPoint:`, which converts a layer point to the
/// sensor POI accounting for the connection's current `videoOrientation` (now
/// driven by the interface orientation, MIN-2437), the videoGravity and front
/// camera mirroring — so tap-to-focus stays correct in every orientation. Falls
/// back to the fixed portrait mapping (px, py) -> (py, 1 - px) if the layer
/// hasn't been laid out yet (its bounds would be zero). Must run on the main
/// thread (focusOnPoint: is invoked from the platform channel, which it is).
- (CGPoint)focusPointOfInterestForPreviewPoint:(CGPoint)point {
  CGSize layerSize = _previewLayer != nil ? _previewLayer.bounds.size : CGSizeZero;
  if (layerSize.width > 0 && layerSize.height > 0) {
    CGPoint layerPoint = CGPointMake(point.x * layerSize.width, point.y * layerSize.height);
    CGPoint poi = [_previewLayer captureDevicePointOfInterestForPoint:layerPoint];
    poi.x = MAX(0.0, MIN(1.0, poi.x));
    poi.y = MAX(0.0, MIN(1.0, poi.y));
    return poi;
  }

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

  // Re-run the session config for the new mode (MIN-3098): Photo/Preview picks
  // the tuned low-power preview format (+ video-HDR off, fps cap); Video
  // restores the full-quality video preset (+ auto HDR). Without this the
  // low-power preview format would leak into a recording — or the video config
  // into the idle preview.
  [self setBestPreviewQuality];

  if (captureMode == Video && _videoController.isAudioEnabled) {
    [self setUpCaptureSessionForAudioError:^(NSError *audioError) {
      // Audio is best-effort. If the microphone can't be set up (permission
      // denied, or no usable audio device — e.g. "Cannot use iPad Microphone")
      // we record silent video instead of failing the capture-mode switch.
      // Disabling audio here keeps the recorder from waiting on samples that
      // never arrive. The Flutter layer owns the microphone-permission UX.
      [self->_videoController setIsAudioEnabled:NO];
      NSLog(@"camerawesome: microphone unavailable, recording video without audio (%@)", audioError.localizedDescription);
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
  // Fire the shutter immediately on press, matching the native Camera app.
  // Blocking to let AF/AE settle first delayed the capture enough that a moving
  // camera produced a moved/blurry shot (Salvos report) — the frame was taken a
  // moment after the tap, by which point the framing had already changed.
  [self capturePictureAtPath:path completion:completion];
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

  // Request the still at the output's configured maximum (set per active format
  // in -applyMaxPhotoDimensions) so the photo is full-sensor even though the
  // analysis stream pins a small video format (MIN-3066). Must be ≤ the output's
  // maxPhotoDimensions; reading it back keeps the two in lockstep. On pre-iOS-16
  // the highResolutionPhotoEnabled flag above remains the ceiling.
  if (@available(iOS 16.0, *)) {
    CMVideoDimensions outputMax = _capturePhotoOutput.maxPhotoDimensions;
    if (outputMax.width > 0 && outputMax.height > 0) {
      settings.maxPhotoDimensions = outputMax;
    }
  }

  // Opt into the modern processing pipeline (Smart HDR / Deep Fusion) at the
  // same tier as the output ceiling — memory-gated so constrained iPads request
  // Speed and skip the full-sensor Deep-Fusion memory spike that freezes the
  // camera (MIN-3176). Matches maxPhotoQualityPrioritization set in
  // initCameraPreview, so it never exceeds the ceiling.
  if (@available(iOS 13.0, *)) {
    settings.photoQualityPrioritization = [self preferredPhotoQualityPrioritization];
  }

  [_capturePhotoOutput capturePhotoWithSettings:settings
                                       delegate:cameraPicture];
  
}

# pragma mark - Camera video
/// Record video into the given path
- (void)recordVideoAtPath:(NSString *)path completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (!_videoController.isRecording) {
    // The video writer is pinned to 32BGRA, so an nv21 analysis stream must
    // hand the output back to BGRA for the duration of the recording
    // (MIN-3084). Done BEFORE the recording starts so a failure can abort it
    // cleanly: if BGRA didn't stick (theoretical — transiently absent from
    // availableVideoCVPixelFormatTypes), every frame would be dropped by the
    // BGRA-only forward guard and the recording would complete "successfully"
    // as an empty file. Skip the session reconfigure entirely for the common
    // BGRA-stream case.
    if (_requestedAnalysisFormat == nv21) {
      _forceBGRAAnalysisForRecording = YES;
      [self applyAnalysisOutputDownscale];
      NSNumber *applied = _captureVideoOutput.videoSettings[(NSString *)kCVPixelBufferPixelFormatTypeKey];
      if (applied == nil || applied.unsignedIntValue != kCVPixelFormatType_32BGRA) {
        [self clearForceBGRAAnalysisForRecording];
        completion([FlutterError errorWithCode:@"VIDEO_ERROR"
                                       message:@"analysis output could not switch back to BGRA for recording"
                                       details:@""]);
        return;
      }
    }
    // Any startup failure after the BGRA flip must restore the nv21 format —
    // stopRecordingVideo never runs for a recording that never started, so the
    // force flag would otherwise stay latched and the stream would silently
    // lose its luma payload for the rest of the session (MIN-3084).
    void (^recordingCompletion)(FlutterError *_Nullable) = ^(FlutterError *_Nullable error) {
      if (error != nil) {
        [self clearForceBGRAAnalysisForRecording];
      }
      completion(error);
    };
    [_videoController recordVideoAtPath:path captureDevice:_captureDevice orientation:_motionController.deviceOrientation audioSetupCallback:^{
      [self setUpCaptureSessionForAudioError:^(NSError *error) {
        recordingCompletion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"error when trying to setup audio" details:[error localizedDescription]]);
      }];
    } videoWriterCallback:^{
      if (self->_videoController.isAudioEnabled) {
        [self->_audioOutput setSampleBufferDelegate:self queue:self->_dispatchQueue];
      }
      [self->_captureVideoOutput setSampleBufferDelegate:self queue:self->_dispatchQueue];
      // Recording consumes the video-data output — force its connection on (the
      // isRecording flag may not be observable yet at this point, so don't rely
      // on -updateAnalysisConnectionState here) (MIN-3077).
      if (self->_captureConnection != nil) {
        self->_captureConnection.enabled = YES;
      }

      recordingCompletion(nil);
    } options:_videoOptions quality: _recordingQuality completion:recordingCompletion];
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
    __weak typeof(self) weakSelf = self;
    [_videoController stopRecordingVideo:^(NSNumber *_Nullable ok, FlutterError *_Nullable err) {
      // Recording no longer consumes the video-data output — re-gate the
      // connection so the idle preview stops producing dropped frames (MIN-3077).
      [weakSelf updateAnalysisConnectionState];
      // Restore the nv21 (YUV) analysis format that recording forced back to
      // BGRA (MIN-3084).
      [weakSelf clearForceBGRAAnalysisForRecording];
      completion(ok, err);
    }];
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
    // MIN-2406: the on-screen preview is the native AVCaptureVideoPreviewLayer
    // (hosted in a PlatformView), so we no longer pump frames into the Flutter
    // preview Texture. Doing so would run a second, redundant preview pipeline
    // — extra memory plus a per-frame CFRetain of the pixel buffer on the
    // capture queue — which on iPad contributes to memory-pressure crashes.
    // The texture stays *registered* (readiness gate / filter thumbnail) but
    // unfed; the GPU preview layer is the display path.

    // Send to image stream controller if enabled
    if (_imageStreamController.streamImages) {
        [_imageStreamController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection orientation:_motionController.deviceOrientation];
    }

    // Send to video recording controller if recording
    if (_videoController.isRecording) {
      // Ensure VideoController's captureOutput can handle being called multiple times for the same timestamp (once for video, once for audio)
      // or ensure it only processes the video buffer here.
      // Assuming it can differentiate based on 'output' or buffer type.
      //
      // Only forward 32BGRA buffers: the writer's pixel-buffer adaptor is
      // pinned to 32BGRA, and YUV frames can still be in flight for a beat
      // after recording start switches an nv21 analysis stream back to BGRA
      // (the settings change and this delegate race on different mechanisms)
      // (MIN-3084).
      CVPixelBufferRef recordingBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      if (recordingBuffer != nil && CVPixelBufferGetPixelFormatType(recordingBuffer) == kCVPixelFormatType_32BGRA) {
        [_videoController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection captureVideoOutput:_captureVideoOutput];
      }
    }
  } else if (output == _audioOutput) {
    // Send audio buffers only to video recording controller if recording & audio enabled
    if (_videoController.isRecording && _videoController.isAudioEnabled) {
      [_videoController captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection captureVideoOutput:nil]; // Pass nil for video output for audio
    }
  }
}

@end
