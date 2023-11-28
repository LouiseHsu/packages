// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_print

import 'package:flutter/widgets.dart';

import 'pointer_interceptor_platform.dart';

/// A default implementation of [PointerInterceptorPlatform].
class DefaultPointerInterceptor extends PointerInterceptorPlatform {
  @override
  Widget buildWidget({
    required Widget child,
    bool debug = false,
    Key? key,
  }) {
    return child;
  }
}