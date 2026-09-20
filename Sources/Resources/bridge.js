// Injected into every page at document start (main frame only).
// Provides keyboard-only navigation primitives: link hints, focus tracking,
// text insertion, caret movement and focus cycling. Native side: Bridge.swift.
(function () {
  if (window.__db) { return; }

  function post(message) {
    try { window.webkit.messageHandlers.db.postMessage(message); } catch (e) {}
  }

  var NON_TEXT_INPUTS = ['button', 'submit', 'checkbox', 'radio', 'file', 'image', 'reset', 'range', 'color', 'hidden'];

  function isEditable(el) {
    if (!el || el === document.body) { return false; }
    var tag = el.tagName;
    if (tag === 'TEXTAREA' || tag === 'SELECT') { return true; }
    if (tag === 'INPUT') { return NON_TEXT_INPUTS.indexOf((el.type || 'text').toLowerCase()) === -1; }
    return el.isContentEditable === true;
  }

  function activeEditable() { return isEditable(document.activeElement); }

  document.addEventListener('focusin', function (e) { post({ type: 'focus', editable: isEditable(e.target) }); }, true);
  document.addEventListener('focusout', function () {
    setTimeout(function () { post({ type: 'focus', editable: activeEditable() }); }, 0);
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
    var link = el.tagName === 'A' ? el : (el.closest ? el.closest('a[href]') : null);
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

  // ---------------------------------------------------------------- insert mode

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
      } else if (el.click) {
        el.click();
      }
    }
    keyEvent('keyup', 'Enter', 'Enter', 13);
  }

  function blur() {
    var el = document.activeElement;
    if (el && el !== document.body && el.blur) { el.blur(); }
  }

  function caret(direction) {
    var el = document.activeElement;
    if (!el) { return; }
    var codes = { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };
    var proceed = keyEvent('keydown', direction, direction, codes[direction] || 0);
    if (proceed) {
      if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null) {
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


  // ---------------------------------------------------------------- pointer

  var lastHover = null;
  var press = null; // { target, x, y, button, moved, selecting }

  function targetAt(x, y) {
    return document.elementFromPoint(x, y) || document.documentElement;
  }

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
      ev = new PointerEvent(type, init);
    } else {
      ev = new MouseEvent(type, init);
    }
    return el.dispatchEvent(ev);
  }

  function closestEditable(el) {
    while (el && el !== document.documentElement) {
      if (isEditable(el)) { return el; }
      el = el.parentElement;
    }
    return null;
  }

  function closestLink(el) {
    return el && el.closest ? el.closest('a[href]') : null;
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

  function pointerMove(x, y, buttons, mods) {
    mods = mods || {};
    var el = targetAt(x, y);
    if (el !== lastHover) {
      if (lastHover) {
        fire(lastHover, 'pointerout', x, y, 0, buttons, 0, mods, true);
        fire(lastHover, 'mouseout', x, y, 0, buttons, 0, mods, false);
      }
      fire(el, 'pointerover', x, y, 0, buttons, 0, mods, true);
      fire(el, 'mouseover', x, y, 0, buttons, 0, mods, false);
      lastHover = el;
    }
    fire(el, 'pointermove', x, y, 0, buttons, 0, mods, true);
    fire(el, 'mousemove', x, y, 0, buttons, 0, mods, false);
    if (press && press.button === 0) {
      if (Math.abs(x - press.x) > 4 || Math.abs(y - press.y) > 4) { press.moved = true; }
      if (press.selecting && press.moved) {
        var r = caretAt(x, y), sel = window.getSelection();
        if (r && sel && sel.rangeCount) {
          try { sel.extend(r.startContainer, r.startOffset); } catch (e) {}
        }
      }
    }
  }

  function pointerDown(x, y, button, count, mods) {
    mods = mods || {};
    var el = targetAt(x, y);
    var buttons = button === 0 ? 1 : (button === 2 ? 2 : 4);
    post({ type: 'debug', info: 'down at ' + Math.round(x) + ',' + Math.round(y) +
      ' tag=' + el.tagName + (el.id ? '#' + el.id : '') +
      ' editable=' + !!closestEditable(el) +
      ' frame=' + (window.top === window ? 'main' : 'sub') });
    fire(el, 'pointerdown', x, y, button, buttons, count, mods, true);
    var proceed = fire(el, 'mousedown', x, y, button, buttons, count, mods, false);
    press = { target: el, x: x, y: y, button: button, moved: false, selecting: false, count: count };
    if (button !== 0 || !proceed) { return; }

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

    var active = document.activeElement;
    if (active && active !== document.body && isEditable(active) && !el.contains(active)) { active.blur(); }

    var sel2 = window.getSelection();
    var range = caretAt(x, y);
    if (sel2 && range && !closestLink(el)) {
      if (count === 2) {
        sel2.removeAllRanges(); sel2.addRange(range);
        try { sel2.modify('move', 'backward', 'word'); sel2.modify('extend', 'forward', 'word'); } catch (e) {}
      } else if (count >= 3) {
        sel2.removeAllRanges(); sel2.addRange(range);
        try { sel2.modify('move', 'backward', 'paragraphboundary'); sel2.modify('extend', 'forward', 'paragraphboundary'); } catch (e) {}
      } else if (mods.shift && sel2.rangeCount) {
        try { sel2.extend(range.startContainer, range.startOffset); } catch (e) {}
      } else {
        sel2.removeAllRanges(); sel2.addRange(range);
      }
      press.selecting = true;
    }
  }

  function pointerUp(x, y, button, count, mods) {
    mods = mods || {};
    var el = targetAt(x, y);
    fire(el, 'pointerup', x, y, button, 0, count, mods, true);
    fire(el, 'mouseup', x, y, button, 0, count, mods, false);
    var p = press; press = null;
    if (!p) { return; }
    var link = closestLink(el);

    if (button === 1) {
      fire(el, 'auxclick', x, y, 1, 0, count, mods, false);
      if (link && link.href) { post({ type: 'openTab', url: link.href }); }
      return;
    }
    if (button === 2) {
      fire(el, 'contextmenu', x, y, 2, 0, count, mods, false);
      return;
    }
    if (p.moved) { return; }

    var clickTarget = el;
    if (p.target !== el) {
      clickTarget = p.target.contains(el) ? p.target : (el.contains(p.target) ? el : null);
      if (!clickTarget) {
        var a = p.target;
        while (a && !a.contains(el)) { a = a.parentElement; }
        clickTarget = a || document.documentElement;
      }
    }
    if (link && (mods.meta || mods.ctrl) && link.href && !/^javascript:/i.test(link.href)) {
      post({ type: 'openTab', url: link.href });
      return;
    }
    fire(clickTarget, 'click', x, y, 0, 0, count, mods, false);
    if (count === 2) { fire(clickTarget, 'dblclick', x, y, 0, 0, 2, mods, false); }
  }

  function canScroll(el, dx, dy) {
    var cs = getComputedStyle(el);
    var oy = cs.overflowY, ox = cs.overflowX;
    var yOk = (oy === 'auto' || oy === 'scroll' || oy === 'overlay' || el === document.scrollingElement) && el.scrollHeight > el.clientHeight + 1;
    var xOk = (ox === 'auto' || ox === 'scroll' || ox === 'overlay' || el === document.scrollingElement) && el.scrollWidth > el.clientWidth + 1;
    if (dy > 0 && yOk && el.scrollTop + el.clientHeight < el.scrollHeight - 1) { return true; }
    if (dy < 0 && yOk && el.scrollTop > 0) { return true; }
    if (dx > 0 && xOk && el.scrollLeft + el.clientWidth < el.scrollWidth - 1) { return true; }
    if (dx < 0 && xOk && el.scrollLeft > 0) { return true; }
    return false;
  }

  function scrollAt(x, y, dx, dy) {
    var el = targetAt(x, y);
    var ev = new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true });
    if (!el.dispatchEvent(ev)) { return; }
    var node = el;
    while (node && node !== document.documentElement && node !== document.body) {
      if (canScroll(node, dx, dy)) { node.scrollBy(dx, dy); return; }
      node = node.parentElement;
    }
    window.scrollBy(dx, dy);
  }

  function probe(x, y) {
    var el = targetAt(x, y);
    var link = closestLink(el);
    var img = el.tagName === 'IMG' ? el : null;
    var editable = closestEditable(el);
    var cursor = 'default';
    var node = el;
    while (node && node !== document.documentElement) {
      var c = getComputedStyle(node).cursor;
      if (c && c !== 'auto') { cursor = c; break; }
      node = node.parentElement;
    }
    if (cursor === 'auto' || cursor === 'default') {
      if (link || el.tagName === 'BUTTON' || el.getAttribute('role') === 'button') { cursor = 'pointer'; }
      else if (editable) { cursor = 'text'; }
      else {
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
    return {
      cursor: cursor,
      href: link ? link.href : null,
      linkText: link ? (link.textContent || '').trim().slice(0, 100) : null,
      src: img ? img.currentSrc || img.src : null,
      editable: !!editable,
      selection: selText.slice(0, 500)
    };
  }

  function getSelectionText() {
    var el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.selectionStart != null) {
      return el.value.substring(el.selectionStart, el.selectionEnd);
    }
    try { return window.getSelection().toString(); } catch (e) { return ''; }
  }

  function selectAll() {
    var el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) { el.select(); return; }
    if (el && el.isContentEditable) { document.execCommand('selectAll'); return; }
    var sel = window.getSelection(); var r = document.createRange();
    r.selectNodeContents(document.body); sel.removeAllRanges(); sel.addRange(r);
  }

  function deleteSelection() {
    document.execCommand('delete');
  }

  window.__db = {
    showHints: showHints,
    hideHints: hideHints,
    hintKey: hintKey,
    insertText: insertText,
    deleteBackward: deleteBackward,
    enter: enter,
    blur: blur,
    caret: caret,
    focusNext: focusNext,
    activeEditable: activeEditable,
    pointerMove: pointerMove,
    pointerDown: pointerDown,
    pointerUp: pointerUp,
    scrollAt: scrollAt,
    probe: probe,
    getSelectionText: getSelectionText,
    selectAll: selectAll,
    deleteSelection: deleteSelection
  };
})();
