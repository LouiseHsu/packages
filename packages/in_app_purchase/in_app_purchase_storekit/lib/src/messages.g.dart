// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Autogenerated from Pigeon (v16.0.4), do not edit directly.
// See also: https://pub.dev/packages/pigeon
// ignore_for_file: public_member_api_docs, non_constant_identifier_names, avoid_as, unused_import, unnecessary_parenthesis, prefer_null_aware_operators, omit_local_variable_types, unused_shown_name, unnecessary_import, no_leading_underscores_for_local_identifiers

import 'dart:async';
import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;

import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;
import 'package:flutter/services.dart';

PlatformException _createConnectionError(String channelName) {
  return PlatformException(
    code: 'channel-error',
    message: 'Unable to establish connection on channel: "$channelName".',
  );
}

List<Object?> wrapResponse({Object? result, PlatformException? error, bool empty = false}) {
  if (empty) {
    return <Object?>[];
  }
  if (error == null) {
    return <Object?>[result];
  }
  return <Object?>[error.code, error.message, error.details];
}

enum SKPaymentTransactionStateMessage {
  /// Indicates the transaction is being processed in App Store.
  ///
  /// You should update your UI to indicate that you are waiting for the
  /// transaction to update to another state. Never complete a transaction that
  /// is still in a purchasing state.
  purchasing,
  /// The user's payment has been succesfully processed.
  ///
  /// You should provide the user the content that they purchased.
  purchased,
  /// The transaction failed.
  ///
  /// Check the [PaymentTransactionWrapper.error] property from
  /// [PaymentTransactionWrapper] for details.
  failed,
  /// This transaction is restoring content previously purchased by the user.
  ///
  /// The previous transaction information can be obtained in
  /// [PaymentTransactionWrapper.originalTransaction] from
  /// [PaymentTransactionWrapper].
  restored,
  /// The transaction is in the queue but pending external action. Wait for
  /// another callback to get the final state.
  ///
  /// You should update your UI to indicate that you are waiting for the
  /// transaction to update to another state.
  deferred,
  /// Indicates the transaction is in an unspecified state.
  unspecified,
}

enum SKProductDiscountTypeMessage {
  /// A constant indicating the discount type is an introductory offer.
  introductory,
  /// A constant indicating the discount type is a promotional offer.
  subscription,
}

enum SKProductDiscountPaymentModeMessage {
  /// Allows user to pay the discounted price at each payment period.
  payAsYouGo,
  /// Allows user to pay the discounted price upfront and receive the product for the rest of time that was paid for.
  payUpFront,
  /// User pays nothing during the discounted period.
  freeTrial,
  /// Unspecified mode.
  unspecified,
}

enum SKSubscriptionPeriodUnitMessage {
  day,
  week,
  month,
  year,
}

class SKPaymentTransactionMessage {
  SKPaymentTransactionMessage({
    required this.payment,
    required this.transactionState,
    this.originalTransaction,
    this.transactionTimeStamp,
    this.transactionIdentifier,
    this.error,
  });

  SKPaymentMessage payment;

  SKPaymentTransactionStateMessage transactionState;

  SKPaymentTransactionMessage? originalTransaction;

  double? transactionTimeStamp;

  String? transactionIdentifier;

  SKErrorMessage? error;

  Object encode() {
    return <Object?>[
      payment.encode(),
      transactionState.index,
      originalTransaction?.encode(),
      transactionTimeStamp,
      transactionIdentifier,
      error?.encode(),
    ];
  }

  static SKPaymentTransactionMessage decode(Object result) {
    result as List<Object?>;
    return SKPaymentTransactionMessage(
      payment: SKPaymentMessage.decode(result[0]! as List<Object?>),
      transactionState: SKPaymentTransactionStateMessage.values[result[1]! as int],
      originalTransaction: result[2] != null
          ? SKPaymentTransactionMessage.decode(result[2]! as List<Object?>)
          : null,
      transactionTimeStamp: result[3] as double?,
      transactionIdentifier: result[4] as String?,
      error: result[5] != null
          ? SKErrorMessage.decode(result[5]! as List<Object?>)
          : null,
    );
  }
}

class SKPaymentMessage {
  SKPaymentMessage({
    required this.productIdentifier,
    this.applicationUsername,
    this.requestData,
    this.quantity = 1,
    this.simulatesAskToBuyInSandbox = false,
    this.paymentDiscount,
  });

  String productIdentifier;

  String? applicationUsername;

  String? requestData;

  int quantity;

