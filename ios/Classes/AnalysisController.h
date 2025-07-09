//
//  AnalysisController.h
//  camerawesome
//
//  Created by Apparence on 20/03/2023.
//

#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>
#import "Pigeon.h"

NS_ASSUME_NONNULL_BEGIN

@interface AnalysisController : NSObject <CAAnalysisImageUtils>

- (instancetype)initWithResult:(FlutterResult)result;

@end

NS_ASSUME_NONNULL_END 