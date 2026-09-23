//
//  CameraPicture.m
//  camerawesome
//
//  Created by Dimitri Dessus on 24/07/2020.
//

#import <ImageIO/ImageIO.h>

#import "CameraPictureController.h"
#import "ExifContainer.h"

/// JPEG quality of the re-encode a 16:9 / 1:1 crop needs. 0.9 is visually
/// indistinguishable for this pipeline while roughly halving both the output
/// file and the transient encode buffer that 1.0 produced.
static const CGFloat kCroppedJpegQuality = 0.9;

/// The one queue every capture is finalized on (crop / metadata / write),
/// shared by all controllers (MIN-5520).
///
/// Not AVFoundation's delegate queue: Apple only promises that one is "not
/// necessarily the main queue", and it is common to every callback of the
/// photo output, so a finalize running on it holds up the next shot's
/// callbacks too. Serial, so two shots in quick succession never hold two
/// full-frame bitmaps at once on a 3 GB iPad (MIN-3057).
static dispatch_queue_t CameraPictureFinalizeQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    queue = dispatch_queue_create("camerawesome.picture.finalize", attributes);
  });
  return queue;
}

@implementation CameraPictureController {
  CameraPictureController *selfReference;
}

- (instancetype)initWithPath:(NSString *)path
                     orientation:(NSInteger)orientation
                  sensorPosition:(PigeonSensorPosition)sensorPosition
                 saveGPSLocation:(bool)saveGPSLocation
               mirrorFrontCamera:(bool)mirrorFrontCamera
                     aspectRatio:(AspectRatio)aspectRatio
                      completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion
                        callback:(OnPictureTaken)callback {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _path = path;
  _completion = completion;
  _orientation = orientation;
  _completionBlock = callback;
  _sensorPosition = sensorPosition;
  _saveGPSLocation = saveGPSLocation;
  _aspectRatioType = aspectRatio;
  _mirrorFrontCamera = mirrorFrontCamera;
  
  if (aspectRatio == Ratio4_3) {
    _aspectRatio = 4.0/3.0;
  } else if(aspectRatio == Ratio16_9) {
    _aspectRatio = 16.0/9.0;
  } else {
    _aspectRatio = 1;
  }
  
  selfReference = self;
  return self;
}

- (NSData *)writeMetadataIntoImageData:(NSData *)imageData metadata:(NSMutableDictionary *)metadata {
  // create an imagesourceref
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef) imageData, NULL);
  if (!source) {
    NSLog(@"Error: Could not create image source");
    return nil;
  }

  // this is the type of image (e.g., public.jpeg)
  CFStringRef UTI = CGImageSourceGetType(source);

  // create a new data object and write the new image into it
  NSMutableData *dest_data = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)dest_data, UTI, 1, NULL);
  if (!destination) {
    NSLog(@"Error: Could not create image destination");
    CFRelease(source);
    return nil;
  }
  // add the image contained in the image source to the destination, overidding the old metadata with our modified metadata
  CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef) metadata);
  BOOL success = NO;
  success = CGImageDestinationFinalize(destination);
  if (!success) {
    NSLog(@"Error: Could not create data from image destination");
  }
  CFRelease(destination);
  CFRelease(source);
  return success ? dest_data : nil;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
  selfReference = nil;
  if (error) {
    _completion(nil, [FlutterError errorWithCode:@"CAPTURE ERROR" message:error.description details:@""]);
    return;
  }

  // Add exif data
  ExifContainer *container = [[ExifContainer alloc] init];
  [container addCreationDate:[NSDate date]];

#if CAMERAWESOME_ENABLE_LOCATION
  // Save GPS location only if provided
  if (_saveGPSLocation) {
    CLLocationManager *locationManager = [CLLocationManager new];
    CLLocation *location = [locationManager location];
    [container addLocation:location];
  }
