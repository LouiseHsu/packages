import Foundation
import StoreKit

@available(iOS 12.2, *)
class FIAObjectTranslator {
  static func getMap(from locale: NSLocale?) -> [String: Any]? {
      guard let locale = locale else {
          return nil
      }

      var map: [String: Any] = [:]

      map["currencySymbol"] = locale.object(forKey: NSLocale.Key.currencySymbol) ?? nil
      map["currencyCode"] = locale.object(forKey: NSLocale.Key.currencyCode) ?? nil
      map["countryCode"] = locale.object(forKey: NSLocale.Key.countryCode) ?? nil

      return map
  }

  static func getMap(from product: SKProduct?) -> [String: Any]? {
      guard let product = product else {
          return nil
      }

      var map: [String: Any] = [
          "localizedDescription": product.localizedDescription,
          "localizedTitle": product.localizedTitle,
          "productIdentifier": product.productIdentifier,
          "price": product.price.description
      ]

      // TODO: NSLocale is a complex object, want to see the actual need of getting this expanded to a map.
      // Matching android to only get the currencySymbol for now.
      // https://github.com/flutter/flutter/issues/26610
      map["priceLocale"] = FIAObjectTranslator.getMap(from: product.priceLocale) ?? NSNull()
      map["subscriptionPeriod"] = FIAObjectTranslator.getMap(from: product.subscriptionPeriod) ?? NSNull()
      map["introductoryPrice"] = FIAObjectTranslator.getMap(from: product.introductoryPrice) ?? NSNull()

      if #available(iOS 12.2, *) {
          map["discounts"] = FIAObjectTranslator.getMapArray(from: product.discounts)
      }

      map["subscriptionGroupIdentifier"] = product.subscriptionGroupIdentifier ?? NSNull()

