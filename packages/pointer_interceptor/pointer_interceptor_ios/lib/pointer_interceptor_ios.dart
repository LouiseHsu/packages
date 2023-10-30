// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:pointer_interceptor_platform_interface/src/pointer_interceptor_platform.dart';

/// The iOS implementation of the [PointerInterceptorPlatform]
class PointerInterceptorIOSPlugin extends PointerInterceptorPlatform {
  static void registerWith() {
    // platformViewRegistry.registerViewFactory('plugins.flutter.dev/pointer_interceptor_ios', viewFactory)
    PointerInterceptorPlatform.instance = PointerInterceptorIOSPlugin();
  }

  @override
  Widget buildWidget(
      {required Widget child,
        bool intercepting = true,
        bool debug = false,
        Key? key}) {
    return Stack(alignment: Alignment.center, children: [
      Positioned.fill(
          child: UiKitView(
            viewType: 'plugins.flutter.dev/pointer_interceptor_ios',
            creationParams: {
              'debug': debug,
            },
            creationParamsCodec: const StandardMessageCodec(),
          )),
      child
    ]);
  }
}
