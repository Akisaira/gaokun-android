import 'backend.dart';

Gk3Backend? locateShellBackend() => null;

/// http://localhost:xxxx/?scenario=factory
String? requestedScenario() => Uri.base.queryParameters['scenario'];
