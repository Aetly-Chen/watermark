// 去水印结果的数值与目视验收。
//
// 跑法（在 app/ 目录下）：
//   dart run tool/quality_compare.dart <result.png>
//        [--original ../assets/cafe.jpg]
//        [--reference ../assets/cafe-clean.png | none]
//        [--box l,t,r,b] [--out crop.png]
//
// 两套口径，取决于有没有可信的「无水印基准图」：
//
//   有基准图（--reference 指向真·干净图）：
//     区域内 MAE / PSNR —— 修复前 vs 修复后，越小/越高越好；
//     区域外 MAE —— 必须≈0，否则说明 inpaint 动到了不该动的地方。
//
//   没有基准图（--reference none）：
//     改动覆盖率 —— Mask 区域里有多少像素真的被改写（证明「框了就有用」）；
//     粗糙度对比 —— 区域内的水平梯度 vs 框上方同尺寸对照带。
//                   涂抹（smear）的特征就是梯度显著低于四周，人眼看是「一片糊」。
//
// ⚠ assets/cafe-clean.png 不能当真基准用：它自己就带着同一行水印，
//   而且与 cafe.jpg 的差异区在 y832~878 的暗区，根本不在文字上。
//   所以本项目的示例图默认走 --reference none。
//
// 用 Dart 写而不是 Python：本机 Python 装 numpy/PIL 会写爆 C 盘，而 image 是纯 Dart 包。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

void main(List<String> argv) {
  final args = _parse(argv);
  final resultPath = args.option('result');
  if (resultPath.isEmpty) {
    stderr.writeln('用法: dart run tool/quality_compare.dart <result.png> [--original ..] [--reference ..|none] [--box l,t,r,b] [--out crop.png]');
    exit(64);
  }

  final original = img.decodeImage(File(args.option('original', '../assets/cafe.jpg')).readAsBytesSync());
  var result = img.decodeImage(File(resultPath).readAsBytesSync());
  if (original == null || result == null) {
    stderr.writeln('图片解码失败');
    exit(65);
  }

  final refPath = args.option('reference', 'none');
  final useRef = refPath != 'none' && File(refPath).existsSync();
  final reference = useRef ? img.decodeImage(File(refPath).readAsBytesSync()) : null;

  final w = original.width;
  final h = original.height;
  if (result.width != w || result.height != h) {
    stdout.writeln('⚠ 结果尺寸 ${result.width}x${result.height} 与原图 ${w}x$h 不同，已缩放对齐');
    result = img.copyResize(result, width: w, height: h, interpolation: img.Interpolation.cubic);
  }

  final box = args.option('box', '0.865,0.982,0.995,0.996').split(',').map((e) => double.parse(e.trim())).toList();
  final x0 = (box[0] * w).floor().clamp(0, w - 1);
  final y0 = (box[1] * h).floor().clamp(0, h - 1);
  final x1 = (box[2] * w).ceil().clamp(0, w);
  final y1 = (box[3] * h).ceil().clamp(0, h);

  String f(double v, [int d = 2]) => v.toStringAsFixed(d);
  String db(double v) => v.isInfinite ? '   ∞  ' : f(v).padLeft(6);

  stdout
    ..writeln('图像尺寸      : ${w}x$h')
    ..writeln('水印区域(px)  : x[$x0,$x1) y[$y0,$y1)  共 ${(x1 - x0) * (y1 - y0)} px');

  if (reference != null) {
    if (reference.width != w || reference.height != h) {
      stderr.writeln('参考图尺寸不一致: ${reference.width}x${reference.height}');
      exit(66);
    }
    var oIn = 0.0, rIn = 0.0, oInSq = 0.0, rInSq = 0.0, outAbs = 0.0;
    var inCount = 0, outCount = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = original.getPixel(x, y);
        final ref = reference.getPixel(x, y);
        final res = result.getPixel(x, y);
        final dr0 = o.r - ref.r, dg0 = o.g - ref.g, db0 = o.b - ref.b;
        final dr1 = res.r - ref.r, dg1 = res.g - ref.g, db1 = res.b - ref.b;
        final inside = x >= x0 && x < x1 && y >= y0 && y < y1;
        if (inside) {
          inCount++;
          oIn += (dr0.abs() + dg0.abs() + db0.abs()) / 3;
          rIn += (dr1.abs() + dg1.abs() + db1.abs()) / 3;
          oInSq += (dr0 * dr0 + dg0 * dg0 + db0 * db0) / 3;
          rInSq += (dr1 * dr1 + dg1 * dg1 + db1 * db1) / 3;
        } else {
          outCount++;
          outAbs += (dr1.abs() + dg1.abs() + db1.abs()) / 3;
        }
      }
    }
    stdout
      ..writeln('-' * 62)
      ..writeln('区域内 MAE    : 修复前 ${f(oIn / inCount).padLeft(7)}  →  修复后 ${f(rIn / inCount).padLeft(7)}')
      ..writeln('区域内 PSNR   : 修复前 ${db(_psnr(oInSq / inCount))} dB →  修复后 ${db(_psnr(rInSq / inCount))} dB')
      ..writeln('区域外 MAE    : 修复后 ${f(outAbs / outCount, 4).padLeft(7)}（应≈0，否则说明动到了不该动的地方）');
  } else {
    // 无基准图：看「改了多少」和「改得平不平」
    var changed = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final o = original.getPixel(x, y);
        final res = result.getPixel(x, y);
        final d = ((o.r - res.r).abs() + (o.g - res.g).abs() + (o.b - res.b).abs()) / 3;
        if (d > 8) changed++;
      }
    }
    final total = (x1 - x0) * (y1 - y0);
    final roughIn = _roughness(result, x0, y0, x1, y1);
    final control = _roughness(original, x0, math.max(y0 - (y1 - y0) - 4, 0), x1, math.max(y0 - 4, 1));
    stdout
      ..writeln('-' * 62)
      ..writeln('改动覆盖率    : ${(changed / total * 100).toStringAsFixed(1)}%  ($changed / $total px)')
      ..writeln('区域内粗糙度  : ${f(roughIn)}（水平梯度均值，越低越「糊」）')
      ..writeln('对照带粗糙度  : ${f(control)}（框上方同高条带，未修复的原图）')
      ..writeln('比值          : ${(roughIn / control).toStringAsFixed(2)}× —— 明显低于 1 说明涂抹过头')
      ..writeln('（没有可信基准图，只能看改动与平滑度；没有 --reference 就是这套口径）');
  }

  final outPath = args.option('out', '');
  if (outPath.isNotEmpty) {
    final panels = <String, img.Image>{'ORIGINAL (watermarked)': original, 'RESULT (inpainted)': result};
    if (reference != null) panels['REFERENCE (clean)'] = reference;
    _writeSheet(panels, x0, y0, x1, y1, w, h, outPath);
    stdout.writeln('裁剪对照已存  : $outPath（${panels.keys.join(' / ')}）');
  }
}

