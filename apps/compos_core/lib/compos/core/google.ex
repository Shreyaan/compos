defmodule Compos.Core.Google do
  @moduledoc """
  Native Google OAuth and authenticated HTTP transport.

  Scheme owns scopes, service paths, commands, and views. Tokens never cross
  the Scheme boundary. Each account is keyed by Google's verified subject.
  """
  use GenServer
  alias Compos.Core.Google.Store

  @authorize "https://accounts.google.com/o/oauth2/v2/auth"
  @token "https://oauth2.googleapis.com/token"
  @userinfo "https://openidconnect.googleapis.com/v1/userinfo"
  @revoke "https://oauth2.googleapis.com/revoke"
  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PATCH" => :patch,
    "PUT" => :put,
    "DELETE" => :delete
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def connect(client_file, scopes),
    do: GenServer.call(__MODULE__, {:connect, client_file, scopes})

  def status, do: GenServer.call(__MODULE__, :status)
  def callback(params), do: GenServer.call(__MODULE__, {:callback, params}, 90_000)
  def accounts, do: Store.accounts()

  def request_json(account, url, json) do
    case Jason.decode(json) do
      {:ok, %{"method" => method} = request} ->
        params = request["params"] || %{}

        if is_map(params) or is_list(params) do
          request(account, method, url, params, request["body"])
        else
          error("Request params must be a JSON object.")
        end

      _ ->
        error("Invalid Google request JSON.")
    end
  end

  def request(account, method, url, params, body) do
    with true <- allowed_url?(url),
         {:ok, verb} <- Map.fetch(@methods, method),
         {:ok, token} <- access_token(account) do
      opts = [
        method: verb,
        url: url,
        params: params,
        headers: [{"authorization", "Bearer " <> token}]
      ]

      opts = if body in [nil, false], do: opts, else: Keyword.put(opts, :json, body)

      case http(opts) do
        {:ok, %{status: status, body: value}} when status in 200..299 ->
          %{"ok" => true, "status" => status, "data" => value}

        {:ok, %{status: 401}} ->
          # Invalidate for the next explicit request. Never replay a mutation.
          lock(account, fn ->
            with {:ok, record} <- Store.read(account),
                 do: Store.write(account, Map.put(record, "expires_at", 0))
          end)

          error("Google rejected this session. Retry to refresh, or reconnect the account.", 401)

        {:ok, %{status: status}} ->
          error(api_error(status), status)

        _ ->
          error("Google could not be reached. Check the connection and retry.")
      end
    else
      false -> error("Only HTTPS Google API URLs are supported.")
      :error -> error("Unsupported HTTP method.")
      {:error, message} -> error(message)
    end
  rescue
    _ -> error("The Google request could not be completed.")
  end

  def disconnect(account) do
    lock(account, fn ->
      with {:ok, record} <- Store.read(account),
           {:ok, %{status: status}} when status in [200, 400] <-
             http(method: :post, url: @revoke, form: [token: record["refresh_token"]]) do
        Store.delete(account)
        %{"ok" => true}
      else
        _ -> error("Could not revoke Google access. The connection was kept so you can retry.")
      end
    end)
  end

  def allowed_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443, fragment: nil}
      when is_binary(host) ->
        host == "www.googleapis.com" or String.ends_with?(host, ".googleapis.com")

      _ ->
        false
    end
  end

  def allowed_url?(_), do: false

  @impl true
  def init(_), do: {:ok, %{flow: nil, listener: nil, status: %{"state" => "idle"}}}

  @impl true
  def handle_call(:status, _, state), do: {:reply, state.status, state}

  def handle_call({:connect, path, scopes}, _, state) do
    with {:ok, %{"installed" => %{"client_id" => client_id} = client}} <- read_client(path),
         true <- is_binary(client_id) and is_list(scopes) and Enum.all?(scopes, &is_binary/1) do
      stop_listener(state.listener)

      case Bandit.start_link(
             plug: __MODULE__.Callback,
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false,
             http_options: [log_protocol_errors: false]
           ) do
        {:ok, listener} ->
          Process.unlink(listener)
          {:ok, {_, port}} = ThousandIsland.listener_info(listener)
          nonce = random()
          verifier = random()
          redirect = "http://127.0.0.1:#{port}/oauth2/callback"
          scopes = Enum.uniq(["openid", "email" | scopes])

          flow = %{
            nonce: nonce,
            verifier: verifier,
            client: client,
            redirect: redirect,
            scopes: scopes,
            deadline: System.monotonic_time(:second) + 600
          }

          url =
            @authorize <>
              "?" <>
              URI.encode_query(%{
                "client_id" => client_id,
                "redirect_uri" => redirect,
                "response_type" => "code",
                "scope" => Enum.join(scopes, " "),
                "state" => nonce,
                "access_type" => "offline",
                "prompt" => "consent select_account",
                "code_challenge_method" => "S256",
                "code_challenge" =>
                  Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
              })

          Process.send_after(self(), {:expire, nonce}, 600_000)

          {:reply, %{"ok" => true, "url" => url},
           %{state | flow: flow, listener: listener, status: %{"state" => "waiting"}}}

        _ ->
          {:reply, error("Could not start the localhost OAuth callback."),
           %{state | flow: nil, listener: nil}}
      end
    else
      _ -> {:reply, error("Choose a Google Desktop OAuth client JSON file."), state}
    end
  end

  def handle_call({:callback, params}, _, state) do
    flow = state.flow

    cond do
      is_nil(flow) ->
        {:reply, {400, "No pending connection."}, state}

      System.monotonic_time(:second) > flow.deadline ->
        {:reply, {400, "Connection expired. Start again in compos."}, finish(state, "expired")}

      not secure_equal?(params["state"], flow.nonce) ->
        {:reply, {400, "Invalid OAuth state."}, state}

      params["error"] ->
        {:reply, {400, "Google access was declined. Return to compos."}, finish(state, "denied")}

      not is_binary(params["code"]) ->
        {:reply, {400, "Missing authorization code."}, finish(state, "failed")}

      true ->
        case exchange(flow, params["code"]) do
          {:ok, account} ->
            next = finish(state, "connected")

            {:reply, {200, "Google is connected. Return to compos and open M-x google."},
             %{next | status: Map.put(next.status, "account", account)}}

          {:error, _} ->
            {:reply,
             {400, "Google connection failed. Check client configuration and retry in compos."},
             finish(state, "failed")}
        end
    end
  end

  @impl true
  def handle_info({:expire, nonce}, %{flow: %{nonce: nonce}} = state),
    do: {:noreply, finish(state, "expired")}

  def handle_info({:stop_listener, pid}, state) do
    stop_listener(pid)
    {:noreply, if(state.listener == pid, do: %{state | listener: nil}, else: state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_listener(state.listener)

  defp finish(state, status) do
    # Let the callback response leave the socket before closing its listener.
    if state.listener, do: Process.send_after(self(), {:stop_listener, state.listener}, 1000)
    %{state | flow: nil, status: %{"state" => status}}
  end

  defp stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp stop_listener(_), do: :ok

  defp read_client(client) when is_map(client), do: {:ok, client}

  defp read_client(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)), do: Jason.decode(bytes)
  end

  defp read_client(_), do: {:error, :invalid_client}

  defp exchange(flow, code) do
    form = [
      grant_type: "authorization_code",
      code: code,
      client_id: flow.client["client_id"],
      code_verifier: flow.verifier,
      redirect_uri: flow.redirect
    ]

    form = client_secret(form, flow.client)

    with {:ok, %{status: 200, body: %{"access_token" => access} = token}} <-
           http(method: :post, url: @token, form: form),
         {:ok, %{status: 200, body: %{"sub" => id, "email" => email, "email_verified" => true}}} <-
           http(method: :get, url: @userinfo, headers: [{"authorization", "Bearer " <> access}]),
         true <- is_binary(id) and is_binary(email) do
      lock(id, fn ->
        old =
          case Store.read(id) do
            {:ok, record} -> record
            _ -> %{}
          end

        refresh =
          token["refresh_token"] || if(old["client"] == flow.client, do: old["refresh_token"])

        if is_binary(refresh) do
          record = %{
            "id" => id,
            "email" => email,
            "client" => flow.client,
            "refresh_token" => refresh,
            "access_token" => access,
            "expires_at" => System.os_time(:second) + token["expires_in"],
            "scopes" => String.split(token["scope"] || Enum.join(flow.scopes, " "))
          }

          case Store.write(id, record) do
            :ok -> {:ok, id}
            _ -> {:error, "Token storage failed."}
          end
        else
          {:error, "Google did not issue offline access. Reconnect with consent."}
        end
      end)
    else
      _ -> {:error, "OAuth exchange failed."}
    end
  rescue
    _ -> {:error, "OAuth exchange failed."}
  end

  defp access_token(account) do
    lock(account, fn ->
      with {:ok, record} <- Store.read(account) do
        if record["expires_at"] > System.os_time(:second) + 60 do
          {:ok, record["access_token"]}
        else
          form =
            client_secret(
              [
                grant_type: "refresh_token",
                refresh_token: record["refresh_token"],
                client_id: record["client"]["client_id"]
              ],
              record["client"]
            )

          case http(method: :post, url: @token, form: form) do
            {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => ttl} = body}} ->
              updated =
                Map.merge(record, %{
                  "access_token" => token,
                  "refresh_token" => body["refresh_token"] || record["refresh_token"],
                  "expires_at" => System.os_time(:second) + ttl
                })

              case Store.write(account, updated) do
                :ok -> {:ok, token}
                _ -> {:error, "Token storage failed."}
              end

            {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
              {:error, "Google access expired or was revoked. Reconnect this account."}

            _ ->
              {:error, "Could not refresh Google access. Retry or reconnect this account."}
          end
        end
      end
    end)
  end

  defp client_secret(form, %{"client_secret" => secret}),
    do: Keyword.put(form, :client_secret, secret)

  defp client_secret(form, _), do: form
  defp lock(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp secure_equal?(a, b) when is_binary(a) and byte_size(a) == byte_size(b),
    do: Plug.Crypto.secure_compare(a, b)

  defp secure_equal?(_, _), do: false
  defp error(message, status \\ 0), do: %{"ok" => false, "error" => message, "status" => status}

  defp api_error(403),
    do: "Google denied access. Check granted scopes, enabled APIs, and Workspace policy."

  defp api_error(404), do: "Google could not find this item for the selected account."
  defp api_error(429), do: "Google rate limit reached. Wait before retrying."
  defp api_error(412), do: "The remote item changed. Refresh it before applying your edit."
  defp api_error(n), do: "Google API request failed (HTTP #{n})."

  defp http(opts) do
    # No redirects, implicit retries, or request logging with bearer credentials.
    defaults = [
      retry: false,
      redirect: false,
      receive_timeout: 30_000,
      connect_options: [timeout: 10_000]
    ]

    opts = Keyword.merge(defaults, opts)

    case Application.get_env(:compos_core, :google_http) do
      nil -> Req.request(opts)
      adapter -> adapter.(opts)
    end
  rescue
    _ -> {:error, :transport}
  end

  defmodule Callback do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn
    def init(opts), do: opts

    def call(%{method: "GET", request_path: "/oauth2/callback"} = conn, _) do
      conn = fetch_query_params(conn)
      {status, body} = Compos.Core.Google.callback(conn.query_params)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_content_type("text/plain")
      |> send_resp(status, body)
    end

    def call(conn, _), do: send_resp(conn, 404, "Not found")
  end
end
