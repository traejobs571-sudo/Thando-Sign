import 'package:flutter/material.dart';

/// Shared route observer — lets screens pause the camera while they are
/// covered by a pushed page (e.g. settings, admin console, sample capture)
/// and resume when the user returns.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