#endif

  // Finalized bytes from the modern photo pipeline — this is the image after
  // Smart HDR / Deep Fusion processing. Replaces the deprecated JPEG
  // sample-buffer path, which delivered an unprocessed frame.
  NSData *data = [photo fileDataRepresentation];
  if (data == nil) {
    _completion(nil, [FlutterError errorWithCode:@"CAPTURE ERROR" message:@"no photo data" details:@""]);
    return;
  }

  // Everything above is cheap and stays on the delegate queue, so the EXIF
  // date and orientation are read at the moment the photo lands. The decode /
  // encode / write leaves it (see CameraPictureFinalizeQueue); the block keeps
  // self alive in place of selfReference.
  CGImagePropertyOrientation orientation = [self exifOrientationForCapture];
  NSDictionary *exif = [container exifData];
  dispatch_async(CameraPictureFinalizeQueue(), ^{
    [self finalizePhotoData:data exif:exif orientation:orientation];
  });
}

/// Crops (16:9 / 1:1) or re-stamps (4:3) the captured bytes, writes them to
/// [path] and completes the capture. Runs on CameraPictureFinalizeQueue.
- (void)finalizePhotoData:(NSData *)data exif:(NSDictionary *)exif orientation:(CGImagePropertyOrientation)orientation {
  // Drain every transient full-size buffer before the next capture is
  // finalized instead of whenever the queue's pool next drains — a capture
  // burst otherwise stacks tens-of-MB autoreleased peaks and jetsams older
  // 2GB iPads (MIN-3057).
  @autoreleasepool {
    // 4:3 equals the 4:3 sensor frame, so there is nothing to crop: keep the
    // camera's bitstream and rewrite only its metadata. 16:9 / 1:1 trim the
    // sensor frame, which needs pixel access. Orientation must be stamped
    // explicitly either way: the capture connection is pinned portrait, so the
    // AVFoundation EXIF never reflects the real device orientation (MIN-3057).
    NSData *imageWithExif = _aspectRatioType == Ratio4_3
        ? [self dataByStampingData:data exif:exif orientation:orientation]
        : [self dataByCroppingData:data exif:exif orientation:orientation];
    if (imageWithExif == nil) {
      _completion(nil, [FlutterError errorWithCode:@"CAPTURE ERROR" message:@"invalid photo data" details:@""]);
      return;
    }

    bool success = [imageWithExif writeToFile:_path atomically:YES];
    if (!success) {
      _completion(nil, [FlutterError errorWithCode:@"IOError" message:@"unable to write file" details:nil]);
      return;
    }
  }
  _completionBlock();
}

/// 4:3: the camera's JPEG with its orientation tag rewritten, without touching
/// a pixel (MIN-5520). CGImageDestinationCopyImageSource is ImageIO's lossless
/// metadata path (Apple QA1895) — the AddImageFromSource route this used
/// before, and still falls back to, decodes and re-encodes the whole frame.
/// The copy keeps AVFoundation's own EXIF, which already carries the capture
/// date, so only a GPS request needs the fallback: CopyImageSource can't take
/// the orientation and extra tags in one call.
- (nullable NSData *)dataByStampingData:(NSData *)data exif:(NSDictionary *)exif orientation:(CGImagePropertyOrientation)orientation {
  NSMutableDictionary *metadata = [exif mutableCopy];
  metadata[(NSString *)kCGImagePropertyOrientation] = @(orientation);
  if (exif[(NSString *)kCGImagePropertyGPSDictionary] != nil) {
    return [self writeMetadataIntoImageData:data metadata:metadata];
  }

  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (source == NULL) {
    return nil;
  }
  NSMutableData *output = [NSMutableData data];
  CFStringRef type = CGImageSourceGetType(source);
  CGImageDestinationRef destination =
      type == NULL ? NULL : CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, type, 1, NULL);
  bool copied = false;
  if (destination != NULL) {
    NSDictionary *options = @{(NSString *)kCGImageDestinationOrientation: @(orientation)};
    CFErrorRef copyError = NULL;
    // No CGImageDestinationFinalize: the copy is complete when this returns.
    copied = CGImageDestinationCopyImageSource(destination, source, (__bridge CFDictionaryRef)options, &copyError);
    if (!copied) {
      NSLog(@"camerawesome: lossless metadata copy failed (%@), re-encoding instead", (__bridge NSError *)copyError);
    }
    if (copyError != NULL) {
      CFRelease(copyError);
    }
    CFRelease(destination);
  }
  CFRelease(source);
  return copied ? output : [self writeMetadataIntoImageData:data metadata:metadata];
}

