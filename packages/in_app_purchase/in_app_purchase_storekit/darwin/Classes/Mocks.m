#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
#import "FIAPaymentQueueHandler.h"
#import "Mocks.h"

#pragma mark Payment Queue Implementations
/// Real implementations
@implementation DefaultPaymentQueue
- (instancetype)initWithQueue:(SKPaymentQueue*)queue {
  self = [super init];
  if (self) {
    _queue = queue;
  }
  return self;
}

#pragma mark DefaultPaymentQueue implementation

- (void)addPayment:(SKPayment * _Nonnull)payment {
  [self.queue addPayment:payment];
}


- (void)finishTransaction:(nonnull SKPaymentTransaction *)transaction { 
  [self.queue finishTransaction:transaction];
}

- (void)addTransactionObserver:(nonnull id<SKPaymentTransactionObserver>)observer { 
  [self.queue addTransactionObserver:observer];
}

- (void)restoreCompletedTransactions { 
  [self.queue restoreCompletedTransactions];
}

- (void)restoreCompletedTransactionsWithApplicationUsername:(nullable NSString *)username { 
  [self.queue restoreCompletedTransactionsWithApplicationUsername:username];
}


- (id<SKPaymentQueueDelegate>) delegate API_AVAILABLE(ios(13.0), macos(10.15), watchos(6.2), visionos(1.0)) {
  return self.queue.delegate;
}

- (NSArray<SKPaymentTransaction *>*) transactions API_AVAILABLE(ios(3.0), macos(10.7), watchos(6.2), visionos(1.0)) {
  return self.queue.transactions;
}

- (SKStorefront *)storefront  API_AVAILABLE(ios(13.0)){
  return self.queue.storefront;
}

- (void)presentCodeRedemptionSheet API_AVAILABLE(ios(14.0), visionos(1.0)) API_UNAVAILABLE(tvos, macos, watchos) {
  [self.queue presentCodeRedemptionSheet];
}
- (void)showPriceConsentIfNeeded API_AVAILABLE(ios(13.4), visionos(1.0)) API_UNAVAILABLE(tvos, macos, watchos) {
  [self.queue showPriceConsentIfNeeded];
}



@synthesize storefront;

@synthesize delegate;

@synthesize transactions;

@end

@implementation TestPaymentQueue

- (void)finishTransaction:(nonnull SKPaymentTransaction *)transaction {

}

- (void)addPayment:(SKPayment * _Nonnull)payment {

}

- (void)addTransactionObserver:(nonnull id<SKPaymentTransactionObserver>)observer { 
  self.observer = observer;
}


- (void)restoreCompletedTransactions {
    [self.observer paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue*)self];
}


- (void)restoreCompletedTransactionsWithApplicationUsername:(nullable NSString *)username { 

}

- (NSArray<SKPaymentTransaction *> * _Nonnull)getUnfinishedTransactions {
  return [NSArray array];
}

- (void)presentCodeRedemptionSheet {

}
- (void)showPriceConsentIfNeeded {
  if (self.showPriceConsentIfNeededStub) {
    self.showPriceConsentIfNeededStub();
  }
}

- (void)restoreTransactions:(nullable NSString *)applicationName {
//  [self.observer paymentQueueRestoreCompletedTransactionsFinished:self];
  
}

- (void)startObservingPaymentQueue {

}

- (void)stopObservingPaymentQueue {

}

@synthesize delegate;

@synthesize transactions;

@end

#pragma mark TransactionCache implemetations
@implementation DefaultTransactionCache
- (void)addObjects:(nonnull NSArray *)objects forKey:(TransactionCacheKey)key {
  [self.cache addObjects:objects forKey:key];
}

- (void)clear {
  [self.cache clear];
}

- (nonnull NSArray *)getObjectsForKey:(TransactionCacheKey)key {
  return [self.cache getObjectsForKey:key];
}

- (nonnull instancetype)initWithCache:(nonnull FIATransactionCache *)cache {
  self = [super init];
  if (self) {
    _cache = cache;
  }
  return self;
}

@end

@implementation TestTransactionCache
- (void)addObjects:(nonnull NSArray *)objects forKey:(TransactionCacheKey)key {

}

- (void)clear {

}

- (nonnull NSArray *)getObjectsForKey:(TransactionCacheKey)key {
  return [NSArray array];
}
@end

#pragma mark MethodChannel implemetations
@implementation DefaultMethodChannel
- (void)invokeMethod:(nonnull NSString *)method arguments:(id _Nullable)arguments { 
  [self.channel invokeMethod:method arguments:arguments];
}

- (instancetype)initWithChannel:(nonnull FlutterMethodChannel *)channel {
  self = [super init];
  if (self) {
    _channel = channel;
  }
  return self;
}

@end

@implementation TestMethodChannel
- (void)invokeMethod:(nonnull NSString *)method arguments:(id _Nullable)arguments { 
  if (self.invokeMethodChannelStub) {
    self.invokeMethodChannelStub(method, arguments);
  }
}

@end


@implementation FakeSKPaymentTransaction {
  SKPayment *_payment;
}

- (instancetype)initWithMap:(NSDictionary *)map {
  self = [super init];
  if (self) {
    [self setValue:map[@"transactionIdentifier"] forKey:@"transactionIdentifier"];
    [self setValue:map[@"transactionState"] forKey:@"transactionState"];
    if (![map[@"originalTransaction"] isKindOfClass:[NSNull class]] &&
        map[@"originalTransaction"]) {
      [self setValue:[[FakeSKPaymentTransaction alloc] initWithMap:map[@"originalTransaction"]]
              forKey:@"originalTransaction"];
    }
    [self setValue:[NSDate dateWithTimeIntervalSince1970:[map[@"transactionTimeStamp"] doubleValue]]
            forKey:@"transactionDate"];
  }
  return self;
}

- (SKPayment *)payment {
  return _payment;
}

@end

