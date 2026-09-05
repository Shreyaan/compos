defmodule Compos.LayoutPolicyTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}
  @suite Path.join([:code.priv_dir(:compos_core), "tests", "layout-policy-test.scm"])
  @names Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@suite)) |> Enum.map(&List.last/1)

  setup do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    assert {:ok, old_auto} = Session.eval("autolayout-mode", frame)
    assert {:ok, _} = Session.eval(~s|(load "#{@suite}")|, frame)

    on_exit(fn ->
      Session.eval(
        """
        (set! *layout-busy* #f)
        (set! *winner-inhibit* #f)
        (set! *group-current-inhibit* #t)
        (customize-set! 'autolayout-mode #{old_auto})
        (for-each (lambda (g)
                    (when (string-prefix? "zz-lp-" (group-name g))
                      (for-each buffer-kill! (group-buffers g))
                      (group-record-delete! g)))
                  (group-ids))
        (for-each (lambda (b)
                    (when (string-prefix? "zz-lp-" b) (buffer-kill! b)))
                  (buffer-list))
        (set! *group-current-inhibit* #f)
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end)

    %{frame: frame}
  end

  for name <- @names do
    test name, %{frame: frame} do
      result = Session.eval("(run-test '#{unquote(name)})", frame)
      {:ok, trace} = Session.eval("*lp-trace*", frame)
      IO.puts("GEOMETRY #{unquote(name)}\n#{trace}")
      assert result == {:ok, "()"}, inspect(result) <> "\n" <> trace
    end
  end

  for side <- ["a", "b"] do
    test "new chat replaces selected #{side} pane without rebuilding windows", %{frame: frame} do
      assert {:ok, _} =
               Session.eval(
                 """
                 (lp-start!) (lp-buffer! "b")
                 (tile-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
                 (layout-target-set! 'two-pane)
                 (select-window! (window-showing "zz-lp-#{unquote(side)}"))
                 (define lp-chat-window (active-window))
                 (define lp-chat-old (current-buffer))
                 (define lp-chat-group (frame-group))
                 (define lp-chat-windows (window-list))
                 (define lp-chat-geometry (map (lambda (r) (cons (car r) (cddr r))) (window-rects)))
                 """,
                 frame
               )

      for key <- ["C-c", "n"], do: KeyDispatch.handle_key(frame, key)

      assert {:ok, "#t"} =
               Session.eval(
                 """
                 (and (chat-buffer? (current-buffer))
                      (buffer-in-group? (current-buffer) lp-chat-group)
                      (equal? (active-window) lp-chat-window)
                      (equal? (layout-target) 'two-pane)
                      (equal? lp-chat-geometry
                        (map (lambda (r) (cons (car r) (cddr r))) (window-rects)))
                      (equal? (car (window-buffer-history lp-chat-window)) lp-chat-old)
                      (equal? (window-list)
                        (map (lambda (r) (if (equal? (car r) lp-chat-window)
                                             (list (car r) (current-buffer)) r)) lp-chat-windows)))
                 """,
                 frame
               )

      assert {:ok, "#t"} =
               Session.eval(
                 """
                 (buffer-kill! (current-buffer))
                 (and (equal? (window-list) lp-chat-windows)
                      (equal? (active-window) lp-chat-window)
                      (equal? lp-chat-geometry
                        (map (lambda (r) (cons (car r) (cddr r))) (window-rects))))
                 """,
                 frame
               )
    end
  end

  test "keyboard layout selection and pane closing reflow through the GUI path", %{frame: frame} do
    assert {:ok, _} = Session.eval("(lp-start!)", frame)

    for key <- ["M-x"] ++ String.graphemes("window-layout-rows") ++ ["RET"],
        do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "rows"} = Session.eval("(layout-target)", frame)

    assert {:ok, _} =
             Session.eval(
               """
               (lp-buffer! "b") (switch-to-buffer! "zz-lp-b")
               (lp-buffer! "c") (switch-to-buffer! "zz-lp-c")
               (select-window! (window-showing "zz-lp-b"))
               """,
               frame
             )

    for key <- ["C-x", "0"], do: KeyDispatch.handle_key(frame, key)
    assert {:ok, "2"} = Session.eval("(length (window-list))", frame)

    assert {:ok, "#t"} =
             Session.eval(
               """
               (equal? (map cdr (window-rects))
                 '(("zz-lp-a" 0.0 0.0 1.0 0.5) ("zz-lp-c" 0.0 0.5 1.0 0.5)))
               """,
               frame
             )

    assert {:ok, before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "l", "C-g"], do: KeyDispatch.handle_key(frame, key)
    assert {:ok, ^before} = Session.eval("(map cdr (window-rects))", frame)
    assert {:ok, "rows"} = Session.eval("(layout-target)", frame)
  end

  test "existing responsive policy and sealed fill tests", %{frame: frame} do
    path = Path.join([:code.priv_dir(:compos_core), "tests", "layouts-test.scm"])
    assert {:ok, _} = Session.eval(~s|(load "#{path}")|, frame)

    for [_, name] <- Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(path)) do
      result = Session.eval("(run-test '#{name})", frame)
      assert result == {:ok, "()"}, name <> ": " <> inspect(result)
    end
  end

  test "a real file visit fills the target before replacing work", %{frame: frame} do
    path = Path.join(System.tmp_dir!(), "zz-lp-visit-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "file visit\n")

    on_exit(fn ->
      Session.eval(~s|(buffer-kill! "#{path}")|, frame)
      File.rm(path)
    end)

    assert {:ok, _} = Session.eval("(lp-start!) (run-command \"window-layout-two-pane\")", frame)
    assert {:ok, _} = Session.eval(~s|(visit "#{path}")|, frame)
    assert {:ok, "2"} = Session.eval("(length (window-list))", frame)
    assert {:ok, "#t"} = Session.eval(~s|(buffer-in-group? "#{path}" (frame-group))|, frame)
    assert Session.eval("(current-buffer)", frame) == {:ok, ~s|"#{path}"|}
  end

  test "moving the layout highlight previews actual geometry and buffers", %{frame: frame} do
    assert {:ok, _} =
             Session.eval(
               """
               (lp-start!) (lp-buffer! "b") (lp-buffer! "c")
               (tile-windows! 'main-right '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
               (layout-target-set! 'main-right)
               """,
               frame
             )

    assert {:ok, before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "l", "C-n"], do: KeyDispatch.handle_key(frame, key)
    assert {:ok, "2"} = Session.eval("(length (window-list))", frame)
    KeyDispatch.handle_key(frame, "C-n")
    assert {:ok, "3"} = Session.eval("(length (window-list))", frame)
    KeyDispatch.handle_key(frame, "C-n")

    assert {:ok, "()"} =
             Session.eval(
               """
               (set! *test-failures* '())
               (lp-rect! "zz-lp-a" 0 0 1 (/ 1 3))
               (lp-rect! "zz-lp-b" 0 (/ 1 3) 1 (/ 1 3))
               (lp-rect! "zz-lp-c" 0 (/ 2 3) 1 (/ 1 3))
               *test-failures*
               """,
               frame
             )

    assert {:ok, "main-right"} = Session.eval("(layout-target)", frame)
    KeyDispatch.handle_key(frame, "C-g")
    assert {:ok, ^before} = Session.eval("(map cdr (window-rects))", frame)
  end

  test "hidden group chat previews in rows and fills a user split", %{frame: frame} do
    assert {:ok, _} = Session.eval("(lp-start!) (group-chat (frame-group))", frame)
    assert {:ok, before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "l", "C-n", "C-n", "C-n"], do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "()"} =
             Session.eval(
               """
               (set! *test-failures* '())
               (lp-rect! "zz-lp-a" 0 0 1 0.5)
               (lp-rect! (group-chat (frame-group)) 0 0.5 1 0.5)
               *test-failures*
               """,
               frame
             )

    KeyDispatch.handle_key(frame, "C-g")
    assert {:ok, ^before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "3"], do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "#t"} =
             Session.eval(
               """
               (equal? (map cadr (window-list)) (list "zz-lp-a" (group-chat (frame-group))))
               """,
               frame
             )

    assert {:ok, ~s|"zz-lp-a"|} = Session.eval("(current-buffer)", frame)
  end

  test "layout previews preserve the displayed list and file before hidden group members", %{
    frame: frame
  } do
    assert {:ok, _} =
             Session.eval(
               """
               (lp-start!) (lp-buffer! "list") (group-chat (frame-group))
               (buffer-remove-group! "zz-lp-list" (frame-group))
               (buffer-set-local! "zz-lp-list" 'transient #t)
               (tile-windows! 'columns '("zz-lp-list" "zz-lp-a"))
               (layout-target-set! 'columns)
               """,
               frame
             )

    assert {:ok, before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "l", "C-n"], do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "()"} =
             Session.eval(
               """
               (set! *test-failures* '())
               (check-equal! (map cadr (window-list)) '("zz-lp-list" "zz-lp-a") "visible slots retain buffers")
               (lp-rect! "zz-lp-list" 0 0 (/ 2 3) 1)
               (lp-rect! "zz-lp-a" (/ 2 3) 0 (/ 1 3) 1)
               *test-failures*
               """,
               frame
             )

    for key <- ["C-n", "C-p"], do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "#t"} =
             Session.eval(
               "(equal? (map cadr (window-list)) '(\"zz-lp-list\" \"zz-lp-a\"))",
               frame
             )

    KeyDispatch.handle_key(frame, "C-g")
    assert {:ok, ^before} = Session.eval("(map cdr (window-rects))", frame)
    for key <- ["C-x", "l", "C-n", "RET"], do: KeyDispatch.handle_key(frame, key)

    assert {:ok, "#t"} =
             Session.eval(
               "(equal? (map cadr (window-list)) '(\"zz-lp-list\" \"zz-lp-a\"))",
               frame
             )

    assert {:ok, "two-pane"} = Session.eval("(layout-target)", frame)
  end

  test "Cmd-RET preserves a main pane on the right", %{frame: frame} do
    assert {:ok, _} =
             Session.eval(
               """
               (lp-start!) (lp-buffer! "b")
               (tile-windows! 'main-left '("zz-lp-a" "zz-lp-b"))
               (layout-target-set! 'main-left)
               """,
               frame
             )

    assert {:ok, before} = Session.eval("(map cdr (window-rects))", frame)
    KeyDispatch.handle_key(frame, "s-RET")
    assert {:ok, ^before} = Session.eval("(map cdr (window-rects))", frame)
    assert {:ok, "main-left"} = Session.eval("(layout-target)", frame)
    assert {:ok, _} = Session.eval("(select-window! (window-showing \"zz-lp-b\"))", frame)
    KeyDispatch.handle_key(frame, "s-RET")

    assert {:ok, "()"} =
             Session.eval(
               """
               (set! *test-failures* '())
               (lp-rect! "zz-lp-b" (- 1 window-layout-main-ratio) 0 window-layout-main-ratio 1)
               (check-equal! (layout-target) 'main-left "promotion preserves the chosen main side")
               *test-failures*
               """,
               frame
             )
  end
end
