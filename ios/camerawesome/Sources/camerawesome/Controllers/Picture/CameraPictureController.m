//
//  CameraPicture.m
//  camerawesome
//
//  Created by Dimitri Dessus on 24/07/2020.
//

#import "CameraPictureController.h"
#import "ExifContainer.h"
#import "NSData+Exif.h"

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
  
  // this is the type of image (e.g., public.jpeg)
  CFStringRef UTI = CGImageSourceGetType(source);
  
  // create a new data object and write the new image into it
  NSMutableData *dest_data = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)dest_data, UTI, 1, NULL);
  if (!destination) {
    NSLog(@"Error: Could not create image destination");
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
  return dest_data;
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

  // Save GPS location only if provided
  if (_saveGPSLocation) {
    CLLocationManager *locationManager = [CLLocationManager new];
    CLLocation *location = [locationManager location];
    [container addLocation:location];
  }

  // Finalized bytes from the modern photo pipeline — this is the image after
  // Smart HDR / Deep Fusion processing. Replaces the deprecated JPEG
  // sample-buffer path, which delivered an unprocessed frame.
  NSData *data = [photo fileDataRepresentation];
  if (data == nil) {
    _completion(nil, [FlutterError errorWithCode:@"CAPTURE ERROR" message:@"no photo data" details:@""]);
    return;
  }

  // Non-nil data doesn't guarantee a successful decode; a nil CGImage would
  // later crash in imageByCroppingImage: (CGImageGetWidth / CGImageCreateWithImageInRect).
  UIImage *decodedImage = [UIImage imageWithData:data];
  if (decodedImage == nil || decodedImage.CGImage == nil) {
    _completion(nil, [FlutterError errorWithCode:@"CAPTURE ERROR" message:@"invalid photo data" details:@""]);
    return;
  }

  UIImage *image = [UIImage imageWithCGImage:decodedImage.CGImage
                                       scale:1.0
                                 orientation:[self getJpegOrientation]];
  float originalWidth = image.size.width;
  float originalHeight = image.size.height;
  
  float originalImageAspectRatio = originalWidth / originalHeight;
  
  float outputWidth = originalWidth;
  float outputHeight = originalHeight;
  if (originalImageAspectRatio != _aspectRatio) {
    if (originalImageAspectRatio > _aspectRatio) {
      outputWidth = originalHeight * _aspectRatio;
    } else if (originalImageAspectRatio < _aspectRatio) {
      outputHeight = originalWidth / _aspectRatio;
    }
  }
  
  UIImage *imageConverted = [self imageByCroppingImage:image toSize:CGSizeMake(outputWidth, outputHeight)];
  
  image = [UIImage imageWithCGImage:[imageConverted CGImage] scale:0.0 orientation:[self getJpegOrientation]];

  NSData *imageWithExif = [UIImageJPEGRepresentation(image, 1.0) addExif:container];
  
  bool success = [imageWithExif writeToFile:_path atomically:YES];
  if (!success) {
    _completion(nil, [FlutterError errorWithCode:@"IOError" message:@"unable to write file" details:nil]);
    return;
  }
  _completionBlock();
  
}

- (UIImage *)imageByCroppingImage:(UIImage *)image toSize:(CGSize)size {
  // Crop to [_aspectRatio] in CGImage (sensor-native) pixel space, centered and
  // independent of device orientation; the caller re-applies the EXIF
  // orientation. The previous orientation-branched logic cropped a portrait 4:3
  // capture down to a square (cutting top & bottom) and never actually cropped
  // 16:9 — so the saved photo didn't match the viewfinder. A centered crop in
  // sensor space is identical in portrait and landscape and equals the
  // preview's centered crop, so the photo matches what you framed. [size] is
  // ignored (it came from the display-oriented math that caused the bug).
  // (MIN-1991)
  //   4:3  -> equals the 4:3 sensor, no crop (full frame).
  //   16:9 -> trims top & bottom to the centered 16:9 band.
  //   1:1  -> centered square.
  CGImageRef cgImage = image.CGImage;
  double cgWidth = CGImageGetWidth(cgImage);
  double cgHeight = CGImageGetHeight(cgImage);
  double sensorAspect = cgWidth / cgHeight;  // sensor frame is landscape, ~1.333

  double cropWidth = cgWidth;
  double cropHeight = cgHeight;
  if (_aspectRatio > sensorAspect) {
    cropHeight = cgWidth / _aspectRatio;
  } else if (_aspectRatio < sensorAspect) {
    cropWidth = cgHeight * _aspectRatio;
  }

  CGRect cropRect = CGRectMake((cgWidth - cropWidth) / 2.0,
                               (cgHeight - cropHeight) / 2.0,
                               cropWidth, cropHeight);

  CGImageRef imageRef = CGImageCreateWithImageInRect(cgImage, cropRect);
  UIImage *cropped = [UIImage imageWithCGImage:imageRef];
  CGImageRelease(imageRef);

  return cropped;
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