  bool simulatesAskToBuyInSandbox;

  SKPaymentDiscountMessage? paymentDiscount;

  Object encode() {
    return <Object?>[
      productIdentifier,
      applicationUsername,
      requestData,
      quantity,
      simulatesAskToBuyInSandbox,
      paymentDiscount?.encode(),
    ];
  }

  static SKPaymentMessage decode(Object result) {
    result as List<Object?>;
    return SKPaymentMessage(
      productIdentifier: result[0]! as String,
      applicationUsername: result[1] as String?,
      requestData: result[2] as String?,
      quantity: result[3]! as int,
      simulatesAskToBuyInSandbox: result[4]! as bool,
      paymentDiscount: result[5] != null
          ? SKPaymentDiscountMessage.decode(result[5]! as List<Object?>)
          : null,
    );
  }
}

class SKErrorMessage {
  SKErrorMessage({
    required this.code,
    required this.domain,
    this.userInfo,
  });

  int code;

  String domain;

  Map<String?, Object?>? userInfo;

  Object encode() {
    return <Object?>[
      code,
      domain,
      userInfo,
    ];
  }

  static SKErrorMessage decode(Object result) {
    result as List<Object?>;
    return SKErrorMessage(
      code: result[0]! as int,
      domain: result[1]! as String,
      userInfo: (result[2] as Map<Object?, Object?>?)?.cast<String?, Object?>(),
    );
  }
}

class SKPaymentDiscountMessage {
  SKPaymentDiscountMessage({
    required this.identifier,
    required this.keyIdentifier,
    required this.nonce,
    required this.signature,
    required this.timestamp,
  });

  String identifier;

  String keyIdentifier;

  String nonce;

  String signature;

  int timestamp;

  Object encode() {
    return <Object?>[
      identifier,
      keyIdentifier,
      nonce,
      signature,
      timestamp,
    ];
  }

  static SKPaymentDiscountMessage decode(Object result) {
    result as List<Object?>;
    return SKPaymentDiscountMessage(
      identifier: result[0]! as String,
      keyIdentifier: result[1]! as String,
      nonce: result[2]! as String,
      signature: result[3]! as String,
      timestamp: result[4]! as int,
    );
  }
}

class SKStorefrontMessage {
  SKStorefrontMessage({
    required this.countryCode,
    required this.identifier,
  });

  String countryCode;

  String identifier;

  Object encode() {
    return <Object?>[
      countryCode,
      identifier,
    ];
  }

  static SKStorefrontMessage decode(Object result) {
    result as List<Object?>;
    return SKStorefrontMessage(
      countryCode: result[0]! as String,
      identifier: result[1]! as String,
    );
  }
}

class SKProductsResponseMessage {
  SKProductsResponseMessage({
    this.products,
    this.invalidProductIdentifiers,
  });

  List<SKProductMessage?>? products;

  List<String?>? invalidProductIdentifiers;

  Object encode() {
    return <Object?>[
      products,
      invalidProductIdentifiers,
    ];
  }

  static SKProductsResponseMessage decode(Object result) {
    result as List<Object?>;
    return SKProductsResponseMessage(
      products: (result[0] as List<Object?>?)?.cast<SKProductMessage?>(),
      invalidProductIdentifiers: (result[1] as List<Object?>?)?.cast<String?>(),
    );
  }
}

class SKProductMessage {
  SKProductMessage({
    required this.productIdentifier,
    required this.localizedTitle,
    required this.localizedDescription,
    required this.priceLocale,
    this.subscriptionGroupIdentifier,
    required this.price,
    this.subscriptionPeriod,
    this.introductoryPrice,
    this.discounts,
  });

  String productIdentifier;

  String localizedTitle;

  String localizedDescription;

  SKPriceLocaleMessage priceLocale;

  String? subscriptionGroupIdentifier;

  String price;

  SKProductSubscriptionPeriodMessage? subscriptionPeriod;

  SKProductDiscountMessage? introductoryPrice;

  List<SKProductDiscountMessage?>? discounts;

  Object encode() {
    return <Object?>[
      productIdentifier,
      localizedTitle,
      localizedDescription,
      priceLocale.encode(),
      subscriptionGroupIdentifier,
      price,
      subscriptionPeriod?.encode(),
      introductoryPrice?.encode(),
      discounts,
    ];
  }

