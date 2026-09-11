defmodule Compos.DesktopSessionRestartTest do
  @moduledoc """
  Every persisted global lives in a Scheme variable, so the Session owns
  them all. When the Session dies, its replacement boots a new interpreter
  holding only the defvar defaults, while the frames and buffers on the
  Elixir side carry on unchanged. The desktop must put the values back, and
  it must never write the defaults over the file in the meantime.

  On 2026-09-11 it wrote them: one autosave replaced 35 group records, the
  group graveyard, both connector catalogs and every history with the
  empty set.
  """

  use ExUnit.Case

  alias Compos.Core.{Desktop, Session}

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  defp group_record?(name) do
    case Session.eval(~s{(and (member "#{name}" (map group-record-name *group-records*)) #t)}) do
      {:ok, "#t"} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  # A replacement Session registers its name before init/1 loads the stdlib.
  # A call queues behind that load, so it returns only once the new
  # interpreter is published.
  defp booted?(dead) do
    case Process.whereis(Session) do
      nil -> false
      ^dead -> false
      pid -> GenServer.call(pid, :await_boot, 60_000) != nil
    end
  catch
    :exit, _ -> false
  end

  defp desktop_file do
    dir = Path.join(System.tmp_dir!(), "desktop-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:compos_core, :desktop_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:compos_core, :desktop_path, previous),
        else: Application.delete_env(:compos_core, :desktop_path)

      File.rm_rf(dir)
    end)

    path = Path.join(dir, "desktop.etf")
    Application.put_env(:compos_core, :desktop_path, path)
    path
  end

  test "a save writes the held globals while the Scheme world has not taken them back" do
    path = desktop_file()
    held = [[{:sym, "registers"}, [["a", "the held value"]]]]

    on_exit(fn ->
      :sys.replace_state(Desktop, fn state -> %{state | scheme_stale?: false} end)
    end)

    :sys.replace_state(Desktop, fn state ->
      %{state | globals: held, scheme_stale?: true}
    end)

    assert :ok = Desktop.save_now()

    assert %{globals: ^held} = path |> File.read!() |> :erlang.binary_to_term()
  end

  test "a save reads the Scheme world again once it holds the globals" do
    path = desktop_file()

    :sys.replace_state(Desktop, fn state ->
      %{state | globals: [[{:sym, "registers"}, [["a", "stale"]]]], scheme_stale?: false}
    end)

    assert :ok = Desktop.save_now()

    %{globals: globals} = path |> File.read!() |> :erlang.binary_to_term()
    keys = for [{:sym, key}, _value] <- globals, do: key
    assert "groups-v2" in keys
  end

  @tag timeout: 180_000
  test "the group records come back after the Session dies" do
    name = "restart-probe-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Session.eval(~s{(group-record-delete! "#{name}")})
    end)

    {:ok, _} = Session.eval(~s{(group-record-create! "#{name}")})
    assert group_record?(name)

    # the desktop reads the globals on every save, so this is where it takes
    # its copy of the record
    assert :ok = Desktop.save_now()

    session = Process.whereis(Session)
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000

    # Session.ready? reads the published handle, and that is still the dead
    # interpreter until the replacement finishes its own init. Wait for the
    # new process to answer instead.
    assert eventually(fn -> booted?(session) end)

    # the new interpreter starts with (defvar '*group-records* '())
    assert eventually(fn -> group_record?(name) end),
           "the desktop did not put the group records back into the new interpreter"
  end
end
