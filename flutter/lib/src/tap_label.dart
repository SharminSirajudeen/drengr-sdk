import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'redact.dart';

/// What a tap landed on: a semantic label and whether anything on the
/// hit-path handles taps (no handler → dead_tap candidate).
class TapTarget {
  const TapTarget(this.label, this.interactive);
  final String label;
  final bool interactive;
}

const int _maxLabelChars = 64;
const int _maxAncestorHops = 60;
const int _maxDescendantVisits = 256;

/// Hit-test [position] (logical coords) and derive the tap target.
/// Label priority: Semantics label > widget key > button/text content >
/// widget runtimeType. Fail-open: returns an empty non-interactive target.
TapTarget describeTap(Offset position, int viewId) {
  try {
    final binding = WidgetsBinding.instance;
    final result = HitTestResult();
    binding.hitTestInView(result, position, viewId);
    final path = <RenderObject>[
      for (final e in result.path)
        if (e.target is RenderObject) e.target as RenderObject,
    ];
    final deepest = _deepestElement(binding.rootElement, path);
    if (deepest == null) return const TapTarget('', false);
    return _describe(deepest);
  } catch (_) {
    return const TapTarget('', false);
  }
}

/// Element of the deepest hit render object (single element-tree DFS).
Element? _deepestElement(Element? root, List<RenderObject> path) {
  if (root == null || path.isEmpty) return null;
  final wanted = Set<RenderObject>.identity()..addAll(path);
  final found = Map<RenderObject, Element>.identity();
  void visit(Element e) {
    if (found.length == wanted.length) return;
    if (e is RenderObjectElement && wanted.contains(e.renderObject)) {
      found[e.renderObject] = e;
    }
    e.visitChildElements(visit);
  }

  visit(root);
  for (final ro in path) {
    final el = found[ro];
    if (el != null) return el;
  }
  return null;
}

TapTarget _describe(Element deepest) {
  var semantics = '';
  var keyLabel = '';
  var text = '';
  var typeName = '';
  var interactive = false;
  Element? interactiveEl;

  void inspect(Element el) {
    final w = el.widget;
    if (w is Semantics) {
      final p = w.properties;
      if (semantics.isEmpty && (p.label?.isNotEmpty ?? false)) {
        semantics = p.label!;
      }
      if (p.button == true || p.onTap != null) {
        interactive = true;
        interactiveEl ??= el;
      }
    }
    if (text.isEmpty && w is Text && (w.data?.isNotEmpty ?? false)) {
      text = w.data!;
    }
    if (text.isEmpty && w is RichText) {
      final t = w.text.toPlainText();
      if (t.isNotEmpty) text = t;
    }
    if (keyLabel.isEmpty) {
      final k = w.key;
      if (k is ValueKey<String> && k.value.isNotEmpty) keyLabel = k.value;
    }
    if (w is GestureDetector && _hasTapHandler(w)) {
      interactive = true;
      interactiveEl ??= el;
    }
    final t = w.runtimeType.toString().split('<').first;
    if (_interactiveType(t)) {
      interactive = true;
      interactiveEl ??= el;
    }
    if (typeName.isEmpty && !t.startsWith('_')) typeName = t;
  }

  inspect(deepest);
  var hops = 0;
  deepest.visitAncestorElements((el) {
    inspect(el);
    return el.widget is! Navigator && ++hops < _maxAncestorHops;
  });

  // Tap on a button's padding: pull the content text from its descendants.
  final ie = interactiveEl;
  if (text.isEmpty && semantics.isEmpty && keyLabel.isEmpty && ie != null) {
    text = _descendantText(ie);
  }
  if (interactiveEl != null) {
    final t = interactiveEl!.widget.runtimeType.toString().split('<').first;
    if (!t.startsWith('_')) typeName = t;
  }

  final raw = semantics.isNotEmpty
      ? semantics
      : keyLabel.isNotEmpty
          ? keyLabel
          : text.isNotEmpty
              ? text
              : typeName;
  return TapTarget(_clean(raw), interactive);
}

bool _hasTapHandler(GestureDetector g) =>
    g.onTap != null ||
    g.onTapDown != null ||
    g.onTapUp != null ||
    g.onDoubleTap != null ||
    g.onLongPress != null;

const Set<String> _interactiveTypes = {
  'InkWell', 'InkResponse', 'ListTile', 'CheckboxListTile', 'SwitchListTile',
  'RadioListTile', 'ExpansionTile', 'Switch', 'Checkbox', 'Radio', 'Slider',
  'TextField', 'TextFormField', 'CupertinoTextField', 'EditableText',
  'Dismissible', 'Tab', 'Chip', 'ActionChip', 'ChoiceChip', 'FilterChip',
  'InputChip',
};

bool _interactiveType(String t) =>
    t.contains('Button') || _interactiveTypes.contains(t);

/// First Text under an interactive widget (bounded DFS).
String _descendantText(Element root) {
  var out = '';
  var visited = 0;
  void visit(Element e) {
    if (out.isNotEmpty || ++visited > _maxDescendantVisits) return;
    final w = e.widget;
    if (w is Text && (w.data?.isNotEmpty ?? false)) {
      out = w.data!;
      return;
    }
    if (w is RichText) {
      final t = w.text.toPlainText();
      if (t.isNotEmpty) {
        out = t;
        return;
      }
    }
    e.visitChildElements(visit);
  }

  try {
    visit(root);
  } catch (_) {}
  return out;
}

/// Collapse whitespace, redact secrets/PII patterns, cap length.
String _clean(String raw) {
  try {
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = redactBody(s);
    if (s.length > _maxLabelChars) s = s.substring(0, _maxLabelChars);
    return s;
  } catch (_) {
    return '';
  }
}
