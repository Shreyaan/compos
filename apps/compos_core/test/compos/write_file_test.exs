defmodule Compos.WriteFileTest do
  use Compos.Case, async: false

  alias Compos.Core.{Editor, Session}
  # A verb by its name. Which key reaches it is a preference that moves.
  defp run(command), do: {:ok, _} = Session.eval(~s[(run-command "#{command}")])

  defp fresh_buffer(text) do
    name = "*zz-write-file-#{System.unique_integer([:positive])}*"

    {:ok, _} =
      Session.eval(
        ~s{(begin (buffer-create "#{name}") (switch-to-buffer! "#{name}") (buffer-insert! "#{name}" 0 "#{text}"))}
      )

    name
  end

  describe "the write prompt" do
    setup do
      Editor.minibuffer_close()
      root = Path.join(System.tmp_dir!(), "compos-wf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "foo-bar.txt"), "X")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "RET writes the typed name although another file fuzzy-matches it", %{root: root} do
      buf = fresh_buffer("fresh text")
      run("write-file")

      Editor.minibuffer_set_input(root <> "/")
      type("foo.txt")
      mb = Editor.render_state().minibuffer
      assert [%{label: "foo-bar.txt"} | _] = mb.candidates

      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "foo.txt")
      assert File.read!(Path.join(root, "foo.txt")) == "fresh text"
      assert File.read!(Path.join(root, "foo-bar.txt")) == "X"
      refute Compos.Core.Buffer.exists?(buf)

      # the buffer is the file now: the next save asks nothing
      run("save-buffer")
      assert Editor.render_state().minibuffer == nil
      assert Editor.current_buffer() == Path.join(root, "foo.txt")
    end

    test "C-n then RET writes over the candidate the person chose", %{root: root} do
      fresh_buffer("chosen")
      run("write-file")

      Editor.minibuffer_set_input(root <> "/")
      type("foo.txt")
      press(["C-n", "RET"])

      assert Editor.current_buffer() == Path.join(root, "foo-bar.txt")
      assert File.read!(Path.join(root, "foo-bar.txt")) == "chosen"
    end

    test "a directory answer writes the buffer name into it", %{root: root} do
      buf = fresh_buffer("into dir")
      stem = String.trim(buf, "*")
      run("write-file")

      Editor.minibuffer_set_input(root <> "/")
      press(["RET"])

      assert Editor.current_buffer() == Path.join(root, stem)
      assert File.read!(Path.join(root, stem)) == "into dir"
    end
  end
end
