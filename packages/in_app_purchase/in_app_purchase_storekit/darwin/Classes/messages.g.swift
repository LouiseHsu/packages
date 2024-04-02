// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Autogenerated from Pigeon (v17.3.0), do not edit directly.
// See also: https://pub.dev/packages/pigeon

import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

private func wrapResult(_ result: Any?) -> [Any?] {
  return [result]
}

private func wrapError(_ error: Any) -> [Any?] {
  if let flutterError = error as? FlutterError {
    return [
      flutterError.code,
      flutterError.message,
      flutterError.details,
    ]
  }
  return [
    "\(error)",
    "\(type(of: error))",
    "Stacktrace: \(Thread.callStackSymbols)",
  ]
}

private func isNullish(_ value: Any?) -> Bool {
  return value is NSNull || value == nil
}

private func nilOrValue<T>(_ value: Any?) -> T? {
  if value is NSNull { return nil }
  return value as! T?
}

enum SKPaymentTransactionStateMessage: Int {
  /// Indicates the transaction is being processed in App Store.
  ///
  /// You should update your UI to indicate that you are waiting for the
  /// transaction to update to another state. Never complete a transaction that
  /// is still in a purchasing state.
  case purchasing = 0
  /// The user's payment has been succesfully processed.
  ///
  /// You should provide the user the content that they purchased.
  case purchased = 1
  /// The transaction failed.
  ///
  /// Check the [PaymentTransactionWrapper.error] property from
  /// [PaymentTransactionWrapper] for details.
  case failed = 2
  /// This transaction is restoring content previously purchased by the user.
  ///
  /// The previous transaction information can be obtained in
  /// [PaymentTransactionWrapper.originalTransaction] from
  /// [PaymentTransactionWrapper].
  case restored = 3
  /// The transaction is in the queue but pending external action. Wait for
  /// another callback to get the final state.
  ///
  /// You should update your UI to indicate that you are waiting for the
  /// transaction to update to another state.
  case deferred = 4
  /// Indicates the transaction is in an unspecified state.
  case unspecified = 5
}

enum SKProductDiscountTypeMessage: Int {
  /// A constant indicating the discount type is an introductory offer.
  case introductory = 0
  /// A constant indicating the discount type is a promotional offer.
  case subscription = 1
}

enum SKProductDiscountPaymentModeMessage: Int {
  /// Allows user to pay the discounted price at each payment period.
  case payAsYouGo = 0
  /// Allows user to pay the discounted price upfront and receive the product for the rest of time that was paid for.
  case payUpFront = 1
  /// User pays nothing during the discounted period.
  case freeTrial = 2
  /// Unspecified mode.
  case unspecified = 3
}

enum SKSubscriptionPeriodUnitMessage: Int {
  case day = 0
  case week = 1
  case month = 2
  case year = 3
}

/// Generated class from Pigeon that represents data sent in messages.
class SKPaymentTransactionMessage {
  init(
    payment: SKPaymentMessage,
    transactionState: SKPaymentTransactionStateMessage,
    originalTransaction: SKPaymentTransactionMessage? = nil,
    transactionTimeStamp: Double? = nil,
    transactionIdentifier: String? = nil,
    error: SKErrorMessage? = nil
  ) {
    self.payment = payment
    self.transactionState = transactionState
    self.originalTransaction = originalTransaction
    self.transactionTimeStamp = transactionTimeStamp
    self.transactionIdentifier = transactionIdentifier
    self.error = error
  }
  var payment: SKPaymentMessage
  var transactionState: SKPaymentTransactionStateMessage
  var originalTransaction: SKPaymentTransactionMessage?
  var transactionTimeStamp: Double?
  var transactionIdentifier: String?
  var error: SKErrorMessage?

