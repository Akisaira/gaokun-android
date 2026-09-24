import 'dart:io';

import 'backend.dart';
import 'shell_backend.dart';

Gk3Backend? locateShellBackend() => ShellBackend.locate();

/// GK3_FIXTURE=factory 之类：在 Linux 开发机上也用演示数据
String? requestedScenario() => Platform.environment['GK3_FIXTURE'];

/// GK3_SOAK=1：直接进浸泡页（M0 量帧率与 RSS 用，见 ui/soak.dart）
bool soakRequested() => Platform.environment['GK3_SOAK'] == '1';
