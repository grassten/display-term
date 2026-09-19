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

  function insertText(text) {
    var el = document.activeElement;
    if (!el) { return; }
    if (text.length === 1) {
      keyEvent('keydown', text, '', text.toUpperCase().charCodeAt(0));
      keyEvent('keypress', text, '', text.charCodeAt(0));
    }
    if (!document.execCommand('insertText', false, text)) {
      if ('value' in el && typeof el.value === 'string') {
        var start = el.selectionStart != null ? el.selectionStart : el.value.length;
        var end = el.selectionEnd != null ? el.selectionEnd : start;
        el.value = el.value.slice(0, start) + text + el.value.slice(end);
        try { el.setSelectionRange(start + text.length, start + text.length); } catch (e) {}
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    if (text.length === 1) { keyEvent('keyup', text, '', text.toUpperCase().charCodeAt(0)); }
  }

  function deleteBackward() {
    keyEvent('keydown', 'Backspace', 'Backspace', 8);
    document.execCommand('delete');
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
    activeEditable: activeEditable
  };
})();