  static func fromList(_ list: [Any?]) -> SKPaymentTransactionMessage? {
    let payment = SKPaymentMessage.fromList(list[0] as! [Any?])!
    let transactionState = SKPaymentTransactionStateMessage(rawValue: list[1] as! Int)!
    var originalTransaction: SKPaymentTransactionMessage? = nil
    if let originalTransactionList: [Any?] = nilOrValue(list[2]) {
      originalTransaction = SKPaymentTransactionMessage.fromList(originalTransactionList)
    }
    let transactionTimeStamp: Double? = nilOrValue(list[3])
    let transactionIdentifier: String? = nilOrValue(list[4])
    var error: SKErrorMessage? = nil
    if let errorList: [Any?] = nilOrValue(list[5]) {
      error = SKErrorMessage.fromList(errorList)
    }

    return SKPaymentTransactionMessage(
      payment: payment,
      transactionState: transactionState,
      originalTransaction: originalTransaction,
      transactionTimeStamp: transactionTimeStamp,
      transactionIdentifier: transactionIdentifier,
      error: error
    )
  }
  func toList() -> [Any?] {
    return [
      payment.toList(),
      transactionState.rawValue,
      originalTransaction?.toList(),
      transactionTimeStamp,
      transactionIdentifier,
      error?.toList(),
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKPaymentMessage {
  init(
    productIdentifier: String,
    applicationUsername: String? = nil,
    requestData: String? = nil,
    quantity: Int64,
    simulatesAskToBuyInSandbox: Bool,
    paymentDiscount: SKPaymentDiscountMessage? = nil
  ) {
    self.productIdentifier = productIdentifier
    self.applicationUsername = applicationUsername
    self.requestData = requestData
    self.quantity = quantity
    self.simulatesAskToBuyInSandbox = simulatesAskToBuyInSandbox
    self.paymentDiscount = paymentDiscount
  }
  var productIdentifier: String
  var applicationUsername: String?
  var requestData: String?
  var quantity: Int64
  var simulatesAskToBuyInSandbox: Bool
  var paymentDiscount: SKPaymentDiscountMessage?

  static func fromList(_ list: [Any?]) -> SKPaymentMessage? {
    let productIdentifier = list[0] as! String
    let applicationUsername: String? = nilOrValue(list[1])
    let requestData: String? = nilOrValue(list[2])
    let quantity = list[3] is Int64 ? list[3] as! Int64 : Int64(list[3] as! Int32)
    let simulatesAskToBuyInSandbox = list[4] as! Bool
    var paymentDiscount: SKPaymentDiscountMessage? = nil
    if let paymentDiscountList: [Any?] = nilOrValue(list[5]) {
      paymentDiscount = SKPaymentDiscountMessage.fromList(paymentDiscountList)
    }

    return SKPaymentMessage(
      productIdentifier: productIdentifier,
      applicationUsername: applicationUsername,
      requestData: requestData,
      quantity: quantity,
      simulatesAskToBuyInSandbox: simulatesAskToBuyInSandbox,
      paymentDiscount: paymentDiscount
    )
  }
  func toList() -> [Any?] {
    return [
      productIdentifier,
      applicationUsername,
      requestData,
      quantity,
      simulatesAskToBuyInSandbox,
      paymentDiscount?.toList(),
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKErrorMessage {
  init(
    code: Int64,
    domain: String,
    userInfo: [String?: Any?]? = nil
  ) {
    self.code = code
    self.domain = domain
    self.userInfo = userInfo
  }
  var code: Int64
  var domain: String
  var userInfo: [String?: Any?]?

  static func fromList(_ list: [Any?]) -> SKErrorMessage? {
    let code = list[0] is Int64 ? list[0] as! Int64 : Int64(list[0] as! Int32)
    let domain = list[1] as! String
    let userInfo: [String?: Any?]? = nilOrValue(list[2])

    return SKErrorMessage(
      code: code,
      domain: domain,
      userInfo: userInfo
    )
  }
  func toList() -> [Any?] {
    return [
      code,
      domain,
      userInfo,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKPaymentDiscountMessage {
  init(
    identifier: String,
    keyIdentifier: String,
    nonce: String,
    signature: String,
    timestamp: Int64
  ) {
    self.identifier = identifier
    self.keyIdentifier = keyIdentifier
    self.nonce = nonce
    self.signature = signature
    self.timestamp = timestamp
  }
  var identifier: String
  var keyIdentifier: String
  var nonce: String
  var signature: String
  var timestamp: Int64

  static func fromList(_ list: [Any?]) -> SKPaymentDiscountMessage? {
    let identifier = list[0] as! String
    let keyIdentifier = list[1] as! String
    let nonce = list[2] as! String
    let signature = list[3] as! String
    let timestamp = list[4] is Int64 ? list[4] as! Int64 : Int64(list[4] as! Int32)

    return SKPaymentDiscountMessage(
      identifier: identifier,
      keyIdentifier: keyIdentifier,
      nonce: nonce,
      signature: signature,
      timestamp: timestamp
    )
  }
  func toList() -> [Any?] {
    return [
      identifier,
      keyIdentifier,
      nonce,
      signature,
      timestamp,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKStorefrontMessage {
  init(
    countryCode: String,
    identifier: String
  ) {
    self.countryCode = countryCode
    self.identifier = identifier
  }
  var countryCode: String
  var identifier: String

  static func fromList(_ list: [Any?]) -> SKStorefrontMessage? {
    let countryCode = list[0] as! String
    let identifier = list[1] as! String

    return SKStorefrontMessage(
      countryCode: countryCode,
      identifier: identifier
    )
  }
  func toList() -> [Any?] {
    return [
      countryCode,
      identifier,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKProductsResponseMessage {
  init(
    products: [SKProductMessage?]? = nil,
    invalidProductIdentifiers: [String?]? = nil
  ) {
    self.products = products
    self.invalidProductIdentifiers = invalidProductIdentifiers
  }
  var products: [SKProductMessage?]?
  var invalidProductIdentifiers: [String?]?

  static func fromList(_ list: [Any?]) -> SKProductsResponseMessage? {
    let products: [SKProductMessage?]? = nilOrValue(list[0])
    let invalidProductIdentifiers: [String?]? = nilOrValue(list[1])

    return SKProductsResponseMessage(
      products: products,
      invalidProductIdentifiers: invalidProductIdentifiers
    )
  }
  func toList() -> [Any?] {
    return [
      products,
      invalidProductIdentifiers,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKProductMessage {
  init(
    productIdentifier: String,
    localizedTitle: String,
    localizedDescription: String,
    priceLocale: SKPriceLocaleMessage,
    subscriptionGroupIdentifier: String? = nil,
    price: String,
    subscriptionPeriod: SKProductSubscriptionPeriodMessage? = nil,
    introductoryPrice: SKProductDiscountMessage? = nil,
    discounts: [SKProductDiscountMessage?]? = nil
  ) {
    self.productIdentifier = productIdentifier
    self.localizedTitle = localizedTitle
    self.localizedDescription = localizedDescription
    self.priceLocale = priceLocale
    self.subscriptionGroupIdentifier = subscriptionGroupIdentifier
    self.price = price
    self.subscriptionPeriod = subscriptionPeriod
    self.introductoryPrice = introductoryPrice
    self.discounts = discounts
  }
  var productIdentifier: String
  var localizedTitle: String
  var localizedDescription: String
  var priceLocale: SKPriceLocaleMessage
  var subscriptionGroupIdentifier: String?
  var price: String
  var subscriptionPeriod: SKProductSubscriptionPeriodMessage?
  var introductoryPrice: SKProductDiscountMessage?
  var discounts: [SKProductDiscountMessage?]?

  static func fromList(_ list: [Any?]) -> SKProductMessage? {
    let productIdentifier = list[0] as! String
    let localizedTitle = list[1] as! String
    let localizedDescription = list[2] as! String
    let priceLocale = SKPriceLocaleMessage.fromList(list[3] as! [Any?])!
    let subscriptionGroupIdentifier: String? = nilOrValue(list[4])
    let price = list[5] as! String
    var subscriptionPeriod: SKProductSubscriptionPeriodMessage? = nil
    if let subscriptionPeriodList: [Any?] = nilOrValue(list[6]) {
      subscriptionPeriod = SKProductSubscriptionPeriodMessage.fromList(subscriptionPeriodList)
    }
    var introductoryPrice: SKProductDiscountMessage? = nil
    if let introductoryPriceList: [Any?] = nilOrValue(list[7]) {
      introductoryPrice = SKProductDiscountMessage.fromList(introductoryPriceList)
    }
    let discounts: [SKProductDiscountMessage?]? = nilOrValue(list[8])

    return SKProductMessage(
      productIdentifier: productIdentifier,
      localizedTitle: localizedTitle,
      localizedDescription: localizedDescription,
      priceLocale: priceLocale,
      subscriptionGroupIdentifier: subscriptionGroupIdentifier,
      price: price,
      subscriptionPeriod: subscriptionPeriod,
      introductoryPrice: introductoryPrice,
      discounts: discounts
    )
  }
  func toList() -> [Any?] {
    return [
      productIdentifier,
      localizedTitle,
      localizedDescription,
      priceLocale.toList(),
      subscriptionGroupIdentifier,
      price,
      subscriptionPeriod?.toList(),
      introductoryPrice?.toList(),
      discounts,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKPriceLocaleMessage {
  init(
    currencySymbol: String,
    currencyCode: String,
    countryCode: String
  ) {
    self.currencySymbol = currencySymbol
    self.currencyCode = currencyCode
    self.countryCode = countryCode
  }
  ///The currency symbol for the locale, e.g. $ for US locale.
  var currencySymbol: String
  ///The currency code for the locale, e.g. USD for US locale.
  var currencyCode: String
  ///The country code for the locale, e.g. US for US locale.
  var countryCode: String

  static func fromList(_ list: [Any?]) -> SKPriceLocaleMessage? {
    let currencySymbol = list[0] as! String
    let currencyCode = list[1] as! String
    let countryCode = list[2] as! String

    return SKPriceLocaleMessage(
      currencySymbol: currencySymbol,
      currencyCode: currencyCode,
      countryCode: countryCode
    )
  }
  func toList() -> [Any?] {
    return [
      currencySymbol,
      currencyCode,
      countryCode,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKProductDiscountMessage {
  init(
    price: String,
    priceLocale: SKPriceLocaleMessage,
    numberOfPeriods: Int64,
    paymentMode: SKProductDiscountPaymentModeMessage,
    subscriptionPeriod: SKProductSubscriptionPeriodMessage,
    identifier: String? = nil,
    type: SKProductDiscountTypeMessage
  ) {
    self.price = price
    self.priceLocale = priceLocale
    self.numberOfPeriods = numberOfPeriods
    self.paymentMode = paymentMode
    self.subscriptionPeriod = subscriptionPeriod
    self.identifier = identifier
    self.type = type
  }
  var price: String
  var priceLocale: SKPriceLocaleMessage
  var numberOfPeriods: Int64
  var paymentMode: SKProductDiscountPaymentModeMessage
  var subscriptionPeriod: SKProductSubscriptionPeriodMessage
  var identifier: String?
  var type: SKProductDiscountTypeMessage

  static func fromList(_ list: [Any?]) -> SKProductDiscountMessage? {
    let price = list[0] as! String
    let priceLocale = SKPriceLocaleMessage.fromList(list[1] as! [Any?])!
    let numberOfPeriods = list[2] is Int64 ? list[2] as! Int64 : Int64(list[2] as! Int32)
    let paymentMode = SKProductDiscountPaymentModeMessage(rawValue: list[3] as! Int)!
    let subscriptionPeriod = SKProductSubscriptionPeriodMessage.fromList(list[4] as! [Any?])!
    let identifier: String? = nilOrValue(list[5])
    let type = SKProductDiscountTypeMessage(rawValue: list[6] as! Int)!

    return SKProductDiscountMessage(
      price: price,
      priceLocale: priceLocale,
      numberOfPeriods: numberOfPeriods,
      paymentMode: paymentMode,
      subscriptionPeriod: subscriptionPeriod,
      identifier: identifier,
      type: type
    )
  }
  func toList() -> [Any?] {
    return [
      price,
      priceLocale.toList(),
      numberOfPeriods,
      paymentMode.rawValue,
      subscriptionPeriod.toList(),
      identifier,
      type.rawValue,
    ]
  }
}

/// Generated class from Pigeon that represents data sent in messages.
class SKProductSubscriptionPeriodMessage {
  init(
    numberOfUnits: Int64,
    unit: SKSubscriptionPeriodUnitMessage
  ) {
    self.numberOfUnits = numberOfUnits
    self.unit = unit
  }
  var numberOfUnits: Int64
  var unit: SKSubscriptionPeriodUnitMessage

  static func fromList(_ list: [Any?]) -> SKProductSubscriptionPeriodMessage? {
    let numberOfUnits = list[0] is Int64 ? list[0] as! Int64 : Int64(list[0] as! Int32)
    let unit = SKSubscriptionPeriodUnitMessage(rawValue: list[1] as! Int)!

    return SKProductSubscriptionPeriodMessage(
      numberOfUnits: numberOfUnits,
      unit: unit
    )
  }
  func toList() -> [Any?] {
    return [
      numberOfUnits,
      unit.rawValue,
    ]
  }
}

private class InAppPurchaseAPICodecReader: FlutterStandardReader {
  override func readValue(ofType type: UInt8) -> Any? {
    switch type {
    case 128:
      return SKErrorMessage.fromList(self.readValue() as! [Any?])
    case 129:
      return SKPaymentDiscountMessage.fromList(self.readValue() as! [Any?])
    case 130:
      return SKPaymentMessage.fromList(self.readValue() as! [Any?])
    case 131:
      return SKPaymentTransactionMessage.fromList(self.readValue() as! [Any?])
    case 132:
      return SKPriceLocaleMessage.fromList(self.readValue() as! [Any?])
    case 133:
      return SKProductDiscountMessage.fromList(self.readValue() as! [Any?])
    case 134:
      return SKProductMessage.fromList(self.readValue() as! [Any?])
    case 135:
      return SKProductSubscriptionPeriodMessage.fromList(self.readValue() as! [Any?])
    case 136:
      return SKProductsResponseMessage.fromList(self.readValue() as! [Any?])
    case 137:
      return SKStorefrontMessage.fromList(self.readValue() as! [Any?])
    default:
      return super.readValue(ofType: type)
    }
  }
}

private class InAppPurchaseAPICodecWriter: FlutterStandardWriter {
  override func writeValue(_ value: Any) {
    if let value = value as? SKErrorMessage {
      super.writeByte(128)
      super.writeValue(value.toList())
    } else if let value = value as? SKPaymentDiscountMessage {
      super.writeByte(129)
      super.writeValue(value.toList())
    } else if let value = value as? SKPaymentMessage {
      super.writeByte(130)
      super.writeValue(value.toList())
    } else if let value = value as? SKPaymentTransactionMessage {
      super.writeByte(131)
      super.writeValue(value.toList())
    } else if let value = value as? SKPriceLocaleMessage {
      super.writeByte(132)
      super.writeValue(value.toList())
    } else if let value = value as? SKProductDiscountMessage {
      super.writeByte(133)
      super.writeValue(value.toList())
    } else if let value = value as? SKProductMessage {
      super.writeByte(134)
      super.writeValue(value.toList())
    } else if let value = value as? SKProductSubscriptionPeriodMessage {
      super.writeByte(135)
      super.writeValue(value.toList())
    } else if let value = value as? SKProductsResponseMessage {
      super.writeByte(136)
      super.writeValue(value.toList())
    } else if let value = value as? SKStorefrontMessage {
      super.writeByte(137)
      super.writeValue(value.toList())
    } else {
      super.writeValue(value)
    }
  }
}

private class InAppPurchaseAPICodecReaderWriter: FlutterStandardReaderWriter {
  override func reader(with data: Data) -> FlutterStandardReader {
    return InAppPurchaseAPICodecReader(data: data)
  }

  override func writer(with data: NSMutableData) -> FlutterStandardWriter {
    return InAppPurchaseAPICodecWriter(data: data)
  }
}

class InAppPurchaseAPICodec: FlutterStandardMessageCodec {
  static let shared = InAppPurchaseAPICodec(readerWriter: InAppPurchaseAPICodecReaderWriter())
}

/// Generated protocol from Pigeon that represents a handler of messages from Flutter.
protocol InAppPurchaseAPI {
  /// Returns if the current device is able to make payments
  func canMakePayments() throws -> Bool
  func transactions() throws -> [SKPaymentTransactionMessage]
  func storefront() throws -> SKStorefrontMessage?
  func addPayment(paymentMap: [String: Any?]) throws
  func startProductRequest(productIdentifiers: [String], completion: @escaping (Result<SKProductsResponseMessage, Error>) -> Void)
  func finishTransaction(finishMap: [String: String?]) throws
  func restoreTransactions(applicationUserName: String?) throws
  func presentCodeRedemptionSheet() throws
  func retrieveReceiptData() throws -> String?
  func refreshReceipt(receiptProperties: [String: Any?]?, completion: @escaping (Result<Void, Error>) -> Void)
  func startObservingPaymentQueue() throws
  func stopObservingPaymentQueue() throws
  func registerPaymentQueueDelegate() throws
  func removePaymentQueueDelegate() throws
  func showPriceConsentIfNeeded() throws
}

/// Generated setup class from Pigeon to handle messages through the `binaryMessenger`.
class InAppPurchaseAPISetup {
  /// The codec used by InAppPurchaseAPI.
  static var codec: FlutterStandardMessageCodec { InAppPurchaseAPICodec.shared }
  /// Sets up an instance of `InAppPurchaseAPI` to handle messages through the `binaryMessenger`.
  static func setUp(binaryMessenger: FlutterBinaryMessenger, api: InAppPurchaseAPI?) {
    /// Returns if the current device is able to make payments
    let canMakePaymentsChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.canMakePayments", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      canMakePaymentsChannel.setMessageHandler { _, reply in
        do {
          let result = try api.canMakePayments()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      canMakePaymentsChannel.setMessageHandler(nil)
    }
    let transactionsChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.transactions", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      transactionsChannel.setMessageHandler { _, reply in
        do {
          let result = try api.transactions()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      transactionsChannel.setMessageHandler(nil)
    }
    let storefrontChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.storefront", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      storefrontChannel.setMessageHandler { _, reply in
        do {
          let result = try api.storefront()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      storefrontChannel.setMessageHandler(nil)
    }
    let addPaymentChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.addPayment", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      addPaymentChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let paymentMapArg = args[0] as! [String: Any?]
        do {
          try api.addPayment(paymentMap: paymentMapArg)
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      addPaymentChannel.setMessageHandler(nil)
    }
    let startProductRequestChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.startProductRequest", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      startProductRequestChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let productIdentifiersArg = args[0] as! [String]
        api.startProductRequest(productIdentifiers: productIdentifiersArg) { result in
          switch result {
          case .success(let res):
            reply(wrapResult(res))
          case .failure(let error):
            reply(wrapError(error))
          }
        }
      }
    } else {
      startProductRequestChannel.setMessageHandler(nil)
    }
    let finishTransactionChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.finishTransaction", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      finishTransactionChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let finishMapArg = args[0] as! [String: String?]
        do {
          try api.finishTransaction(finishMap: finishMapArg)
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      finishTransactionChannel.setMessageHandler(nil)
    }
    let restoreTransactionsChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.restoreTransactions", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      restoreTransactionsChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let applicationUserNameArg: String? = nilOrValue(args[0])
        do {
          try api.restoreTransactions(applicationUserName: applicationUserNameArg)
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      restoreTransactionsChannel.setMessageHandler(nil)
    }
    let presentCodeRedemptionSheetChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.presentCodeRedemptionSheet", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      presentCodeRedemptionSheetChannel.setMessageHandler { _, reply in
        do {
          try api.presentCodeRedemptionSheet()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      presentCodeRedemptionSheetChannel.setMessageHandler(nil)
    }
    let retrieveReceiptDataChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.retrieveReceiptData", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      retrieveReceiptDataChannel.setMessageHandler { _, reply in
        do {
          let result = try api.retrieveReceiptData()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      retrieveReceiptDataChannel.setMessageHandler(nil)
    }
    let refreshReceiptChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.refreshReceipt", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      refreshReceiptChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let receiptPropertiesArg: [String: Any?]? = nilOrValue(args[0])
        api.refreshReceipt(receiptProperties: receiptPropertiesArg) { result in
          switch result {
          case .success:
            reply(wrapResult(nil))
          case .failure(let error):
            reply(wrapError(error))
          }
        }
      }
    } else {
      refreshReceiptChannel.setMessageHandler(nil)
    }
    let startObservingPaymentQueueChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.startObservingPaymentQueue", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      startObservingPaymentQueueChannel.setMessageHandler { _, reply in
        do {
          try api.startObservingPaymentQueue()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      startObservingPaymentQueueChannel.setMessageHandler(nil)
    }
    let stopObservingPaymentQueueChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.stopObservingPaymentQueue", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      stopObservingPaymentQueueChannel.setMessageHandler { _, reply in
        do {
          try api.stopObservingPaymentQueue()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      stopObservingPaymentQueueChannel.setMessageHandler(nil)
    }
    let registerPaymentQueueDelegateChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.registerPaymentQueueDelegate", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      registerPaymentQueueDelegateChannel.setMessageHandler { _, reply in
        do {
          try api.registerPaymentQueueDelegate()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      registerPaymentQueueDelegateChannel.setMessageHandler(nil)
    }
    let removePaymentQueueDelegateChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.removePaymentQueueDelegate", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      removePaymentQueueDelegateChannel.setMessageHandler { _, reply in
        do {
          try api.removePaymentQueueDelegate()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      removePaymentQueueDelegateChannel.setMessageHandler(nil)
    }
    let showPriceConsentIfNeededChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.showPriceConsentIfNeeded", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      showPriceConsentIfNeededChannel.setMessageHandler { _, reply in
        do {
          try api.showPriceConsentIfNeeded()
          reply(wrapResult(nil))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      showPriceConsentIfNeededChannel.setMessageHandler(nil)
    }
  }
}
