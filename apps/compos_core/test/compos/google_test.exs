defmodule Compos.GoogleTest do
  use ExUnit.Case, async: false
  alias Compos.Core.Google
  alias Compos.Core.Google.Store

  setup do
    unique = Integer.to_string(System.unique_integer([:positive]))
    path = Path.join(System.tmp_dir!(), "compos-google-client-#{unique}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "installed" => %{"client_id" => "test-client", "client_secret" => "test-secret"}
      })
    )

    on_exit(fn ->
      Application.delete_env(:compos_core, :google_http)
      File.rm(path)
      for id <- [unique, unique <> "b"], do: Store.delete(id)
    end)

    %{path: path, id: unique}
  end

  defp adapter(id, owner \\ self()) do
    Application.put_env(:compos_core, :google_http, fn opts ->
      send(owner, {:http, opts})

      cond do
        opts[:url] == "https://oauth2.googleapis.com/token" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "access_token" => "access-#{id}",
               "refresh_token" => "refresh-#{id}",
               "expires_in" => 3600,
               "scope" => "openid email scope-a"
             }
           }}

        opts[:url] == "https://openidconnect.googleapis.com/v1/userinfo" ->
          {:ok,
           %{
             status: 200,
             body: %{"sub" => id, "email" => "#{id}@example.com", "email_verified" => true}
           }}

        true ->
          {:ok, %{status: 200, body: %{"items" => []}}}
      end
    end)
  end

  defp connect(path) do
    %{"ok" => true, "url" => url} = Google.connect(path, ["scope-a"])
    URI.decode_query(URI.parse(url).query)
  end

  defp authorize(path, id) do
    adapter(id)
    query = connect(path)
    assert {200, _} = Google.callback(%{"state" => query["state"], "code" => "one-time-code"})
    query
  end

  test "account lookup uses the default app home when no override is configured" do
    home = Application.fetch_env!(:compos_core, :home)

    try do
      Application.delete_env(:compos_core, :home)

      assert {:error, message} =
               Store.read("missing-google-test-#{System.unique_integer([:positive])}")

      assert message =~ "Google account is unavailable"
    after
      Application.put_env(:compos_core, :home, home)
    end
  end

  test "PKCE, one-use state, loopback callback, and safe account metadata", %{path: path, id: id} do
    adapter(id)
    query = connect(path)
    assert query["code_challenge_method"] == "S256"
    assert byte_size(query["code_challenge"]) == 43
    assert query["access_type"] == "offline"
    assert query["redirect_uri"] =~ "http://127.0.0.1:"
    assert {400, _} = Google.callback(%{"state" => "wrong", "code" => "bad"})
    refute_received {:http, _}

    callback =
      query["redirect_uri"] <>
        "?" <> URI.encode_query(%{state: query["state"], code: "one-time-code"})

    assert {:ok, %{status: 200}} = Req.get(callback)
    assert_received {:http, opts}
    assert opts[:form][:code] == "one-time-code"
    verifier = opts[:form][:code_verifier]

    assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) ==
             query["code_challenge"]

    assert {400, _} = Google.callback(%{"state" => query["state"], "code" => "one-time-code"})
    account = Enum.find(Google.accounts(), &(&1["id"] == id))
    assert account["email"] == "#{id}@example.com"
    refute inspect(account) =~ "token"
    refute inspect(Google.status()) =~ "secret"
    assert Google.status()["state"] == "connected"
  end

  test "denial and expired flows never exchange a code", %{path: path} do
    query = connect(path)
    assert {400, _} = Google.callback(%{"state" => query["state"], "error" => "access_denied"})
    assert Google.status()["state"] == "denied"
    query = connect(path)

    :sys.replace_state(Google, fn state ->
      put_in(state.flow.deadline, System.monotonic_time(:second) - 1)
    end)

    assert {400, _} = Google.callback(%{"state" => query["state"], "code" => "expired"})
    assert Google.status()["state"] == "expired"
  end

  test "encrypted credentials survive process restart and remain account isolated", %{
    path: path,
    id: id
  } do
    authorize(path, id)
    authorize(path, id <> "b")
    assert :ok = Supervisor.terminate_child(Compos.Core.Supervisor, Google)
    assert {:ok, _} = Supervisor.restart_child(Compos.Core.Supervisor, Google)
    assert {:ok, first} = Store.read(id)
    assert first["access_token"] == "access-#{id}"
    assert {:ok, second} = Store.read(id <> "b")
    assert second["access_token"] == "access-#{id}b"
    root = Path.join(Application.fetch_env!(:compos_core, :home), "google")

    for file <- Path.wildcard(Path.join(root, "*.token")) do
      refute File.read!(file) =~ "refresh-"
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    end

    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
  end

  test "requests pin the account, reject foreign URLs, and never replay writes", %{
    path: path,
    id: id
  } do
    authorize(path, id)
    owner = self()

    Application.put_env(:compos_core, :google_http, fn opts ->
      send(owner, {:api, opts})
      {:ok, %{status: 500, body: "private-token-and-payload"}}
    end)

    assert %{"ok" => false} =
             Google.request(id, "GET", "https://googleapis.com.evil.test/data", [], nil)

    refute_received {:api, _}

    assert %{"ok" => false, "status" => 500} =
             result =
             Google.request(id, "POST", "https://docs.googleapis.com/v1/documents", [], %{
               "title" => "Test"
             })

    refute inspect(result) =~ "private"
    assert_received {:api, opts}
    assert opts[:headers] == [{"authorization", "Bearer access-#{id}"}]
    assert opts[:retry] == false
    assert opts[:redirect] == false
    refute_received {:api, _}
  end

  test "concurrent requests refresh once and use the refreshed account token", %{
    path: path,
    id: id
  } do
    authorize(path, id)
    {:ok, record} = Store.read(id)
    :ok = Store.write(id, Map.put(record, "expires_at", 0))
    owner = self()

    Application.put_env(:compos_core, :google_http, fn opts ->
      if opts[:url] == "https://oauth2.googleapis.com/token" do
        send(owner, :refresh)
        assert opts[:form][:refresh_token] == "refresh-#{id}"
        {:ok, %{status: 200, body: %{"access_token" => "renewed", "expires_in" => 3600}}}
      else
        assert opts[:headers] == [{"authorization", "Bearer renewed"}]
        {:ok, %{status: 200, body: %{}}}
      end
    end)

    tasks =
      for _ <- 1..4,
          do:
            Task.async(fn ->
              Google.request(id, "GET", "https://docs.googleapis.com/v1/documents/x", [], nil)
            end)

    assert Enum.all?(Task.await_many(tasks), & &1["ok"])
    assert_received :refresh
    refute_received :refresh
  end

  test "revocation failure keeps the account and success removes only that account", %{
    path: path,
    id: id
  } do
    authorize(path, id)
    authorize(path, id <> "b")
    Application.put_env(:compos_core, :google_http, fn _ -> {:error, :offline} end)
    assert %{"ok" => false} = Google.disconnect(id)
    assert {:ok, _} = Store.read(id)

    Application.put_env(:compos_core, :google_http, fn opts ->
      assert opts[:url] == "https://oauth2.googleapis.com/revoke"
      assert opts[:form][:token] == "refresh-#{id}"
      {:ok, %{status: 200, body: ""}}
    end)

    assert %{"ok" => true} = Google.disconnect(id)
    assert {:error, _} = Store.read(id)
    assert {:ok, _} = Store.read(id <> "b")
  end

  test "raw request JSON preserves empty objects, nulls and arrays", %{path: path, id: id} do
    authorize(path, id)

    Application.put_env(:compos_core, :google_http, fn opts ->
      assert opts[:json] == %{"object" => %{}, "array" => [], "null" => nil, "boolean" => false}
      {:ok, %{status: 200, body: %{}}}
    end)

    json =
      ~s|{"method":"POST","params":{},"body":{"object":{},"array":[],"null":null,"boolean":false}}|

    assert %{"ok" => true} =
             Google.request_json(id, "https://docs.googleapis.com/v1/documents", json)
  end
end
