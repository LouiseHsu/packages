// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Autogenerated from Pigeon (v16.0.5), do not edit directly.
// See also: https://pub.dev/packages/pigeon
// ignore_for_file: public_member_api_docs, non_constant_identifier_names, avoid_as, unused_import, unnecessary_parenthesis, unnecessary_import, no_leading_underscores_for_local_identifiers
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;
import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:in_app_purchase_storekit/src/sk2_pigeon.g.dart';

class _TestInAppPurchase2ApiCodec extends StandardMessageCodec {
  const _TestInAppPurchase2ApiCodec();
  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is SK2PriceLocaleMessage) {
      buffer.putUint8(128);
      writeValue(buffer, value.encode());
    } else if (value is SK2ProductMessage) {
      buffer.putUint8(129);
      writeValue(buffer, value.encode());
    } else if (value is SK2SubscriptionInfoMessage) {
      buffer.putUint8(130);
      writeValue(buffer, value.encode());
    } else if (value is SK2SubscriptionOfferMessage) {
      buffer.putUint8(131);
      writeValue(buffer, value.encode());
    } else if (value is SK2SubscriptionPeriodMessage) {
      buffer.putUint8(132);
      writeValue(buffer, value.encode());
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case 128: 
        return SK2PriceLocaleMessage.decode(readValue(buffer)!);
      case 129: 
        return SK2ProductMessage.decode(readValue(buffer)!);
      case 130: 
        return SK2SubscriptionInfoMessage.decode(readValue(buffer)!);
      case 131: 
        return SK2SubscriptionOfferMessage.decode(readValue(buffer)!);
      case 132: 
        return SK2SubscriptionPeriodMessage.decode(readValue(buffer)!);
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

abstract class TestInAppPurchase2Api {
  static TestDefaultBinaryMessengerBinding? get _testBinaryMessengerBinding => TestDefaultBinaryMessengerBinding.instance;
  static const MessageCodec<Object?> pigeonChannelCodec = _TestInAppPurchase2ApiCodec();

  bool canMakePayments();

  Future<List<SK2ProductMessage?>> products(List<String?> identifiers);

  static void setup(TestInAppPurchase2Api? api, {BinaryMessenger? binaryMessenger}) {
    {
      final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchase2API.canMakePayments', pigeonChannelCodec,
          binaryMessenger: binaryMessenger);
      if (api == null) {
        _testBinaryMessengerBinding!.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(__pigeon_channel, null);
      } else {
        _testBinaryMessengerBinding!.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(__pigeon_channel, (Object? message) async {
          try {
            final bool output = api.canMakePayments();
            return <Object?>[output];
          } on PlatformException catch (e) {
            return wrapResponse(error: e);
          }          catch (e) {
            return wrapResponse(error: PlatformException(code: 'error', message: e.toString()));
          }
        });
      }
    }
    {
      final BasicMessageChannel<Object?> __pigeon_channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchase2API.products', pigeonChannelCodec,
          binaryMessenger: binaryMessenger);
      if (api == null) {
        _testBinaryMessengerBinding!.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(__pigeon_channel, null);
      } else {
        _testBinaryMessengerBinding!.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(__pigeon_channel, (Object? message) async {
          assert(message != null,
          'Argument for dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchase2API.products was null.');
          final List<Object?> args = (message as List<Object?>?)!;
          final List<String?>? arg_identifiers = (args[0] as List<Object?>?)?.cast<String?>();
          assert(arg_identifiers != null,
              'Argument for dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchase2API.products was null, expected non-null List<String?>.');
          try {
            final List<SK2ProductMessage?> output = await api.products(arg_identifiers!);
            return <Object?>[output];
          } on PlatformException catch (e) {
            return wrapResponse(error: e);
          }          catch (e) {
            return wrapResponse(error: PlatformException(code: 'error', message: e.toString()));
          }
        });
      }
    }
  }
}
