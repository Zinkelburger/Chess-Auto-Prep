// Debug-only service extensions that let an external process drive the
// running app: list what is on screen, tap it, type into it, scroll it, and
// save a screenshot. This is how agents (and headless scripts) exercise the
// real app instead of guessing from source.
//
// Compiled in only for debug builds started with
//   --dart-define=AGENT_DRIVER=true
// and reached over the VM service — see
// .claude/skills/run-chess-auto-prep/driver.py, which wraps
// `flutter run --machine` and turns `driver.py tap text=Play` into an
// `ext.chessprep.tap` call. Release builds tree-shake the whole file.
//
// Everything here lives in lib/debug/ and imports only Flutter: no app
// widgets, no services, so the layering rules stay intact.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// True when the app was launched with `--dart-define=AGENT_DRIVER=true`.
const bool agentDriverEnabled = bool.fromEnvironment('AGENT_DRIVER');

/// Registers the `ext.chessprep.*` extensions. Safe to call unconditionally;
/// it is a no-op outside debug builds or without the dart-define.
void installAgentDriver() {
  if (!kDebugMode || !agentDriverEnabled) return;
  _register('dump', _dump);
  _register('tap', _tap);
  _register('type', _type);
  _register('scroll', _scroll);
  _register('screenshot', _screenshot);
  _register('settle', _settleExt);
  _register('ping', (method, params) async => _ok({'ok': true}));
  debugPrint('agent driver: ext.chessprep.* registered');
}

/// Registers [handler] so that anything it throws — including a framework
/// assertion — comes back to the caller as an error instead of a hung call.
void _register(String name, developer.ServiceExtensionHandler handler) {
  developer.registerExtension('ext.chessprep.$name', (method, params) async {
    try {
      return await handler(method, params);
    } catch (e, st) {
      debugPrint('agent driver: $name failed: $e\n$st');
      return _err('$e');
    }
  });
}

// ---------------------------------------------------------------------------
// Element inventory
// ---------------------------------------------------------------------------

class _Item {
  _Item(this.kind, this.value, this.rect, this.element);
  final String kind;
  final String value;
  final Rect rect;
  final Element element;

  Map<String, Object> toJson() => {
    'kind': kind,
    'value': value,
    'rect': [
      rect.left.round(),
      rect.top.round(),
      rect.width.round(),
      rect.height.round(),
    ],
  };
}

Size _viewSize() {
  final view = RendererBinding.instance.renderViews.first;
  return view.size;
}

/// Global rect of the nearest render box under [element], or null if it is
/// not laid out, offstage, or entirely outside the window.
Rect? _visibleRect(Element element) {
  final ro = element.renderObject;
  if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
  // Anything under an Offstage (Navigator keeps hidden routes this way) is
  // laid out but never painted — leave it out of the inventory.
  for (RenderObject? p = ro; p != null; p = p.parent) {
    if (p is RenderOffstage && p.offstage) return null;
    if (p is RenderOpacity && p.opacity == 0) return null;
  }
  final topLeft = ro.localToGlobal(Offset.zero);
  final rect = topLeft & ro.size;
  // A sliver child that is laid out but parked off the viewport can report a
  // non-finite origin. `round()` on that throws and takes the whole dump down,
  // so drop the item instead — it is not on screen anyway.
  if (!rect.isFinite) return null;
  final bounds = Offset.zero & _viewSize();
  if (rect.isEmpty || !rect.overlaps(bounds)) return null;
  return rect;
}

