defmodule Compos.Ui.TranscriptSettleTest do
  @moduledoc """
  The BlockFollow hook's `place`, `observe` and `settle`, run as the code
  they are.

  A chat follows its tail, so a load must land at the end of the
  transcript. A window that is hidden or not laid out yet reports no
  height and a short scrollHeight. Placing then puts a long chat near its
  top, and the reader finds their chat scrolled back hundreds of blocks.
  The height arrives late and keeps changing after it arrives, so the
  hook has to keep placing until it stops.
  """

  use ExUnit.Case, async: true

  @app_js Path.expand("../../../priv/static/app.js", __DIR__)

  # place(), observe() and settle() are the three methods between
  # BlockFollow's place and its updated, in that order.
  defp hook_source do
    src = File.read!(@app_js)
    [_, rest] = String.split(src, "      place() {", parts: 2)
    [body, _] = String.split(rest, "      updated() {", parts: 2)
    "const hook = {\n      place() {" <> body <> "};"
  end

  # A scroller that starts with no height, gains one at frame LAID, and
  # keeps growing for GROW frames after that. FRAMES animation frames run
  # in order; a resize fires the observers, as the browser does.
  defp run(opts) do
    laid = Keyword.fetch!(opts, :laid)
    grow = Keyword.fetch!(opts, :grow)
    frames = Keyword.get(opts, :frames, 60)
    reader_at = Keyword.get(opts, :reader_at, -1)
    resize_at = Keyword.get(opts, :resize_at, -1)

    script = """
    const LAID = #{laid}, GROW = #{grow}, FRAMES = #{frames};
    const READER_AT = #{reader_at}, RESIZE_AT = #{resize_at};

    const pending = new Map();
    let nextId = 1;
    globalThis.requestAnimationFrame = (fn) => {
      const id = nextId++;
      pending.set(id, fn);
      return id;
    };
    globalThis.cancelAnimationFrame = (id) => pending.delete(id);
    const tick = () => {
      const due = [...pending.values()];
      pending.clear();
      due.forEach((fn) => fn());
    };

    const observers = [];
    globalThis.ResizeObserver = class {
      constructor(cb) { this.cb = cb; observers.push(this); }
      observe() {}
      disconnect() {
        const i = observers.indexOf(this);
        if (i >= 0) observers.splice(i, 1);
      }
    };
    const resized = () => observers.slice().forEach((o) => o.cb());

    const s = {
      isConnected: true,
      clientHeight: 0,
      scrollHeight: 800,
      scrollTop: 0,
      contains: () => true,
      getBoundingClientRect: () => ({
        top: 0, left: 0, width: 800,
        height: s.clientHeight, bottom: s.clientHeight
      })
    };
    const el = { dataset: { scrollTop: "0" }, querySelector: () => null };

    #{hook_source()}
    Object.assign(hook, {
      scroller: s, el: el, stick: true, anchor: null, offset: 0,
      placing: false, ro: null, reader: false, raf: null
    });

    hook.settle();
    for (let f = 0; f < FRAMES; f++) {
      if (f === LAID) {
        // the window is laid out: a real height, and a transcript
        // taller than the stub height it reported while hidden
        s.clientHeight = 500;
        s.scrollHeight = 2000;
        resized();
      }
      if (f > LAID && f <= LAID + GROW) {
        // fonts land, images decode, late patches arrive
        s.scrollHeight += 300;
      }
      if (f === READER_AT) hook.reader = true;
      if (f === RESIZE_AT) {
        s.clientHeight = 300;
        resized();
      }
      tick();
    }

    process.stdout.write(JSON.stringify({
      top: s.scrollTop,
      bottom: s.scrollHeight - s.clientHeight,
      height: s.scrollHeight
    }));
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "compos-settle-#{System.unique_integer([:positive])}.js"
      )

    File.write!(path, script)

    try do
      {out, 0} = System.cmd("node", [path], stderr_to_stdout: true)
      Jason.decode!(out)
    after
      File.rm(path)
    end
  end

  test "a window laid out at once lands at the end" do
    got = run(laid: 0, grow: 10)
    assert got["top"] == got["bottom"]
  end

  test "a window laid out late still lands at the end" do
    # the settle's still-frame count ran out long before frame 20
    got = run(laid: 20, grow: 10)
    assert got["top"] == got["bottom"]
    assert got["height"] == 5000
  end

  test "a resize after the settle re-places the tail" do
    got = run(laid: 2, grow: 4, resize_at: 40)
    assert got["top"] == got["bottom"]
  end

  test "the reader's gesture ends it" do
    got = run(laid: 2, grow: 30, reader_at: 6)
    assert got["top"] < got["bottom"]
  end
end
