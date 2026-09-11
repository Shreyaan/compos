defmodule Compos.ZzProbeTest do
  use ExUnit.Case
  alias Compos.Core.{Agent, Session}

  test "probe" do
    {:ok, printed} =
      Session.eval("""
      (execute* "go" '(permission-mode ask backend "stub" script
        (((type chunk text "working…")
          (type permission rpc-id 3 title "Write x" kind "edit"
                options (("opt-allow" "Allow" "allow_once")))))))
      """)

    slug = String.trim(printed, "\"")
    Process.sleep(2000)
    IO.inspect(slug, label: "slug")
    IO.inspect(Agent.list(), label: "agents")
    IO.inspect(Agent.info(slug), label: "info")
    IO.inspect(Compos.Core.list_buffers() |> Enum.filter(&String.contains?(&1, "chat")), label: "bufs")
    IO.inspect(Compos.Core.Buffer.text("*chat:a1*"), label: "text")
  end
end