List<_Item> _inventory() {
  final items = <_Item>[];
  final seen = <String>{};
  void add(String kind, String value, Element el) {
    final rect = _visibleRect(el);
    if (rect == null) return;
    final key = '$kind|$value|${rect.left.round()},${rect.top.round()}';
    if (!seen.add(key)) return;
    items.add(_Item(kind, value, rect, el));
  }

  void visit(Element el) {
    final w = el.widget;
    final k = w.key;
    if (k is ValueKey) add('key', '${k.value}', el);
    if (w is RichText) {
      final t = w.text.toPlainText().trim();
      if (t.isNotEmpty) add('text', t, el);
    } else if (w is Tooltip) {
      final m = w.message ?? w.richMessage?.toPlainText();
      if (m != null && m.isNotEmpty) add('tooltip', m, el);
    } else if (w is EditableText) {
      add('field', w.controller.text, el);
    } else if (w is Checkbox) {
      add('checkbox', '${w.value}', el);
    } else if (w is Switch) {
      add('switch', '${w.value}', el);
    }
    el.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  items.sort((a, b) {
    final dy = a.rect.top.compareTo(b.rect.top);
    return dy != 0 ? dy : a.rect.left.compareTo(b.rect.left);
  });
  return items;
}

/// Resolves a target from params: `text=`, `tooltip=`, `key=`, `field=`,
/// each matched exactly first and then as a substring, with optional
/// `index=` to pick the nth match; or `x=`/`y=` for a raw point.
({Offset? point, _Item? item, String? error}) _resolve(
  Map<String, String> params,
) {
  final x = params['x'];
  final y = params['y'];
  if (x != null && y != null) {
    return (
      point: Offset(double.parse(x), double.parse(y)),
      item: null,
      error: null,
    );
  }
  String? kind;
  String? needle;
  for (final k in const ['text', 'tooltip', 'key', 'field']) {
    if (params.containsKey(k)) {
      kind = k;
      needle = params[k];
      break;
    }
  }
  if (kind == null || needle == null) {
    return (
      point: null,
      item: null,
      error: 'no target (text=/tooltip=/key=/field= or x=,y=)',
    );
  }
  final all = _inventory().where((i) => i.kind == kind).toList();
  var matches = all.where((i) => i.value == needle).toList();
  if (matches.isEmpty) {
    matches = all
        .where((i) => i.value.toLowerCase().contains(needle!.toLowerCase()))
        .toList();
  }
  if (matches.isEmpty) {
    return (
      point: null,
      item: null,
      error: 'no visible $kind matching "$needle"',
    );
  }
  final index = int.tryParse(params['index'] ?? '0') ?? 0;
  if (index >= matches.length) {
    return (
      point: null,
      item: null,
      error: 'only ${matches.length} match(es) for $kind "$needle"',
    );
  }
  final item = matches[index];
  return (point: item.rect.center, item: item, error: null);
}

// ---------------------------------------------------------------------------
// Waiting for the UI to settle
// ---------------------------------------------------------------------------

/// Waits until no frame has been scheduled for [quiet] ms, or [timeout].
Future<int> _settle({int quiet = 120, int timeout = 5000}) async {
  final sw = Stopwatch()..start();
  var frames = 0;
  while (sw.elapsedMilliseconds < timeout) {
    if (SchedulerBinding.instance.hasScheduledFrame) {
      // Bounded: if the embedder stops delivering frames (window hidden or
      // minimised) this must not hang the whole extension call.
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 750),
        onTimeout: () {},
      );
      frames++;
      continue;
    }
    await Future<void>.delayed(Duration(milliseconds: quiet));
    if (!SchedulerBinding.instance.hasScheduledFrame) return frames;
  }
  return frames;
}

// ---------------------------------------------------------------------------
// Extensions
// ---------------------------------------------------------------------------

developer.ServiceExtensionResponse _ok(Map<String, Object?> body) =>
    developer.ServiceExtensionResponse.result(jsonEncode(body));

developer.ServiceExtensionResponse _err(String message) =>
    developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      message,
    );

Future<developer.ServiceExtensionResponse> _dump(
  String method,
  Map<String, String> params,
) async {
  await _settle(timeout: 1000);
  final size = _viewSize();
  final items = _inventory();
  final kinds = params['kinds']?.split(',');
  return _ok({
    'size': [size.width.round(), size.height.round()],
    'items': [
      for (final i in items)
        if (kinds == null || kinds.contains(i.kind)) i.toJson(),
    ],
  });
}

Future<developer.ServiceExtensionResponse> _settleExt(
  String method,
  Map<String, String> params,
) async {
  final frames = await _settle(
    timeout: int.tryParse(params['timeout'] ?? '') ?? 5000,
  );
  return _ok({'frames': frames});
}

int _pointerId = 100;

/// A device id the embedder never uses, so the synthetic mouse never shares
/// MouseTracker state with the real one. Never send a PointerAddedEvent for
/// it: MouseTracker asserts if a device is "added" twice, and a hover event
/// on an unknown device creates its state anyway.
const int _syntheticMouse = 4242;

