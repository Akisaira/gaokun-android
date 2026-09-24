// installer-lib.sh 的行协议。规则写在 scripts/live/installer-lib.sh 的文件头：
//
//   stdout：`TYPE k=v k=v …`，值经百分号编码（所以值里没有空格）
//   stderr：给人看的日志；`PROGRESS <百分比> <说明>` 是进度；`!! …` 是 gk3_die 的错误
//
// ⇒ 解析规则就一条：按空格切，每个值做 %-解码。不像记录的 stdout 行（命令回显之类）
//   当作日志 —— 协议要求它们走 stderr，但前端不该因为后端一处疏忽就把日志当数据。
import 'dart:convert';

sealed class Gk3Event {
  const Gk3Event();
}

/// stdout 上的一条记录，例如 `PART path=/dev/nvme0n1p1 name=EFI%20system%20partition …`
final class Gk3Record extends Gk3Event {
  const Gk3Record(this.type, this.fields);
  final String type;
  final Map<String, String> fields;

  String operator [](String key) => fields[key] ?? '';
  int intOf(String key, [int fallback = 0]) => int.tryParse(fields[key] ?? '') ?? fallback;
  bool yes(String key) => fields[key] == 'yes';

  @override
  String toString() => '$type $fields';
}

final class Gk3Progress extends Gk3Event {
  const Gk3Progress(this.percent, this.text);
  final int percent;
  final String text;
}

final class Gk3Log extends Gk3Event {
  const Gk3Log(this.line, {this.stderr = true});
  final String line;
  final bool stderr;

  /// gk3_die 的格式：`!! <说明>`
  bool get isError => line.startsWith('!! ');
  String get message => isError ? line.substring(3) : line;
}

final class Gk3Exit extends Gk3Event {
  const Gk3Exit(this.code);
  final int code;
}

final _recordType = RegExp(r'^[A-Z][A-Z0-9_]*$');

Gk3Event parseStdoutLine(String line) {
  final parts = line.split(' ');
  if (!_recordType.hasMatch(parts.first)) return Gk3Log(line, stderr: false);
  final fields = <String, String>{};
  for (final tok in parts.skip(1)) {
    if (tok.isEmpty) continue;
    final eq = tok.indexOf('=');
    // 不是 k=v 的 token ⇒ 这一行不是记录（例如某条说明恰好以大写单词开头）
    if (eq <= 0) return Gk3Log(line, stderr: false);
    fields[tok.substring(0, eq)] = pctDecode(tok.substring(eq + 1));
  }
  return Gk3Record(parts.first, fields);
}

final _progress = RegExp(r'^PROGRESS (\d+)(?: (.*))?$');

Gk3Event parseStderrLine(String line) {
  final m = _progress.firstMatch(line);
  if (m != null) return Gk3Progress(int.parse(m.group(1)!), m.group(2) ?? '');
  return Gk3Log(line);
}

/// 百分号解码：%XX 还原成字节，再整体按 UTF-8 解码（中文本身没有编码，原样透过）。
String pctDecode(String s) {
  if (!s.contains('%')) return s;
  final src = utf8.encode(s);
  final out = <int>[];
  for (var i = 0; i < src.length; i++) {
    if (src[i] == 0x25 && i + 2 < src.length) {
      final h = _hex(src[i + 1]), l = _hex(src[i + 2]);
      if (h >= 0 && l >= 0) {
        out.add(h * 16 + l);
        i += 2;
        continue;
      }
    }
    out.add(src[i]);
  }
  return utf8.decode(out, allowMalformed: true);
}

int _hex(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}
