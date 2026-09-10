defmodule Compos.Ui.ComposMLTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Compos.Ui.Representation

  defmodule View do
    use Phoenix.Component
    import Compos.Ui.ComposML

    def composml(assigns) do
      ~M"""
      <c-frame id="frame">
        <c-window :for={item <- @items} id={item.id} active={to_string(item.active)}>
          <c-modeline><c-text face="dim">{item.text}</c-text></c-modeline>
          <button :if={item.active} phx-click="choose" phx-value-id={item.id}>Choose</button>
        </c-window>
      </c-frame>
      """
    end

    def render(assigns), do: html(assigns)
    def html(assigns), do: ~H"<p>{@text}</p>"
    def failure(_assigns), do: raise("render failed")
  end

  defmodule Legacy do
    def render(assigns), do: {:legacy, assigns}
  end

  defmodule SemanticOnly do
    def composml(assigns), do: {:semantic, assigns}
    def render(assigns), do: Representation.live(__MODULE__, assigns)
  end

  test "HTML preference reports the actual format for migrated views" do
    assert %{format: :composml, content: {:semantic, %{}}} =
             Representation.render(SemanticOnly, %{}, :html)
  end

  defmodule Broken do
    def composml(_assigns), do: raise("broken composml")
    def render(_assigns), do: :must_not_fallback
  end

  test "format dispatch selects ComposML and preserves the tracked render value" do
    assigns = %{__changed__: nil, items: []}

    assert %{format: :composml, content: %Phoenix.LiveView.Rendered{}} =
             Representation.render(View, assigns)

    assert %{format: :html, content: %Phoenix.LiveView.Rendered{}} =
             Representation.render(View, %{__changed__: nil, text: "legacy"}, :html)
  end

  test "missing ComposML falls back honestly to the existing renderer" do
    assert %{format: :html, content: {:legacy, %{value: 42}}} =
             Representation.render(Legacy, %{value: 42})
  end

  test "a failed ComposML renderer does not silently fall back" do
    assert_raise RuntimeError, "broken composml", fn -> Representation.render(Broken, %{}) end
  end

  test "semantic names, loops, conditionals, events, and escaping survive rendering" do
    html =
      render_component(&View.composml/1,
        items: [
          %{id: "a", active: true, text: "<script>&"},
          %{id: "b", active: false, text: "second"}
        ]
      )

    assert html =~ ~s(<c-frame id="frame">)
    assert html =~ ~s(<c-window id="a" active="true">)
    assert html =~ ~s(<c-text face="dim">&lt;script&gt;&amp;</c-text>)
    assert html =~ ~s(phx-click="choose" phx-value-id="a")
    refute html =~ ~s(phx-value-id="b")
    assert html =~ "second"
  end

  test "mismatched semantic tags, unknown core tags, and generic containers fail compilation" do
    for {body, expected} <- [
          {"<c-frame></c-window>", "unmatched closing tag"},
          {"<c-nonesuch />", "unknown ComposML"},
          {"<div />", "use a semantic ComposML"}
        ] do
      source = """
      defmodule BadComposML#{System.unique_integer([:positive])} do
        use Phoenix.Component
        import Compos.Ui.ComposML
        def render(assigns), do: ~M"#{body}"
      end
      """

      error =
        assert_raise Phoenix.LiveView.TagEngine.Tokenizer.ParseError, fn ->
          Code.compile_string(source)
        end

      assert Exception.message(error) =~ expected
    end
  end

  test "all first-party LiveViews advertise a ComposML renderer" do
    for view <- [
          Compos.Ui.EditorLive,
          Compos.Ui.MobileLive,
          Compos.Ui.HomepageLive,
          Compos.Ui.Window,
          Compos.Ui.AgentTranscript
        ] do
      Code.ensure_loaded!(view)
      assert function_exported?(view, :composml, 1)
    end
  end

  test "the browser can load the semantic elements' base stylesheet" do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      Compos.Ui.Endpoint.call(
        %{conn | request_path: "/composml.css", path_info: ["composml.css"]},
        []
      )

    assert conn.status == 200
    assert conn.resp_body =~ "c-modeline"
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/css"
  end
end
