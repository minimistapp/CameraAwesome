//
//  LocationController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 07/09/2022.
//

#import "LocationController.h"

@implementation LocationController

#if CAMERAWESOME_ENABLE_LOCATION

- (instancetype)init {
  if (self = [super init]) {
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    
    self.locationManager.distanceFilter = kCLDistanceFilterNone;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
  }
  
  return self;
}

- (void)requestLocationAuthorizationOnGranted:(OnAuthorizationGranted)granted declined:(OnAuthorizationDeclined)declined {
  _grantedBlock = granted;
  _declinedBlock = declined;
  
  if (self.locationManager.authorizationStatus ==  kCLAuthorizationStatusNotDetermined) {
    if ([self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
      [self.locationManager requestWhenInUseAuthorization];
    }
  } else if (self.locationManager.authorizationStatus ==  kCLAuthorizationStatusAuthorizedAlways || self.locationManager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
    _grantedBlock();
  } else {
    _declinedBlock();
  }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
  if (manager.authorizationStatus ==  kCLAuthorizationStatusAuthorizedAlways || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
    if (_grantedBlock != nil) {
      _grantedBlock();
    }
    
  } else {
    if (_declinedBlock != nil) {
      _declinedBlock();
    }
    
  }
}

#else

- (instancetype)init {
  return [super init];
}

/// Location is compiled out (see CamerawesomeLocation.h), so there is nothing
/// to ask for. Reporting "declined" is the same answer a user who refuses the
/// prompt gives, and every caller already handles it by leaving
/// saveGPSLocation false.
- (void)requestLocationAuthorizationOnGranted:(OnAuthorizationGranted)granted declined:(OnAuthorizationDeclined)declined {
  _grantedBlock = granted;
  _declinedBlock = declined;
  
  declined();
}

#endif

@end
