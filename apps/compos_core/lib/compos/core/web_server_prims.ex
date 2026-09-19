defmodule Compos.Core.WebServer.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.Session

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- Inbound HTTP servers (Bandit mechanism; Scheme handlers) -------
      {"web-server-start!",
       "(web-server-start! NAME SPEC HANDLER) — start an HTTP callback or webhook server; HANDLER receives a request plist and returns a response plist."} =>
        fn [name, spec, handler] ->
          case Compos.Core.WebServer.start(s(name), plist_to_map(spec), handler) do
            {:ok, detail} -> web_server_detail(detail)
            {:error, msg} -> raise_scheme("web-server-start!: #{msg}")
          end
        end,
      {"web-server-stop!", "(web-server-stop! NAME) — stop the named HTTP server."} => fn [name] ->
        Compos.Core.WebServer.stop(s(name))
        :void
      end,
      # MCP-shaped JSON for a list of registry tool specs — the proxy's
      # tools/list payload (input_schema key renamed to MCP's camelCase)
      {"tool-specs-json",
       "(tool-specs-json SPECS) — return the specs as MCP tools/list JSON text."} => fn [specs] ->
        specs
        |> Enum.map(fn spec ->
          %{input_schema: schema} = t = Compos.Core.LLM.tool_json(spec)

          t
          |> Map.delete(:input_schema)
          |> Map.put(:inputSchema, schema)
          |> Map.put(:annotations, Compos.Core.LLM.tool_annotations(spec))
        end)
        |> Jason.encode!()
      end,
      # canonical: the build dir holds a symlink to the checkout's priv, and
      # a path that names the source file is the one a reader can open,
      # reload, and diff. A release has no link, so the path is unchanged.
      {"priv-path",
       "(priv-path REL) — return the absolute path of REL in the compos_core priv directory."} =>
        fn [rel] ->
          Session.canonical(Path.join(Application.app_dir(:compos_core, "priv"), rel))
        end
    }
  end

  defp web_server_detail(detail) do
    [
      {:sym, "name"},
      detail.name,
      {:sym, "host"},
      detail.host,
      {:sym, "port"},
      detail.port,
      {:sym, "url"},
      detail.url,
      {:sym, "max-body"},
      detail.max_body
    ]
  end
end