/// 16:9 / 1:1: exactly one decode and one encode (MIN-5520). Until then this
/// was a UIImage decode + crop + UIImageJPEGRepresentation, then -addExif:,
/// whose CGImageDestinationAddImageFromSource decoded that JPEG a second time
/// and re-encoded it again just to add one EXIF tag — with the first full-frame
/// bitmap still cached on an autoreleased UIImage until the pool drained.
/// Metadata matches what that path wrote: the container's EXIF plus the
/// orientation tag, not the camera's EXIF.
- (nullable NSData *)dataByCroppingData:(NSData *)data exif:(NSDictionary *)exif orientation:(CGImagePropertyOrientation)orientation {
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (source == NULL) {
    return nil;
  }
  // Decode now, once: the crop below references this bitmap rather than
  // re-reading the JPEG, and both are released as soon as the encode is done.
  NSDictionary *decodeOptions = @{(NSString *)kCGImageSourceShouldCacheImmediately: @YES};
  CGImageRef fullImage = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)decodeOptions);
  CFRelease(source);
  if (fullImage == NULL) {
    return nil;
  }
  CGImageRef croppedImage =
      CGImageCreateWithImageInRect(fullImage, [self cropRectForWidth:CGImageGetWidth(fullImage) height:CGImageGetHeight(fullImage)]);
  CGImageRelease(fullImage);
  if (croppedImage == NULL) {
    return nil;
  }

  NSMutableData *output = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, CFSTR("public.jpeg"), 1, NULL);
  bool encoded = false;
  if (destination != NULL) {
    NSMutableDictionary *properties = [exif mutableCopy];
    properties[(NSString *)kCGImagePropertyOrientation] = @(orientation);
    properties[(NSString *)kCGImageDestinationLossyCompressionQuality] = @(kCroppedJpegQuality);
    CGImageDestinationAddImage(destination, croppedImage, (__bridge CFDictionaryRef)properties);
    encoded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(croppedImage);
  return encoded ? output : nil;
}

/// EXIF/TIFF orientation value (CGImagePropertyOrientation) equivalent to
/// [getJpegOrientation], for paths that stamp metadata without building a
/// UIImage.
- (CGImagePropertyOrientation)exifOrientationForCapture {
  switch ([self getJpegOrientation]) {
    case UIImageOrientationUp: return kCGImagePropertyOrientationUp;
    case UIImageOrientationDown: return kCGImagePropertyOrientationDown;
    case UIImageOrientationLeft: return kCGImagePropertyOrientationLeft;
    case UIImageOrientationRight: return kCGImagePropertyOrientationRight;
    case UIImageOrientationUpMirrored: return kCGImagePropertyOrientationUpMirrored;
    case UIImageOrientationDownMirrored: return kCGImagePropertyOrientationDownMirrored;
    case UIImageOrientationLeftMirrored: return kCGImagePropertyOrientationLeftMirrored;
    case UIImageOrientationRightMirrored: return kCGImagePropertyOrientationRightMirrored;
  }
  return kCGImagePropertyOrientationUp;
}