  static SKProductMessage decode(Object result) {
    result as List<Object?>;
    return SKProductMessage(
      productIdentifier: result[0]! as String,
      localizedTitle: result[1]! as String,
      localizedDescription: result[2]! as String,
      priceLocale: SKPriceLocaleMessage.decode(result[3]! as List<Object?>),
      subscriptionGroupIdentifier: result[4] as String?,
      price: result[5]! as String,
      subscriptionPeriod: result[6] != null
          ? SKProductSubscriptionPeriodMessage.decode(result[6]! as List<Object?>)
          : null,
      introductoryPrice: result[7] != null
          ? SKProductDiscountMessage.decode(result[7]! as List<Object?>)
          : null,
      discounts: (result[8] as List<Object?>?)?.cast<SKProductDiscountMessage?>(),
    );
  }
}

class SKPriceLocaleMessage {
  SKPriceLocaleMessage({
    required this.currencySymbol,
    required this.currencyCode,
    required this.countryCode,
  });

  ///The currency symbol for the locale, e.g. $ for US locale.
  String currencySymbol;

  ///The currency code for the locale, e.g. USD for US locale.
  String currencyCode;

  ///The country code for the locale, e.g. US for US locale.
  String countryCode;

  Object encode() {
    return <Object?>[
      currencySymbol,
      currencyCode,
      countryCode,
    ];
  }

  static SKPriceLocaleMessage decode(Object result) {
    result as List<Object?>;
    return SKPriceLocaleMessage(
      currencySymbol: result[0]! as String,
      currencyCode: result[1]! as String,
      countryCode: result[2]! as String,
    );
  }
}

class SKProductDiscountMessage {
  SKProductDiscountMessage({
    required this.price,
    required this.priceLocale,
    required this.numberOfPeriods,
    required this.paymentMode,
    required this.subscriptionPeriod,
    this.identifier,
    required this.type,
  });

  String price;

  SKPriceLocaleMessage priceLocale;

  int numberOfPeriods;

  SKProductDiscountPaymentModeMessage paymentMode;

  SKProductSubscriptionPeriodMessage subscriptionPeriod;

  String? identifier;

  SKProductDiscountTypeMessage type;

  Object encode() {
    return <Object?>[
      price,
      priceLocale.encode(),
      numberOfPeriods,
      paymentMode.index,
      subscriptionPeriod.encode(),
      identifier,
      type.index,
    ];
  }

  static SKProductDiscountMessage decode(Object result) {
    result as List<Object?>;
    return SKProductDiscountMessage(
      price: result[0]! as String,
      priceLocale: SKPriceLocaleMessage.decode(result[1]! as List<Object?>),
      numberOfPeriods: result[2]! as int,
      paymentMode: SKProductDiscountPaymentModeMessage.values[result[3]! as int],
      subscriptionPeriod: SKProductSubscriptionPeriodMessage.decode(result[4]! as List<Object?>),
      identifier: result[5] as String?,
      type: SKProductDiscountTypeMessage.values[result[6]! as int],
    );
  }
}

class SKProductSubscriptionPeriodMessage {
  SKProductSubscriptionPeriodMessage({
    required this.numberOfUnits,
    required this.unit,
  });

  int numberOfUnits;

  SKSubscriptionPeriodUnitMessage unit;

  Object encode() {
    return <Object?>[
      numberOfUnits,
      unit.index,
    ];
  }

  static SKProductSubscriptionPeriodMessage decode(Object result) {
    result as List<Object?>;
    return SKProductSubscriptionPeriodMessage(
      numberOfUnits: result[0]! as int,
      unit: SKSubscriptionPeriodUnitMessage.values[result[1]! as int],
    );
  }
}