      return map
  }

  static func getMap(from transaction: SKPaymentTransaction?) -> [String: Any] {
      guard let transaction = transaction else {
        fatalError();
      }

      var map: [String: Any] = [
        "error": transaction.error != nil ? getMap(from: transaction.error as! NSError) : NSNull(),
          "payment": getMap(from: transaction.payment),
          "originalTransaction": transaction.original != nil ? getMap(from: transaction.original) : NSNull(),
          "transactionTimeStamp": transaction.transactionDate != nil ? transaction.transactionDate!.timeIntervalSince1970 : NSNull(),
          "transactionIdentifier": transaction.transactionIdentifier ?? NSNull(),
          "transactionState": transaction.transactionState.rawValue
      ]

      return map
  }

  static func getMap(from payment: SKPayment) -> [String: Any] {
      return [
          "productIdentifier": payment.productIdentifier,
          "applicationUsername": payment.applicationUsername ?? nil,
          "requestData": payment.requestData != nil ? String(data: payment.requestData!, encoding: .utf8) : nil,
          "quantity": payment.quantity,
          "simulatesAskToBuyInSandbox": payment.simulatesAskToBuyInSandbox,
          "paymentDiscount": payment.paymentDiscount != nil ? getMap(from: payment.paymentDiscount!) : NSNull()
      ]
  }

  static func getMap(from paymentDiscount: SKPaymentDiscount) -> [String: Any] {
      return [
          "identifier": paymentDiscount.identifier,
          "keyIdentifier": paymentDiscount.keyIdentifier,
          "nonce": paymentDiscount.nonce.uuidString,
          "signature": paymentDiscount.signature,
          "timestamp": paymentDiscount.timestamp
      ]
  }

  static func getMap(from error: NSError) -> [String: Any]? {
    return [
        "code": "\(error.code)",
        "domain": error.domain,
        "userInfo": encodeNSErrorUserInfo(error.userInfo)
    ]
  }

  static func encodeNSErrorUserInfo(_ value: Any) -> Any {
      switch value {
        case let error as NSError:
            return getMap(from: error) as Any
        case let url as NSURL:
            return url.absoluteString ?? ""
        case let number as NSNumber:
            return number
        case let string as NSString:
            return string
        case let array as [Any]:
            return array.map { encodeNSErrorUserInfo($0) }
        case let dictionary as [String: Any]:
            var encodedDictionary = [String: Any]()
            for (key, value) in dictionary {
                encodedDictionary[key] = encodeNSErrorUserInfo(value)
            }
            return encodedDictionary
      default:
          return "Unable to encode native userInfo object of type \(type(of: value)) to map. Please submit an issue at https://github.com/flutter/flutter/issues/new with the title \"[in_app_purchase_storekit] Unable to encode userInfo of type \(type(of: value))\" and add reproduction steps and the error details in the description field."
      }
  }

  static func getSKPaymentDiscount(from map: [String: Any]) throws -> SKPaymentDiscount {
    guard !map.isEmpty else {
      throw FlutterError(
        code: "INVALID_ARGUMENT", message: "The discount map is empty.", details: nil)
    }

    guard let identifier = map["identifier"] as? String, !identifier.isEmpty else {
      throw FlutterError(
        code: "INVALID_ARGUMENT",
        message: "When specifying a payment discount the 'identifier' field is mandatory.",
        details: nil)
    }

    guard let keyIdentifier = map["keyIdentifier"] as? String, !keyIdentifier.isEmpty else {
      throw FlutterError(
        code: "INVALID_ARGUMENT",
        message: "When specifying a payment discount the 'keyIdentifier' field is mandatory.",
        details: nil)
    }

    guard let nonceString = map["nonce"] as? String, !nonceString.isEmpty,
      let nonce = UUID(uuidString: nonceString)
    else {
      throw FlutterError(
        code: "INVALID_ARGUMENT",
        message: "When specifying a payment discount the 'nonce' field is mandatory.", details: nil)
    }

    guard let signature = map["signature"] as? String, !signature.isEmpty else {
      throw FlutterError(
        code: "INVALID_ARGUMENT",
        message: "When specifying a payment discount the 'signature' field is mandatory.",
        details: nil)
    }

    guard let timestamp = map["timestamp"] as? NSNumber, timestamp.int64Value > 0 else {
      throw FlutterError(
        code: "INVALID_ARGUMENT",
        message: "When specifying a payment discount the 'timestamp' field is mandatory.",
        details: nil)
    }

    let discount = SKPaymentDiscount(
      identifier: identifier,
      keyIdentifier: keyIdentifier,
      nonce: nonce,
      signature: signature,
      timestamp: timestamp
    )

    return discount
  }

  static func convertTransactionToPigeon(transaction: SKPaymentTransaction?)
    -> SKPaymentTransactionMessage?
  {
    guard let transaction = transaction else {
      return nil
    }

    let msg = SKPaymentTransactionMessage(
      payment: convertPaymentToPigeon(payment: transaction.payment),
      transactionState: convertTransactionStateToPigeon(state: transaction.transactionState),
      originalTransaction: transaction.original != nil
        ? convertTransactionToPigeon(transaction: transaction.original) : nil,
      transactionTimeStamp: Double(transaction.transactionDate!.timeIntervalSince1970),
      transactionIdentifier: transaction.transactionIdentifier,
      error: convertSKErrorToPigeon(error: transaction.error as NSError?)
    )
    return msg
  }

  static func convertSKErrorToPigeon(error: NSError?) -> SKErrorMessage? {
    guard let error = error else {
      return nil
    }

    var userInfo = [String: Any]()
    for (key, value) in error.userInfo {
      userInfo[key] = encodeNSErrorUserInfo(value: value)
    }

    let msg = SKErrorMessage(
      code: Int64(error.code),
      domain: error.domain,
      userInfo: userInfo
    )
    return msg
  }

  static func convertTransactionStateToPigeon(state: SKPaymentTransactionState)
    -> SKPaymentTransactionStateMessage
  {
    switch state {
    case .purchasing:
      return .purchasing
    case .purchased:
      return .purchased
    case .failed:
      return .failed
    case .restored:
      return .restored
    case .deferred:
      return .deferred
    @unknown default:
      fatalError("Unknown transaction state")
    }
  }

  static func convertPaymentToPigeon(payment: SKPayment?) -> SKPaymentMessage {
    guard let payment = payment else {
      fatalError()
    }

    guard let requestData = payment.requestData else {
      fatalError()
    }

    let msg = SKPaymentMessage(
      productIdentifier: payment.productIdentifier,
      applicationUsername: payment.applicationUsername,
      requestData: String(data: requestData, encoding: .utf8),
      quantity: Int64(payment.quantity),
      simulatesAskToBuyInSandbox: payment.simulatesAskToBuyInSandbox,
      paymentDiscount: convertPaymentDiscountToPigeon(discount: payment.paymentDiscount)
    )
    return msg
  }

  static func convertPaymentDiscountToPigeon(discount: SKPaymentDiscount?)
    -> SKPaymentDiscountMessage?
  {
    guard let discount = discount else {
      return nil
    }

    let msg = SKPaymentDiscountMessage(
      identifier: discount.identifier,
      keyIdentifier: discount.keyIdentifier,
      nonce: discount.nonce.uuidString,
      signature: discount.signature,
      timestamp: Int64(discount.timestamp.intValue)
    )
    return msg
  }

  @available(iOS 13.0, *)
  static func convertStorefrontToPigeon(storefront: SKStorefront?) -> SKStorefrontMessage {
    guard let storefront = storefront else {
      fatalError()
    }

    let msg = SKStorefrontMessage(
      countryCode: storefront.countryCode,
      identifier: storefront.identifier
    )
    return msg
  }

  static func convertSKProductSubscriptionPeriodToPigeon(period: SKProductSubscriptionPeriod?)
    -> SKProductSubscriptionPeriodMessage
  {
    guard let period = period else {
      fatalError()
    }

    let unit: SKSubscriptionPeriodUnitMessage
    switch period.unit {
    case .day:
      unit = .day
    case .week:
      unit = .week
    case .month:
      unit = .month
    case .year:
      unit = .year
    @unknown default:
      fatalError("Unknown subscription period unit")
    }

    let msg = SKProductSubscriptionPeriodMessage(
      numberOfUnits: Int64(period.numberOfUnits),
      unit: unit
    )
    return msg
  }

  static func convertProductDiscountToPigeon(productDiscount: SKProductDiscount?)
    -> SKProductDiscountMessage?
  {
    guard let productDiscount = productDiscount else {
      return nil
    }

    let paymentMode: SKProductDiscountPaymentModeMessage
    switch productDiscount.paymentMode {
    case .freeTrial:
      paymentMode = .freeTrial
    case .payAsYouGo:
      paymentMode = .payAsYouGo
    case .payUpFront:
      paymentMode = .payUpFront
    @unknown default:
      fatalError("Unknown payment mode")
    }

    let type: SKProductDiscountTypeMessage
    switch productDiscount.type {
    case .introductory:
      type = .introductory
    case .subscription:
      type = .subscription
    @unknown default:
      fatalError("Unknown product discount type")
    }

    let msg = SKProductDiscountMessage(
      price: productDiscount.price.description,
      priceLocale: convertNSLocaleToPigeon(locale: productDiscount.priceLocale as NSLocale),
      numberOfPeriods: Int64(productDiscount.numberOfPeriods),
      paymentMode: paymentMode,
      subscriptionPeriod: convertSKProductSubscriptionPeriodToPigeon(
        period: productDiscount.subscriptionPeriod),
      identifier: productDiscount.identifier,
      type: type
    )
    return msg
  }

  static func convertNSLocaleToPigeon(locale: NSLocale?) -> SKPriceLocaleMessage {
    guard let locale = locale else {
      fatalError()
    }

    let msg = SKPriceLocaleMessage(
      currencySymbol: locale.currencySymbol,
      currencyCode: locale.currencyCode!,
      countryCode: locale.countryCode!
    )
    return msg
  }

  static func convertProductToPigeon(product: SKProduct?) -> SKProductMessage? {
    guard let product = product else {
      return nil
    }

    let skProductDiscounts = product.discounts
    let pigeonProductDiscounts = skProductDiscounts.map {
      convertProductDiscountToPigeon(productDiscount: $0)
    }

    let msg = SKProductMessage(
      productIdentifier: product.productIdentifier,
      localizedTitle: product.localizedTitle,
      localizedDescription: product.localizedDescription,
      priceLocale: convertNSLocaleToPigeon(locale: product.priceLocale as NSLocale),
      subscriptionGroupIdentifier: product.subscriptionGroupIdentifier,
      price: product.price.description,
      subscriptionPeriod: convertSKProductSubscriptionPeriodToPigeon(
        period: product.subscriptionPeriod),
      introductoryPrice: convertProductDiscountToPigeon(productDiscount: product.introductoryPrice),
      discounts: pigeonProductDiscounts
    )
    return msg
  }

  static func convertProductsResponseToPigeon(productsResponse: SKProductsResponse?)
    -> SKProductsResponseMessage?
  {
    guard let productsResponse = productsResponse else {
      return nil
    }

    let skProducts = productsResponse.products
    let pigeonProducts = skProducts.map { convertProductToPigeon(product: $0) }

    let msg = SKProductsResponseMessage(
      products: pigeonProducts,
      invalidProductIdentifiers: productsResponse.invalidProductIdentifiers
    )
    return msg
  }

  // Assuming encodeNSErrorUserInfo is a method that encodes NSError user info
  static func encodeNSErrorUserInfo(value: Any) -> Any {
    // Implementation of encoding NSError user info
    // This is a placeholder, actual implementation needed
    return value
  }
}