double _psnr(double mse) {
  if (mse <= 0.0000001) return double.infinity;
  return 10 * math.log(255 * 255 / mse) / math.ln10;
}

/// 水平梯度均值：涂抹后画面变平，这个值会掉下来。
double _roughness(img.Image im, int x0, int y0, int x1, int y1) {
  var s = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1 - 1; x++) {
      final a = im.getPixel(x, y);
      final b = im.getPixel(x + 1, y);
      s += ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) / 3;
      n++;
    }
  }
  return n == 0 ? 0 : s / n;
}

void _writeSheet(Map<String, img.Image> panels, int x0, int y0, int x1, int y1, int w, int h, String outPath) {
  const pad = 10;
  final cx0 = math.max(x0 - pad, 0);
  final cy0 = math.max(y0 - pad, 0);
  final cx1 = math.min(x1 + pad, w);
  final cy1 = math.min(y1 + pad, h);
  final cw = cx1 - cx0;
  final ch = cy1 - cy0;
  const gap = 8;
  const labelH = 18;
  final rows = panels.length;
  final sheet = img.Image(width: cw, height: (ch + gap + labelH) * rows);
  img.fill(sheet, color: img.ColorRgb8(20, 18, 14));
  var i = 0;
  for (final e in panels.entries) {
    final top = i * (ch + gap + labelH);
    // 标签不能省：三块长得很像，没标注的对照图会被看反（我犯过）
    img.drawString(sheet, e.key, font: img.arial14, x: 4, y: top + 2, color: img.ColorRgb8(235, 230, 220));
    img.compositeImage(sheet, img.copyCrop(e.value, x: cx0, y: cy0, width: cw, height: ch), dstX: 0, dstY: top + labelH);
    i++;
  }
  // 6px 高的水印要放大 3 倍才看得清
  final big = img.copyResize(sheet, width: cw * 3, interpolation: img.Interpolation.nearest);
  File(outPath).writeAsBytesSync(img.encodePng(big));
}

class _Args {
  _Args(this._values);
  final Map<String, String> _values;
  String option(String key, [String fallback = '']) => _values[key] ?? fallback;
}

_Args _parse(List<String> argv) {
  final map = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a.startsWith('--')) {
      final key = a.substring(2);
      if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        map[key] = argv[i + 1];
        i++;
      } else {
        map[key] = 'true';
      }
    } else if (!map.containsKey('result')) {
      map['result'] = a;
    }
  }
  return _Args(map);
}
