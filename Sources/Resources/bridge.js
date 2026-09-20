// Injected into every frame at document start, in its own content world (pages cannot
// see window.__db). Provides pointer/mouse event synthesis, text selection, focus
// tracking, text insertion, caret movement, focus cycling and link hints.
// Native side: Bridge.swift. Keep the window.__db API in sync with it.
//
// Frames: the display's pointer only ever talks to the top frame. When the point lands
// on an <iframe>, the top frame translates the coordinates and forwards the call to the
// frame's own copy of this script, directly when same-origin and by postMessage when
// not. Nested frames repeat the trick. Without this nothing inside a cross-origin frame
// (Google's sign-in button and One Tap prompt, embedded players, captchas) is clickable.
(function () {
  if (window.__db) { return; }

  // Replaced by Bridge.swift with a per-launch random string. Only frames running this
  // script know it, so page scripts in a parent cannot forge pointer input into a
  // cross-origin child (that would defeat click-jacking protection).
  var TOKEN = '__DB_TOKEN__';
  var isTop = (function () { try { return window === window.top; } catch (e) { return false; } })();

  function post(message) {
    try { window.webkit.messageHandlers.db.postMessage(message); } catch (e) {}
  }

  // ---------------------------------------------------------------- DOM helpers

  var NON_TEXT_INPUTS = ['button', 'submit', 'checkbox', 'radio', 'file', 'image', 'reset', 'range', 'color', 'hidden'];

  function isEditable(el) {
    if (!el || el === document.body || el.nodeType !== 1) { return false; }
    var tag = el.tagName;
    if (tag === 'TEXTAREA' || tag === 'SELECT') { return true; }
    if (tag === 'INPUT') { return NON_TEXT_INPUTS.indexOf((el.type || 'text').toLowerCase()) === -1; }
    return el.isContentEditable === true;
  }

  function isFrameElement(el) {
    return !!el && el.nodeType === 1 && (el.tagName === 'IFRAME' || el.tagName === 'FRAME');
  }

  // Parent that also steps out of shadow trees, so ancestry checks work on web components.
  function parentOf(el) {
    if (!el) { return null; }
    if (el.parentElement) { return el.parentElement; }
    var root = el.getRootNode ? el.getRootNode() : null;
    return (root && root.host) ? root.host : null;
  }

  function closest(el, pred) {
    var guard = 0;
    while (el && el.nodeType === 1 && guard++ < 500) {
      if (pred(el)) { return el; }
      el = parentOf(el);
    }
    return null;
  }

  function containsAcrossShadow(ancestor, el) {
    return !!closest(el, function (n) { return n === ancestor; });
  }

  function isLink(n) { return n.tagName === 'A' && n.hasAttribute('href'); }
  function closestLink(el) { return closest(el, isLink); }
  function closestEditable(el) { return closest(el, isEditable); }

  var INTERACTIVE_ROLES = ['button', 'link', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
    'checkbox', 'radio', 'switch', 'slider', 'spinbutton', 'combobox', 'listbox', 'scrollbar'];

  // Things a mouse press acts on rather than starting a text selection in.
  function isInteractive(n) {
    var tag = n.tagName;
    if (tag === 'BUTTON' || tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'SUMMARY' ||
        tag === 'LABEL' || tag === 'VIDEO' || tag === 'AUDIO' || tag === 'IMG') { return true; }
    if (isLink(n)) { return true; }
    if (n.draggable === true) { return true; }
    var role = n.getAttribute && n.getAttribute('role');
    return !!role && INTERACTIVE_ROLES.indexOf(role) !== -1;
  }

  // WebKit inherits -webkit-user-select, so the target's computed value is enough.
  function isSelectable(el) {
    if (closest(el, isInteractive)) { return false; }
    try {
      var cs = getComputedStyle(el);
      var us = cs.webkitUserSelect || cs.userSelect;
      if (us === 'none') { return false; }
    } catch (e) {}
    return true;
  }

  // Topmost element at a viewport point, descending into shadow roots so events reach
  // the element that actually has the listeners (elementFromPoint stops at the host).
  function targetAt(x, y) {
    var el = document.elementFromPoint(x, y);
    if (!el) { return document.documentElement; }
    var guard = 0;
    while (el.shadowRoot && guard++ < 20) {
      var inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) { break; }
      el = inner;
    }
    return el;
  }

  function caretAt(x, y) {
    if (document.caretRangeFromPoint) { return document.caretRangeFromPoint(x, y); }
    if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (!p) { return null; }
      var r = document.createRange(); r.setStart(p.offsetNode, p.offset); r.collapse(true); return r;
    }
    return null;
  }

  // ---------------------------------------------------------------- frames

  // Viewport point inside a frame's content box, in the child's coordinates.
  function frameLocalPoint(frame, x, y) {
    var r = frame.getBoundingClientRect();
    var bl = 0, bt = 0, pl = 0, pt = 0;
    try {
      var cs = getComputedStyle(frame);
      bl = parseFloat(cs.borderLeftWidth) || 0; bt = parseFloat(cs.borderTopWidth) || 0;
      pl = parseFloat(cs.paddingLeft) || 0; pt = parseFloat(cs.paddingTop) || 0;
    } catch (e) {}
    return { x: x - r.left - bl - pl, y: y - r.top - bt - pt };
  }

  function sameOriginAPI(frame) {
    try {
      var w = frame.contentWindow;
      if (w && w.__db && typeof w.__db.pointerMove === 'function') { return w.__db; }
    } catch (e) {}
    return null;
  }

  // Calls fn(args) inside a frame. Returns the result only when the frame is same-origin.
  function forward(frame, fn, args) {
    var api = sameOriginAPI(frame);
    if (api && typeof api[fn] === 'function') {
      try { return api[fn].apply(null, args); } catch (e) {}
    }
    try { frame.contentWindow.postMessage({ __db: TOKEN, fn: fn, args: args }, '*'); } catch (e) {}
    return undefined;
  }

  function frameElementFor(win) {
    var frames = document.querySelectorAll('iframe, frame');
    for (var i = 0; i < frames.length; i++) {
      try { if (frames[i].contentWindow === win) { return frames[i]; } } catch (e) {}
    }
    return null;
  }

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || typeof d !== 'object' || d.__db !== TOKEN || typeof d.fn !== 'string') { return; }
    var args = Array.isArray(d.args) ? d.args : [];
    if (d.fn === 'scrollFromChild') {
      // A child could not scroll any further; continue in this document from the frame
      // element outwards, like scroll chaining in a real browser.
      var frameEl = frameElementFor(e.source);
      if (frameEl) { chainScroll(parentOf(frameEl), args[0], args[1]); }
      return;
    }
    // Commands only flow downwards, from the frame that owns the pointer.
    if (e.source !== window.parent) { return; }
    var f = window.__db && window.__db[d.fn];
    if (typeof f === 'function') { try { f.apply(null, args); } catch (err) {} }
  });

  // Text input goes to the frame that owns the focused element.
  function routed(name, impl) {
    return function () {
      var a = document.activeElement;
      var args = Array.prototype.slice.call(arguments);
      if (isFrameElement(a)) { return forward(a, name, args); }
      return impl.apply(null, args);
    };
  }

  // ---------------------------------------------------------------- focus tracking

  function activeEditable() { return isEditable(document.activeElement); }

  function reportFocus() {
    var a = document.activeElement;
    if (isFrameElement(a)) { return; } // the frame reports for itself
    post({ type: 'focus', editable: isEditable(a), password: !!(a && a.type === 'password') });
  }

  document.addEventListener('focusin', function (e) {
    if (isFrameElement(e.target)) { return; }
    post({ type: 'focus', editable: isEditable(e.target),
           password: !!(e.target && e.target.type === 'password') });
  }, true);
  document.addEventListener('focusout', function () {
    setTimeout(function () {
      // Focus that left this document altogether is reported by whoever received it.
      if (!isTop && !document.hasFocus()) { return; }
      reportFocus();
    }, 0);
  }, true);

  // ---------------------------------------------------------------- link hints

  var HINT_CHARS = 'asdfghjkl';
  var hints = null;

  function makeLabels(n) {
    var len = 1;
    while (Math.pow(HINT_CHARS.length, len) < n) { len++; }
    var out = [];
    for (var i = 0; i < n; i++) {
      var s = '', x = i;
      for (var k = 0; k < len; k++) { s = HINT_CHARS[x % HINT_CHARS.length] + s; x = Math.floor(x / HINT_CHARS.length); }
      out.push(s);
    }
    return out;
  }

  var CLICKABLE = 'a[href], button, input, select, textarea, summary, label, [role="button"], [role="link"], ' +
    '[role="tab"], [role="menuitem"], [role="option"], [role="checkbox"], [role="switch"], [onclick], ' +
    '[tabindex]:not([tabindex="-1"]), [contenteditable="true"], [contenteditable=""]';

  function visibleClickables() {
    var vw = window.innerWidth, vh = window.innerHeight;
    var els = document.querySelectorAll(CLICKABLE);
    var result = [];
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.closest && el.closest('#__db_hints')) { continue; }
      var r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) { continue; }
      if (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) { continue; }
      var cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) === 0) { continue; }
      var cx = Math.min(vw - 1, Math.max(0, r.left + Math.min(r.width / 2, 8)));
      var cy = Math.min(vh - 1, Math.max(0, r.top + Math.min(r.height / 2, 8)));
      var top = document.elementFromPoint(cx, cy);
      if (top && top !== el && !el.contains(top) && !top.contains(el)) { continue; }
      result.push({ el: el, rect: r });
    }
    return result;
  }

  function showHints(newTab) {
    hideHints();
    var items = visibleClickables();
    if (!items.length) { post({ type: 'hints', count: 0 }); return; }
    var labels = makeLabels(items.length);
    var container = document.createElement('div');
    container.id = '__db_hints';
    container.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
    for (var i = 0; i < items.length; i++) {
      var d = document.createElement('div');
      d.textContent = labels[i].toUpperCase();
      d.style.cssText = 'position:fixed;left:' + Math.max(0, items[i].rect.left) + 'px;top:' + Math.max(0, items[i].rect.top) + 'px;' +
        'background:#ffec3d;color:#111;font:bold 13px/1 -apple-system,Helvetica,Arial,sans-serif;padding:3px 5px;' +
        'border:1px solid #b89f00;border-radius:3px;box-shadow:0 1px 3px rgba(0,0,0,.45);letter-spacing:1px;';
      container.appendChild(d);
      items[i].label = labels[i];
      items[i].node = d;
    }
    document.documentElement.appendChild(container);
    hints = { container: container, items: items, typed: '', newTab: !!newTab };
    post({ type: 'hints', count: items.length });
  }

  function hideHints() {
    if (hints) { hints.container.remove(); hints = null; }
  }

  function hintKey(key) {
    if (!hints) { return; }
    key = String(key).toLowerCase();
    if (key === 'escape') { hideHints(); post({ type: 'hints', count: 0 }); return; }
    if (key === 'backspace') { hints.typed = hints.typed.slice(0, -1); }
    else if (key.length === 1 && HINT_CHARS.indexOf(key) !== -1) { hints.typed += key; }
    else { return; }
    var typed = hints.typed, match = null, remaining = 0;
    for (var i = 0; i < hints.items.length; i++) {
      var it = hints.items[i];
      var ok = it.label.indexOf(typed) === 0;
      it.node.style.display = ok ? '' : 'none';
      if (ok) { remaining++; }
      if (it.label === typed) { match = it; }
    }
    if (match) {
      var el = match.el, newTab = hints.newTab;
      hideHints();
      activate(el, newTab);
      post({ type: 'hints', count: 0 });
    } else if (!remaining) {
      hideHints();
      post({ type: 'hints', count: 0 });
    }
  }

  function activate(el, newTab) {
    var link = closestLink(el);
    if (newTab && link && link.href && !/^javascript:/i.test(link.href)) {
      post({ type: 'openTab', url: link.href });
      return;
    }
    if (isEditable(el)) {
      el.focus();
      try { if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { var n = el.value.length; el.setSelectionRange(n, n); } } catch (e) {}
      return;
    }
    if (el.focus) { el.focus(); }
    el.click();
  }

  // ---------------------------------------------------------------- text input

  function keyEvent(type, key, code, keyCode) {
    var el = document.activeElement || document.body;
    return el.dispatchEvent(new KeyboardEvent(type, { key: key, code: code, keyCode: keyCode, which: keyCode, bubbles: true, cancelable: true }));
  }

  // React and other frameworks keep a value tracker on the node itself. Assigning
  // el.value goes through that tracker, so the framework sees no change and reverts
  // the edit on its next render - the field looks like it ignores typing. Going
  // through the prototype setter leaves the tracker stale, which is what makes the
  // framework notice. Google's sign-in fields need this.
  function nativeSetValue(el, value) {
    var proto = (typeof window.HTMLTextAreaElement !== 'undefined' && el instanceof window.HTMLTextAreaElement)
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
  }

  function insertText(text) {
    var el = document.activeElement;
    if (!el) { return; }
    if (text.length === 1) {
      keyEvent('keydown', text, '', text.toUpperCase().charCodeAt(0));
      keyEvent('keypress', text, '', text.charCodeAt(0));
    }
    var hasValue = ('value' in el && typeof el.value === 'string');
    var before = hasValue ? el.value : null;
    var ok = false;
    try { ok = document.execCommand('insertText', false, text); } catch (e) { ok = false; }
    // execCommand can report success without changing anything on a controlled
    // input, so check the value rather than trusting the return.
    var changed = hasValue ? (el.value !== before) : ok;
    if (!changed && hasValue) {
      var start = el.selectionStart != null ? el.selectionStart : el.value.length;
      var end = el.selectionEnd != null ? el.selectionEnd : start;
      nativeSetValue(el, el.value.slice(0, start) + text + el.value.slice(end));
      try { el.setSelectionRange(start + text.length, start + text.length); } catch (e) {}
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
    }
    if (text.length === 1) { keyEvent('keyup', text, '', text.toUpperCase().charCodeAt(0)); }
  }

  function deleteBackward() {
    keyEvent('keydown', 'Backspace', 'Backspace', 8);
    var el = document.activeElement;
    var hasValue = el && ('value' in el && typeof el.value === 'string');
    var before = hasValue ? el.value : null;
    try { document.execCommand('delete'); } catch (e) {}
    if (hasValue && el.value === before && before.length) {
      var start = el.selectionStart != null ? el.selectionStart : before.length;
      var end = el.selectionEnd != null ? el.selectionEnd : start;
      if (start === end) { start = Math.max(0, start - 1); }
      nativeSetValue(el, before.slice(0, start) + before.slice(end));
      try { el.setSelectionRange(start, start); } catch (e) {}
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
    }
    keyEvent('keyup', 'Backspace', 'Backspace', 8);
  }

  function enter(shift) {
    var el = document.activeElement;
    if (!el) { return; }
    var proceed = keyEvent('keydown', 'Enter', 'Enter', 13);
    keyEvent('keypress', 'Enter', 'Enter', 13);
    if (proceed) {
      if (el.tagName === 'TEXTAREA') {
        insertText('\n');
      } else if (el.isContentEditable) {
        document.execCommand(shift ? 'insertLineBreak' : 'insertParagraph');
      } else if (el.tagName === 'INPUT' && el.form) {
        if (el.form.requestSubmit) { el.form.requestSubmit(); } else { el.form.submit(); }
      } else if (el.tagName !== 'SELECT' && el.click) {
        el.click();
      }
    }
    keyEvent('keyup', 'Enter', 'Enter', 13);
  }

  function blur() {
    var el = document.activeElement;
    if (el && el !== document.body && el.blur) { el.blur(); }
    reportFocus();
  }

  // Moves a <select> to the next enabled option and tells the page.
  function stepSelect(sel, delta) {
    var i = sel.selectedIndex, n = sel.options.length;
    for (var k = 0; k < n; k++) {
      i += delta;
      if (i < 0 || i >= n) { return; }
      if (!sel.options[i].disabled) { break; }
    }
    if (i === sel.selectedIndex) { return; }
    sel.selectedIndex = i;
    sel.dispatchEvent(new Event('input', { bubbles: true }));
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function caret(direction) {
    var el = document.activeElement;
    if (!el) { return; }
    var codes = { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };
    var proceed = keyEvent('keydown', direction, direction, codes[direction] || 0);
    if (proceed) {
      if (el.tagName === 'SELECT') {
        if (direction === 'ArrowUp' || direction === 'ArrowLeft') { stepSelect(el, -1); }
        else { stepSelect(el, 1); }
      } else if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null) {
        var pos = el.selectionStart, len = el.value.length;
        if (direction === 'ArrowLeft') { pos = Math.max(0, pos - 1); }
        else if (direction === 'ArrowRight') { pos = Math.min(len, pos + 1); }
        else if (direction === 'ArrowUp') { pos = 0; }
        else if (direction === 'ArrowDown') { pos = len; }
        try { el.setSelectionRange(pos, pos); } catch (e) {}
      } else {
        var sel = window.getSelection();
        if (sel && sel.modify) {
          var map = { ArrowLeft: ['backward', 'character'], ArrowRight: ['forward', 'character'], ArrowUp: ['backward', 'line'], ArrowDown: ['forward', 'line'] };
          var m = map[direction];
          if (m) { sel.modify('move', m[0], m[1]); }
        }
      }
    }
    keyEvent('keyup', direction, direction, codes[direction] || 0);
  }

  function focusNext(reverse) {
    var all = Array.prototype.slice.call(document.querySelectorAll(
      'a[href], button, input, select, textarea, summary, [tabindex]:not([tabindex="-1"]), [contenteditable="true"]'));
    all = all.filter(function (el) {
      if (el.disabled || el.tabIndex < 0) { return false; }
      var r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) { return false; }
      var cs = getComputedStyle(el);
      return cs.visibility !== 'hidden' && cs.display !== 'none';
    });
    if (!all.length) { return; }
    var idx = all.indexOf(document.activeElement);
    var next = reverse ? (idx <= 0 ? all.length - 1 : idx - 1) : (idx >= all.length - 1 ? 0 : idx + 1);
    var target = all[next];
    target.focus();
    if (target.scrollIntoViewIfNeeded) { target.scrollIntoViewIfNeeded(); } else { target.scrollIntoView({ block: 'center' }); }
  }

  // ---------------------------------------------------------------- select menus

  // Synthetic clicks never open WebKit's own <select> picker (and on the display it
  // would be untouchable anyway), so the options go to the native side as a menu.
  var pendingSelect = null;

  function requestSelect(sel) {
    if (!sel || sel.disabled) { return; }
    pendingSelect = sel;
    try { sel.focus(); } catch (e) {}
    var options = [];
    for (var i = 0; i < sel.options.length; i++) {
      var o = sel.options[i];
      options.push({ label: (o.label || o.textContent || '').trim().slice(0, 120),
                     disabled: !!o.disabled, selected: !!o.selected });
    }
    post({ type: 'select', options: options, multiple: !!sel.multiple });
  }

  function chooseOption(index) {
    var sel = pendingSelect;
    pendingSelect = null;
    if (!sel || index < 0 || index >= sel.options.length) { return; }
    if (sel.multiple) { sel.options[index].selected = !sel.options[index].selected; }
    else if (sel.selectedIndex === index) { return; }
    else { sel.selectedIndex = index; }
    sel.dispatchEvent(new Event('input', { bubbles: true }));
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // ---------------------------------------------------------------- pointer

  var lastHover = null;   // element in this document under the pointer
  var hoverFrame = null;  // frame element currently receiving forwarded hover
  var lastPressFrame = null;
  var press = null;       // { target, x, y, button, count, mods, moved, selecting, caret, mouseCanceled, frame }

  function fire(el, type, x, y, button, buttons, count, mods, pointer) {
    var init = {
      bubbles: true, cancelable: true, composed: true, view: window,
      clientX: x, clientY: y, screenX: x, screenY: y,
      button: button, buttons: buttons, detail: count,
      ctrlKey: !!mods.ctrl, shiftKey: !!mods.shift, altKey: !!mods.alt, metaKey: !!mods.meta
    };
    var ev;
    if (pointer && window.PointerEvent) {
      init.pointerId = 1; init.pointerType = 'mouse'; init.isPrimary = true;
      init.width = 1; init.height = 1; init.pressure = buttons ? 0.5 : 0;
      ev = new PointerEvent(type, init);
    } else {
      ev = new MouseEvent(type, init);
    }
    return el.dispatchEvent(ev);
  }

  function leaveHover(x, y, buttons, mods) {
    if (lastHover) {
      fire(lastHover, 'pointerout', x, y, 0, buttons, 0, mods, true);
      fire(lastHover, 'mouseout', x, y, 0, buttons, 0, mods, false);
      lastHover = null;
    }
  }

  // The pointer left this document (moved out of the frame, or onto another element in
  // the parent). Called in the frame that loses it.
  function pointerLeave() {
    leaveHover(-1, -1, 0, {});
    if (hoverFrame) { forward(hoverFrame, 'pointerLeave', []); hoverFrame = null; }
  }

  function pointerMove(x, y, buttons, mods) {
    mods = mods || {};
    if (press && press.frame) {
      var lp = frameLocalPoint(press.frame, x, y);
      forward(press.frame, 'pointerMove', [lp.x, lp.y, buttons, mods]);
      return;
    }
    var el = targetAt(x, y);
    if (isFrameElement(el)) {
      if (hoverFrame && hoverFrame !== el) { forward(hoverFrame, 'pointerLeave', []); }
      hoverFrame = el;
      leaveHover(x, y, buttons, mods);
      var p = frameLocalPoint(el, x, y);
      forward(el, 'pointerMove', [p.x, p.y, buttons, mods]);
      return;
    }
    if (hoverFrame) { forward(hoverFrame, 'pointerLeave', []); hoverFrame = null; }

    if (el !== lastHover) {
      leaveHover(x, y, buttons, mods);
      fire(el, 'pointerover', x, y, 0, buttons, 0, mods, true);
      fire(el, 'mouseover', x, y, 0, buttons, 0, mods, false);
      lastHover = el;
    }
    fire(el, 'pointermove', x, y, 0, buttons, 0, mods, true);
    fire(el, 'mousemove', x, y, 0, buttons, 0, mods, false);

    if (press && press.button === 0) {
      if (!press.moved && (Math.abs(x - press.x) > 3 || Math.abs(y - press.y) > 3)) { press.moved = true; }
      if (press.selecting && press.moved) {
        var r = caretAt(x, y), sel = window.getSelection();
        if (r && sel) {
          // The selection is created on the first real drag, anchored where the press
          // landed. A plain click therefore never touches the selection.
          if (press.caret) { sel.removeAllRanges(); sel.addRange(press.caret); press.caret = null; }
          if (sel.rangeCount) { try { sel.extend(r.startContainer, r.startOffset); } catch (e) {} }
        }
      }
    }
  }

  function pointerDown(x, y, button, count, mods) {
    mods = mods || {};
    var el = targetAt(x, y);
    if (isFrameElement(el)) {
      press = { frame: el, button: button, target: el, x: x, y: y, count: count, mods: mods };
      lastPressFrame = el;
      var p = frameLocalPoint(el, x, y);
      forward(el, 'pointerDown', [p.x, p.y, button, count, mods]);
      return;
    }
    lastPressFrame = null;
    var buttons = button === 0 ? 1 : (button === 2 ? 2 : 4);
    press = { target: el, x: x, y: y, button: button, count: count, mods: mods,
              moved: false, selecting: false, caret: null, mouseCanceled: false, frame: null, select: null };
    // <select> gets no mouse events at all. WebKit opens its own popup on mousedown, which
    // on the display would be an untouchable picker (and on macOS blocks the main thread);
    // the options go to the native side as a menu on release instead.
    var selectEl = closest(el, function (n) { return n.tagName === 'SELECT'; });
    if (selectEl && button === 0) {
      press.select = selectEl;
      try { selectEl.focus(); } catch (e) {}
      return;
    }
    // Cancelling pointerdown suppresses the compatibility mouse events (Pointer Events
    // spec); click still fires later.
    var pd = fire(el, 'pointerdown', x, y, button, buttons, count, mods, true);
    press.mouseCanceled = !pd;
    var md = pd ? fire(el, 'mousedown', x, y, button, buttons, count, mods, false) : true;
    if (button !== 0 || !md) { return; }

    var editable = closestEditable(el);
    if (editable) {
      editable.focus();
      if (editable.isContentEditable) {
        var r = caretAt(x, y), sel = window.getSelection();
        if (r && sel) {
          if (mods.shift && sel.rangeCount) { try { sel.extend(r.startContainer, r.startOffset); } catch (e) {} }
          else { sel.removeAllRanges(); sel.addRange(r); }
        }
        press.selecting = true;
      }
      return;
    }

    // A press on plain page content takes focus away from the focused field, as in any
    // browser. A press on a button or link does not, as in Safari on macOS: the composer
    // keeps the keyboard after its Send button is clicked.
    var active = document.activeElement;
    if (active && active !== document.body && (isEditable(active) || isFrameElement(active)) &&
        !containsAcrossShadow(active, el) && !closest(el, isInteractive)) {
      active.blur();
      reportFocus();
    }

    if (!isSelectable(el)) { return; }
    var sel2 = window.getSelection();
    var range = caretAt(x, y);
    if (!sel2 || !range) { return; }
    if (count === 2) {
      sel2.removeAllRanges(); sel2.addRange(range);
      try { sel2.modify('move', 'backward', 'word'); sel2.modify('extend', 'forward', 'word'); } catch (e) {}
    } else if (count >= 3) {
      sel2.removeAllRanges(); sel2.addRange(range);
      try { sel2.modify('move', 'backward', 'paragraphboundary'); sel2.modify('extend', 'forward', 'paragraphboundary'); } catch (e) {}
    } else if (mods.shift && sel2.rangeCount) {
      try { sel2.extend(range.startContainer, range.startOffset); } catch (e) {}
    } else {
      // Remember where the press landed; the selection itself starts on drag. Placing a
      // collapsed range here fired selectionchange on every click and left stray carets.
      if (sel2.rangeCount && !sel2.isCollapsed) { sel2.removeAllRanges(); }
      press.caret = range;
    }
    press.selecting = true;
  }

  // Click goes to the nearest common ancestor of the press and release targets (UI Events).
  function commonAncestor(a, b) {
    if (a === b) { return a; }
    var chain = [];
    var n = a;
    while (n) { chain.push(n); n = parentOf(n); }
    n = b;
    while (n) { if (chain.indexOf(n) !== -1) { return n; } n = parentOf(n); }
    return document.documentElement;
  }

  function pointerUp(x, y, button, count, mods) {
    mods = mods || {};
    var p = press; press = null;
    if (p && p.frame) {
      var lp = frameLocalPoint(p.frame, x, y);
      forward(p.frame, 'pointerUp', [lp.x, lp.y, button, count, mods]);
      return;
    }
    var el = targetAt(x, y);
    if (isFrameElement(el)) {
      // Pressed here, released over a frame: nothing to click.
      return;
    }
    if (p && p.select) {
      if (closest(el, function (n) { return n === p.select; })) { requestSelect(p.select); }
      return;
    }
    fire(el, 'pointerup', x, y, button, 0, count, mods, true);
    if (!p || !p.mouseCanceled) { fire(el, 'mouseup', x, y, button, 0, count, mods, false); }
    if (!p) { return; }
    var link = closestLink(el);

    if (button === 1) {
      fire(el, 'auxclick', x, y, 1, 0, count, mods, false);
      if (link && link.href) { post({ type: 'openTab', url: link.href }); }
      return;
    }
    if (button === 2) {
      if (fire(el, 'contextmenu', x, y, 2, 0, count, mods, false)) {
        post({ type: 'contextmenu', info: probe(x, y) });
      }
      return;
    }

    // A drag that produced a selection, or dragged a link/image, is not a click.
    var dist = Math.hypot(x - p.x, y - p.y);
    if (p.moved && p.selecting) {
      var s = window.getSelection();
      if (s && !s.isCollapsed && s.toString().length) { return; }
    }
    if (dist > 12 && closest(p.target, isInteractive) && !closestEditable(p.target)) { return; }

    var clickTarget = commonAncestor(p.target, el);
    if (link && (mods.meta || mods.ctrl) && link.href && !/^javascript:/i.test(link.href)) {
      post({ type: 'openTab', url: link.href });
      return;
    }
    fire(clickTarget, 'click', x, y, 0, 0, count, mods, false);
    if (count === 2) { fire(clickTarget, 'dblclick', x, y, 0, 0, 2, mods, false); }

    // WebKit opens a file chooser only from a real user gesture, which our clicks never are.
    var fileInput = closest(clickTarget, function (n) {
      if (n.tagName === 'INPUT' && (n.type || '').toLowerCase() === 'file') { return true; }
      return n.tagName === 'LABEL' && n.control && n.control.type === 'file';
    });
    if (fileInput) { post({ type: 'status', text: 'File pickers need a real tap: use "Type on phone" and tap the field there.' }); }
  }

  // ---------------------------------------------------------------- scrolling

  function canScroll(el, dx, dy) {
    var cs = getComputedStyle(el);
    var oy = cs.overflowY, ox = cs.overflowX;
    var root = el === document.scrollingElement || el === document.documentElement || el === document.body;
    var yOk = (oy === 'auto' || oy === 'scroll' || oy === 'overlay' || root) && el.scrollHeight > el.clientHeight + 1;
    var xOk = (ox === 'auto' || ox === 'scroll' || ox === 'overlay' || root) && el.scrollWidth > el.clientWidth + 1;
    if (dy > 0 && yOk && el.scrollTop + el.clientHeight < el.scrollHeight - 1) { return true; }
    if (dy < 0 && yOk && el.scrollTop > 0) { return true; }
    if (dx > 0 && xOk && el.scrollLeft + el.clientWidth < el.scrollWidth - 1) { return true; }
    if (dx < 0 && xOk && el.scrollLeft > 0) { return true; }
    return false;
  }

  function docCanScroll(dx, dy) {
    var se = document.scrollingElement || document.documentElement;
    var maxY = se.scrollHeight - window.innerHeight, maxX = se.scrollWidth - window.innerWidth;
    var y = window.scrollY, x = window.scrollX;
    return (dy > 0 && y < maxY - 1) || (dy < 0 && y > 0) || (dx > 0 && x < maxX - 1) || (dx < 0 && x > 0);
  }

  // Scrolls the nearest scrollable ancestor of `node`, then the document, then asks the
  // parent frame. Returns true when something scrolled.
  function chainScroll(node, dx, dy) {
    while (node && node !== document.documentElement && node !== document.body) {
      if (canScroll(node, dx, dy)) { node.scrollBy(dx, dy); return true; }
      node = parentOf(node);
    }
    if (docCanScroll(dx, dy)) { window.scrollBy(dx, dy); return true; }
    if (!isTop) {
      try { window.parent.postMessage({ __db: TOKEN, fn: 'scrollFromChild', args: [dx, dy] }, '*'); } catch (e) {}
    }
    return false;
  }

  function scrollAt(x, y, dx, dy) {
    var el = targetAt(x, y);
    if (isFrameElement(el)) {
      var p = frameLocalPoint(el, x, y);
      forward(el, 'scrollAt', [p.x, p.y, dx, dy]);
      return;
    }
    var ev = new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true });
    if (!el.dispatchEvent(ev)) { return; }
    chainScroll(el, dx, dy);
  }

  // ---------------------------------------------------------------- probe

  // What is under the point: cursor shape, link, image, editable, selection. `report`
  // makes the answer travel by message (used when a parent frame forwarded the call).
  function probe(x, y, report) {
    var el = targetAt(x, y);
    var result;
    if (isFrameElement(el)) {
      var p = frameLocalPoint(el, x, y);
      var api = sameOriginAPI(el);
      if (api) {
        result = api.probe(p.x, p.y, false) || { cursor: 'default' };
      } else {
        forward(el, 'probe', [p.x, p.y, true]);
        result = { frame: true };
      }
      if (report) { post({ type: 'probe', info: result }); }
      return result;
    }
    var link = closestLink(el);
    var img = el.tagName === 'IMG' ? el : null;
    var editable = closestEditable(el);
    var cursor = 'default';
    var node = el;
    while (node && node !== document.documentElement) {
      var c = getComputedStyle(node).cursor;
      if (c && c !== 'auto') { cursor = c; break; }
      node = parentOf(node);
    }
    if (cursor === 'auto' || cursor === 'default') {
      if (link || closest(el, function (n) { return n.tagName === 'BUTTON' || n.getAttribute('role') === 'button'; })) { cursor = 'pointer'; }
      else if (editable && editable.tagName !== 'SELECT') { cursor = 'text'; }
      else if (isSelectable(el)) {
        var r = caretAt(x, y);
        if (r && r.startContainer && r.startContainer.nodeType === 3) {
          var rect = null;
          try { var rr = document.createRange(); rr.selectNodeContents(r.startContainer); rect = rr.getBoundingClientRect(); } catch (e) {}
          if (rect && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) { cursor = 'text'; }
        }
      }
    }
    var selText = '';
    try { selText = window.getSelection().toString(); } catch (e) {}
    result = {
      cursor: cursor,
      href: link ? link.href : null,
      linkText: link ? (link.textContent || '').trim().slice(0, 100) : null,
      src: img ? img.currentSrc || img.src : null,
      editable: !!editable,
      selection: selText.slice(0, 500)
    };
    if (report) { post({ type: 'probe', info: result }); }
    return result;
  }

  // ---------------------------------------------------------------- clipboard

  function selectionText() {
    var el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null) {
      return el.value.substring(el.selectionStart, el.selectionEnd);
    }
    try { return window.getSelection().toString(); } catch (e) { return ''; }
  }

  // Copy and cut report through a message so they work from any frame. When this
  // document has nothing selected, the frame that last took a press is asked instead.
  function copySelection(cut) {
    var text = selectionText();
    if (!text && lastPressFrame) { forward(lastPressFrame, 'copySelection', [cut]); return; }
    post({ type: 'clipboard', text: text, cut: !!cut });
    if (cut && text) { document.execCommand('delete'); }
  }

  function selectAll() {
    var el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) { el.select(); return; }
    if (el && el.isContentEditable) { document.execCommand('selectAll'); return; }
    var sel = window.getSelection(); var r = document.createRange();
    r.selectNodeContents(document.body); sel.removeAllRanges(); sel.addRange(r);
  }

  window.__db = {
    showHints: showHints,
    hideHints: hideHints,
    hintKey: hintKey,
    insertText: routed('insertText', insertText),
    deleteBackward: routed('deleteBackward', deleteBackward),
    enter: routed('enter', enter),
    blur: routed('blur', blur),
    caret: routed('caret', caret),
    focusNext: routed('focusNext', focusNext),
    activeEditable: activeEditable,
    pointerMove: pointerMove,
    pointerDown: pointerDown,
    pointerUp: pointerUp,
    pointerLeave: pointerLeave,
    scrollAt: scrollAt,
    probe: probe,
    copySelection: routed('copySelection', copySelection),
    selectAll: routed('selectAll', selectAll),
    chooseOption: routed('chooseOption', chooseOption)
  };
})();
