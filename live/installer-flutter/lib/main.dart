import 'package:flutter/material.dart';

import 'app.dart';
import 'backend/backend.dart';
import 'backend/fixture_backend.dart';
import 'backend/platform.dart';
import 'session.dart';
import 'ui/soak.dart';

/// 真机：找 installer-lib.sh，走真后端。
/// 开发：GK3_FIXTURE=<场景>（Linux）或 ?scenario=<场景>（Chrome）回放录好的输出；
///       Web 上没有真后端，默认用 windows-free。
void main() {
  final scenario = requestedScenario();
  Gk3Backend? backend = scenario == null ? locateShellBackend() : null;
  backend ??= FixtureBackend(FixtureBackend.scenarios.contains(scenario) ? scenario! : 'windows-free');
  runApp(InstallerApp(session: Session(backend), home: soakRequested() ? const SoakPage() : null));
}
