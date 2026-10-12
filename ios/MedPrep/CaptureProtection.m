#import "CaptureProtection.h"

// Independently implemented per-layer secure-text rendering technique, reviewed
// against Telegram's UIKitRuntimeUtils. UIKit does not support this contract.
BOOL MedPrepProtectLayer(CALayer *layer) {
    NSCAssert([NSThread isMainThread], @"Capture protection requires the main thread");
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    field.text = @" ";
    [field layoutIfNeeded];
    UIView *canvas = nil;
    for (UIView *candidate in field.subviews) {
        if ([NSStringFromClass(candidate.class) containsString:@"TextLayoutCanvasView"]) {
            canvas = candidate;
            break;
        }
    }
    if (!canvas) { return NO; }
    CALayer *original = canvas.layer;
    BOOL applied = NO;
    @try {
        [canvas setValue:layer forKey:@"layer"];
        field.secureTextEntry = NO;
        field.secureTextEntry = YES;
        applied = YES;
    } @catch (NSException *exception) {
        applied = NO;
    } @finally {
        @try { [canvas setValue:original forKey:@"layer"]; }
        @catch (NSException *exception) { applied = NO; }
    }
    return applied;
}