- (CGRect)cropRectForWidth:(size_t)width height:(size_t)height {
  // Crop to [_aspectRatio] in CGImage (sensor-native) pixel space, centered and
  // independent of device orientation; the caller stamps the EXIF
  // orientation. The previous orientation-branched logic cropped a portrait 4:3
  // capture down to a square (cutting top & bottom) and never actually cropped
  // 16:9 — so the saved photo didn't match the viewfinder. A centered crop in
  // sensor space is identical in portrait and landscape and equals the
  // preview's centered crop, so the photo matches what you framed.
  // (MIN-1991)
  //   4:3  -> equals the 4:3 sensor, no crop (full frame).
  //   16:9 -> trims top & bottom to the centered 16:9 band.
  //   1:1  -> centered square.
  double cgWidth = width;
  double cgHeight = height;
  double sensorAspect = cgWidth / cgHeight;  // sensor frame is landscape, ~1.333

  double cropWidth = cgWidth;
  double cropHeight = cgHeight;
  if (_aspectRatio > sensorAspect) {
    cropHeight = cgWidth / _aspectRatio;
  } else if (_aspectRatio < sensorAspect) {
    cropWidth = cgHeight * _aspectRatio;
  }

  return CGRectMake((cgWidth - cropWidth) / 2.0,
                    (cgHeight - cropHeight) / 2.0,
                    cropWidth, cropHeight);
}

// Helper #1: map a “known” UIDeviceOrientation → UIImageOrientation
- (UIImageOrientation)imageOrientationFromDeviceOrientation:(UIDeviceOrientation)devOrient {
    switch (devOrient) {
        case UIDeviceOrientationPortrait:
            return (self.sensorPosition == PigeonSensorPositionFront && _mirrorFrontCamera)
                ? UIImageOrientationLeftMirrored
                : UIImageOrientationRight;
        case UIDeviceOrientationPortraitUpsideDown:
            return UIImageOrientationLeft;
        case UIDeviceOrientationLandscapeLeft:
            return (self.sensorPosition == PigeonSensorPositionBack)
                ? UIImageOrientationDown
                : UIImageOrientationUp;
        case UIDeviceOrientationLandscapeRight:
            return (self.sensorPosition == PigeonSensorPositionBack)
                ? UIImageOrientationUp
                : UIImageOrientationDown;
        default:
            return UIImageOrientationUp;
    }
}

// Helper #2: map a UIInterfaceOrientation → UIImageOrientation
- (UIImageOrientation)imageOrientationFromInterfaceOrientation:(UIInterfaceOrientation)uiOrient {
    switch (uiOrient) {
        case UIInterfaceOrientationPortrait:
            return (self.sensorPosition == PigeonSensorPositionFront && _mirrorFrontCamera)
                ? UIImageOrientationLeftMirrored
                : UIImageOrientationRight;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIImageOrientationLeft;
        case UIInterfaceOrientationLandscapeLeft:
            return (self.sensorPosition == PigeonSensorPositionBack)
                ? UIImageOrientationDown
                : UIImageOrientationUp;
        case UIInterfaceOrientationLandscapeRight:
            return (self.sensorPosition == PigeonSensorPositionBack)
                ? UIImageOrientationUp
                : UIImageOrientationDown;
        default:
            return UIImageOrientationUp;
    }
}

- (UIImageOrientation)getJpegOrientation {
    UIDeviceOrientation devOrient = _orientation;
    // Check if _orientation is one of the ones we handle directly
    if (devOrient != UIDeviceOrientationUnknown) {
        return [self imageOrientationFromDeviceOrientation:devOrient];
    }

    // Fallback: pull the UI orientation
    UIInterfaceOrientation uiOrient;
    if (@available(iOS 13.0, *)) {
        uiOrient = UIApplication.sharedApplication
                        .windows.firstObject.windowScene.interfaceOrientation;
    } else {
        uiOrient = UIApplication.sharedApplication.statusBarOrientation;
    }
    return [self imageOrientationFromInterfaceOrientation:uiOrient];
}

@end