Future<void> _pointerTap(Offset at, {bool secondary = false}) async {
  final binding = GestureBinding.instance;
  final pointer = _pointerId++;
  final buttons = secondary ? kSecondaryMouseButton : kPrimaryMouseButton;
  binding.handlePointerEvent(
    PointerHoverEvent(
      position: at,
      kind: PointerDeviceKind.mouse,
      device: _syntheticMouse,
    ),
  );
  await _settle(quiet: 30, timeout: 500);
  binding.handlePointerEvent(
    PointerDownEvent(
      position: at,
      kind: PointerDeviceKind.mouse,
      device: _syntheticMouse,
      pointer: pointer,
      buttons: buttons,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  binding.handlePointerEvent(
    PointerUpEvent(
      position: at,
      kind: PointerDeviceKind.mouse,
      device: _syntheticMouse,
      pointer: pointer,
    ),
  );
}

Future<developer.ServiceExtensionResponse> _tap(
  String method,
  Map<String, String> params,
) async {
  final r = _resolve(params);
  if (r.error != null) return _err(r.error!);
  final at = r.point!;
  final taps = int.tryParse(params['count'] ?? '1') ?? 1;
  for (var i = 0; i < taps; i++) {
    await _pointerTap(at, secondary: params['button'] == 'secondary');
    if (taps > 1) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }
  final frames = await _settle();
  return _ok({
    'tapped': r.item?.toJson() ?? {'x': at.dx, 'y': at.dy},
    'frames': frames,
  });
}

Future<developer.ServiceExtensionResponse> _scroll(
  String method,
  Map<String, String> params,
) async {
  final r = _resolve(params);
  if (r.error != null) return _err(r.error!);
  final at = r.point!;
  final dx = double.tryParse(params['dx'] ?? '0') ?? 0;
  final dy = double.tryParse(params['dy'] ?? '300') ?? 300;
  // Mouse-wheel semantics: desktop ScrollBehavior ignores mouse drags, so a
  // PointerScrollEvent is the input a scrollable will actually honour.
  GestureBinding.instance.handlePointerEvent(
    PointerHoverEvent(
      position: at,
      kind: PointerDeviceKind.mouse,
      device: _syntheticMouse,
    ),
  );
  GestureBinding.instance.handlePointerEvent(
    PointerScrollEvent(
      position: at,
      scrollDelta: Offset(dx, dy),
      kind: PointerDeviceKind.mouse,
      device: _syntheticMouse,
    ),
  );
  final frames = await _settle();
  return _ok({
    'scrolled': [dx, dy],
    'frames': frames,
  });
}

EditableTextState? _editableUnder(Element el) {
  EditableTextState? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is EditableTextState) {
      found = e.state as EditableTextState;
      return;
    }
    e.visitChildren(visit);
  }

  visit(el);
  return found;
}

Future<developer.ServiceExtensionResponse> _type(
  String method,
  Map<String, String> params,
) async {
  final text = params['text'];
  if (text == null) return _err('text= is required');
  EditableTextState? state;
  if (params.keys.any(
    (k) => const ['text_target', 'key', 'field', 'tooltip'].contains(k),
  )) {
    // `text=` is the payload, so the target text (if any) comes as
    // text_target= to avoid the clash.
    final targetParams = Map<String, String>.from(params)..remove('text');
    if (targetParams.containsKey('text_target')) {
      targetParams['text'] = targetParams.remove('text_target')!;
    }
    final r = _resolve(targetParams);
    if (r.error != null) return _err(r.error!);
    state = _editableUnder(r.item!.element);
    if (state == null) return _err('target has no text field under it');
  } else {
    // Focused field, else the first visible one.
    final fields = _inventory().where((i) => i.kind == 'field').toList();
    for (final f in fields) {
      final s = _editableUnder(f.element);
      if (s != null && s.widget.focusNode.hasFocus) {
        state = s;
        break;
      }
    }
    state ??= fields.isEmpty ? null : _editableUnder(fields.first.element);
    if (state == null) return _err('no text field on screen');
  }
  if (!state.widget.focusNode.hasFocus) {
    state.widget.focusNode.requestFocus();
    await _settle(timeout: 1000);
  }
  final value = params['append'] == 'true'
      ? '${state.textEditingValue.text}$text'
      : text;
  state.updateEditingValue(
    TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ),
  );
  if (params['submit'] == 'true') {
    await _settle(timeout: 500);
    state.performAction(TextInputAction.done);
  }
  final frames = await _settle();
  return _ok({'text': value, 'frames': frames});
}

Future<developer.ServiceExtensionResponse> _screenshot(
  String method,
  Map<String, String> params,
) async {
  final path = params['path'];
  if (path == null) return _err('path= is required');
  await _settle(timeout: 2000);
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer;
  if (layer is! OffsetLayer)
    return _err('no root layer yet (nothing painted?)');
  final dpr = view.flutterView.devicePixelRatio;
  // The root TransformLayer already scales by the device pixel ratio, so
  // ask for bounds in physical pixels at pixelRatio 1.
  final bounds =
      Offset.zero & Size(view.size.width * dpr, view.size.height * dpr);
  final image = await layer.toImage(bounds);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final width = image.width;
  final height = image.height;
  image.dispose();
  if (bytes == null) return _err('PNG encode failed');
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes.buffer.asUint8List());
  return _ok({'path': path, 'width': width, 'height': height});
}
