defmodule Compos.Ui.Representation do
  @moduledoc """
  Select a view representation without hiding render failures.

  A ComposML-capable view exports `composml/1`. Existing views can retain
  `render/1`. The result reports the actual format, including HTML fallback.
  `live/2` keeps the tracked Phoenix value intact for normal LiveView patches.
  This is render dispatch, not an XML-over-HTTP endpoint.
  """

  def render(view, assigns, requested \\ :composml) when requested in [:composml, :html] do
    Code.ensure_loaded!(view)

    {format, callback} =
      cond do
        requested == :composml and function_exported?(view, :composml, 1) ->
          {:composml, :composml}

        function_exported?(view, :html, 1) ->
          {:html, :html}

        function_exported?(view, :composml, 1) ->
          {:composml, :composml}

        true ->
          {:html, :render}
      end

    %{format: format, content: apply(view, callback, [assigns])}
  end

  def live(view, assigns), do: render(view, assigns).content
end
