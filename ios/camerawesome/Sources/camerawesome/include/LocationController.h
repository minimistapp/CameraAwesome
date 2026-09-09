//
//  LocationController.h
//  camerawesome
//
//  Created by Dimitri Dessus on 07/09/2022.
//

#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>

#import "CamerawesomeLocation.h"

#if CAMERAWESOME_ENABLE_LOCATION
#import <CoreLocation/CoreLocation.h>
#endif

NS_ASSUME_NONNULL_BEGIN

typedef void(^OnAuthorizationDeclined)(void);
typedef void(^OnAuthorizationGranted)(void);

#if CAMERAWESOME_ENABLE_LOCATION
@interface LocationController : NSObject<CLLocationManagerDelegate>

@property (strong, nonatomic, nonnull) CLLocationManager *locationManager;
#else
/// Location is compiled out (see CamerawesomeLocation.h) — the authorization
/// request always reports "declined" and no CoreLocation API is referenced.
@interface LocationController : NSObject
#endif

@property (nonatomic, copy) OnAuthorizationDeclined declinedBlock;
@property (nonatomic, copy) OnAuthorizationGranted grantedBlock;

- (instancetype)init;
- (void)requestLocationAuthorizationOnGranted:(OnAuthorizationGranted)granted declined:(OnAuthorizationDeclined)declined;

@end

NS_ASSUME_NONNULL_END
