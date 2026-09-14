defmodule Compos.Ui.SelectionReportTest do
  use ExUnit.Case, async: true

  test "selection reports require a gesture and cannot outlive a patch or typing" do
    src = File.read!(Path.expand("../../../lib/compos/ui/layouts.ex", __DIR__))
    [_, rest] = String.split(src, "this.selChangeH = () => {", parts: 2)
    [body, _] = String.split(rest, "document.addEventListener(\"selectionchange\"", parts: 2)
    script = """
    const assert = require('node:assert/strict');
    let timer;
    globalThis.setTimeout = f => { timer = f; return 1; };
    globalThis.clearTimeout = () => { timer = null; };
    globalThis.performance = {now: () => 200};
    const win = {classList: {contains: () => true}};
    const buf = {isConnected: true, dataset: {pt: '5'},
      closest: () => win, contains: () => true,
      hasAttribute: name => name === 'contenteditable'};
    globalThis.document = {activeElement: {closest: () => buf}};
    globalThis.window = {getSelection: () => ({isCollapsed: true, focusNode: {}, focusOffset: 2})};
    const domByte = () => 2;
    const markCurrentRow = () => {};
    let reports = 0;
    const hook = {_gestureAt: 100, _patchAt: 50, sendSelection: () => reports++};
    (function () { this.selChangeH = () => {#{body} }).call(hook);
    hook.selChangeH();
    assert.equal(hook._selPending, true);
    hook._patchAt = 150;
    timer();
    assert.equal(reports, 0, 'patch-induced caret must not be sent');
    hook._patchAt = 50;
    hook._gestureAt = 100;
    hook.selChangeH();
    hook._gestureAt = 0;
    timer();
    assert.equal(reports, 0, 'typing invalidates a delayed selection');
    timer = null;
    hook.selChangeH();
    assert.equal(timer, null, 'no selection report without a gesture');
    hook._gestureAt = 100;
    hook.selChangeH();
    timer();
    assert.equal(reports, 1, 'real caret motion still reports');
    """
    path = Path.join(System.tmp_dir!(), "compos-selection-#{System.unique_integer([:positive])}.js")
    File.write!(path, script)
    try do
      {output, status} = System.cmd("node", [path], stderr_to_stdout: true)
      assert status == 0, output
    after
      File.rm(path)
    end
  end
end