class _InAppPurchaseAPICodec extends StandardMessageCodec {
  const _InAppPurchaseAPICodec();
  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is SKErrorMessage) {
      buffer.putUint8(128);
      writeValue(buffer, value.encode());
    } else if (value is SKPaymentDiscountMessage) {
      buffer.putUint8(129);
      writeValue(buffer, value.encode());
    } else if (value is SKPaymentMessage) {
      buffer.putUint8(130);
      writeValue(buffer, value.encode());
    } else if (value is SKPaymentTransactionMessage) {
      buffer.putUint8(131);
      writeValue(buffer, value.encode());
    } else if (value is SKPriceLocaleMessage) {
      buffer.putUint8(132);
      writeValue(buffer, value.encode());
    } else if (value is SKProductDiscountMessage) {
      buffer.putUint8(133);
      writeValue(buffer, value.encode());
    } else if (value is SKProductMessage) {
      buffer.putUint8(134);
      writeValue(buffer, value.encode());
    } else if (value is SKProductSubscriptionPeriodMessage) {
      buffer.putUint8(135);
      writeValue(buffer, value.encode());
    } else if (value is SKProductsResponseMessage) {
      buffer.putUint8(136);
      writeValue(buffer, value.encode());
    } else if (value is SKStorefrontMessage) {
      buffer.putUint8(137);
      writeValue(buffer, value.encode());
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case 128: 
        return SKErrorMessage.decode(readValue(buffer)!);
      case 129: 
        return SKPaymentDiscountMessage.decode(readValue(buffer)!);
      case 130: 
        return SKPaymentMessage.decode(readValue(buffer)!);
      case 131: 
        return SKPaymentTransactionMessage.decode(readValue(buffer)!);
      case 132: 
        return SKPriceLocaleMessage.decode(readValue(buffer)!);
      case 133: 
        return SKProductDiscountMessage.decode(readValue(buffer)!);
      case 134: 
        return SKProductMessage.decode(readValue(buffer)!);
      case 135: 
        return SKProductSubscriptionPeriodMessage.decode(readValue(buffer)!);
      case 136: 
        return SKProductsResponseMessage.decode(readValue(buffer)!);
      case 137: 
        return SKStorefrontMessage.decode(readValue(buffer)!);
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

class InAppPurchaseAPI {
  /// Constructor for [InAppPurchaseAPI].  The [binaryMessenger] named argument is
  /// available for dependency injection.  If it is left null, the default
  /// BinaryMessenger will be used which routes to the host platform.
  InAppPurchaseAPI({BinaryMessenger? binaryMessenger})
      : __pigeon_binaryMessenger = binaryMessenger;
  final BinaryMessenger? __pigeon_binaryMessenger;

  static const MessageCodec<Object?> pigeonChannelCodec = _InAppPurchaseAPICodec();

  /// Returns if the current device is able to make payments
  Future<bool> canMakePayments() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.canMakePayments';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else if (__pigeon_replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (__pigeon_replyList[0] as bool?)!;
    }
  }

  Future<List<SKPaymentTransactionMessage?>> transactions() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.transactions';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else if (__pigeon_replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (__pigeon_replyList[0] as List<Object?>?)!.cast<SKPaymentTransactionMessage?>();
    }
  }

  Future<SKStorefrontMessage?> storefront() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.storefront';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return (__pigeon_replyList[0] as SKStorefrontMessage?);
    }
  }

  Future<void> addPayment(Map<String?, Object?> paymentMap) async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.addPayment';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(<Object?>[paymentMap]) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<SKProductsResponseMessage> startProductRequest(List<String?> productIdentifiers) async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.startProductRequest';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(<Object?>[productIdentifiers]) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else if (__pigeon_replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (__pigeon_replyList[0] as SKProductsResponseMessage?)!;
    }
  }

  Future<void> finishTransaction(Map<String?, String?> finishMap) async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.finishTransaction';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(<Object?>[finishMap]) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> restoreTransactions(String? applicationUserName) async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.restoreTransactions';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(<Object?>[applicationUserName]) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> presentCodeRedemptionSheet() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.presentCodeRedemptionSheet';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<String?> retrieveReceiptData() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.retrieveReceiptData';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return (__pigeon_replyList[0] as String?);
    }
  }

  Future<void> refreshReceipt({Map<String?, Object?>? receiptProperties}) async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.refreshReceipt';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(<Object?>[receiptProperties]) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> startObservingPaymentQueue() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.startObservingPaymentQueue';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> stopObservingPaymentQueue() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.stopObservingPaymentQueue';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> registerPaymentQueueDelegate() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.registerPaymentQueueDelegate';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> removePaymentQueueDelegate() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.removePaymentQueueDelegate';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> showPriceConsentIfNeeded() async {
    const String __pigeon_channelName = 'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchaseAPI.showPriceConsentIfNeeded';
    final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
      __pigeon_channelName,
      pigeonChannelCodec,
      binaryMessenger: __pigeon_binaryMessenger,
    );
    final List<Object?>? __pigeon_replyList =
        await __pigeon_channel.send(null) as List<Object?>?;
    if (__pigeon_replyList == null) {
      throw _createConnectionError(__pigeon_channelName);
    } else if (__pigeon_replyList.length > 1) {
      throw PlatformException(
        code: __pigeon_replyList[0]! as String,
        message: __pigeon_replyList[1] as String?,
        details: __pigeon_replyList[2],
      );
    } else {
      return;
    }
  }
}
