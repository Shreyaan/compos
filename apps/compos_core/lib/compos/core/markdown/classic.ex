defmodule Compos.Core.Markdown.Classic do
  @moduledoc """
  The Markdown page drawn by Earmark, for a home with no Markdown grammar.

  The grammar is not compiled into the NIF: a reader installs it with
  `M-x ts-install-grammar markdown`. Until then every preview and every
  chat paragraph draws through this module, so it stays. Where the grammar
  is present, `Compos.Core.Markdown.Html` draws the page and this module
  only lends it the overlay positions and the YouTube card.

  Earmark knows no source offsets, so the caret and the line anchors ride
  through the parse as private-use sentinels, and the rules below keep a
  sentinel from breaking the construct it lands in.
  """

  alias Compos.Core.Markdown.Html
  alias Compos.Scheme.Text

  # The cursor in a markdown preview: a private-use sentinel goes into the
  # source at POINT, rides through Earmark as plain text, and comes out as
  # the .pt span. If point sits inside markdown syntax the one construct
  # can render off for a moment; the sandbox runs no scripts, so a mangled
  # span is a display blemish and nothing more.
  @pt_sentinel "\uE000"

  # one marker per source line that draws text; it becomes a .ln span that
  # names the line's byte offset, so a key in the page can say which source
  # line the reader moved to
  @anchor "\uE005"
  @llm_start "\uE002"
  @llm_end "\uE003"
  @llm_meta_end "\uE004"
  @csv_preview_lines 5

  @doc """
  The page for TEXT of render mode RM drawn by Earmark, with the caret at
  POINT and the mark at MARK. `html` pages go to `Html.html_document/3`.
  OPTS: `base_dir`, `csv_source`, `local_url` (a path to a URL the page
  can load) and `tweet_card` (a URL to `{:ok, html} | :pending | :error`).
  """
  def preview_doc(rm, text, point, faces, authored),
    do: preview_doc(rm, text, point, nil, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored),
    do: preview_doc(rm, text, point, mark, faces, authored, [])

  def preview_doc("markdown", text, point, mark, faces, authored, overlays) do
    preview_doc("markdown", text, point, mark, faces, authored, overlays, [])
  end

  def preview_doc(rm, text, _point, _mark, faces, authored, _overlays),
    do: preview_html(rm, text, faces, authored)

  def preview_doc("markdown", text, point, mark, faces, authored, overlays, opts) do
    p = point |> max(0) |> min(byte_size(text))
    m = if is_integer(mark), do: mark |> max(0) |> min(byte_size(text)), else: nil

    blank = blank_point_line(text, p, overlays)
    anchors = line_anchors(text, blank)
    marked = mark_preview_positions(text, p, m, overlays, anchors, blank)

    "markdown"
    |> preview_html(marked, faces, authored, opts)
    |> place_anchors(anchors)
  end

  def preview_doc(rm, text, _point, _mark, faces, authored, _overlays, _opts),
    do: preview_html(rm, text, faces, authored)

  defp mark_preview_positions(text, point, mark, overlays, anchors, blank) do
    positions =
      point_position(text, point, blank) ++
        mark_position(text, mark) ++
        Enum.map(overlay_positions(text, overlays), fn {at, s} -> {at, 2, s} end) ++
        (anchors |> Enum.reject(&(&1 == blank)) |> Enum.map(&{&1, 1, @anchor}))

    positions =
      positions
      |> Enum.reject(fn {at, _rank, _s} -> is_nil(at) end)
      # a sentinel inside a character makes the document invalid UTF-8, and
      # the Markdown parser then raises on the whole page
      |> Enum.map(fn {at, rank, s} -> {Text.floor_utf8(text, at), rank, s} end)
      # Later insertions at one offset land BEFORE earlier ones, so the rank
      # here is the reverse of the order in the page: a quote marker the
      # overlay adds keeps the start of its line, the line's anchor sits
      # after it, and the cursor stays innermost, right at point.
      |> Enum.sort_by(fn {at, rank, _s} -> {-at, rank} end)

    Enum.reduce(positions, text, fn {at, _rank, s}, acc ->
      binary_part(acc, 0, at) <> s <> binary_part(acc, at, byte_size(acc) - at)
    end)
  end

  # The point's own blank line draws an empty paragraph, and that paragraph
  # needs a blank line on each side or it joins the block above or below. The
  # anchor rides inside it, so the client still reads the source line the
  # caret stands on.
  defp point_position(_text, _point, ls) when is_integer(ls),
    do: [{ls, 0, "\n" <> @anchor <> @pt_sentinel <> "\n"}]

  defp point_position(text, point, nil), do: [{cursor_spot(text, point), 0, @pt_sentinel}]

  defp mark_position(_text, nil), do: []
  defp mark_position(text, mark), do: [{cursor_spot(text, mark), 0, "\uE001"}]

  # A blank line has no Markdown node, so a cursor on it has nowhere to draw.
  # The old answer moved the cursor to the next line that draws text. The
  # caret then stood in front of another block's words while every keystroke
  # went to the blank line: RET at the end of a document looked like it did
  # nothing, and RET above a table threw the caret into the first cell. Give
  # the line its own empty paragraph instead. An llm overlay quotes the lines
  # it covers, so leave those to it.
  defp blank_point_line(text, p, overlays) do
    ls = line_start(text, p)

    if blank_line?(text, ls) and not overlaid?(overlays, ls), do: ls, else: nil
  end

  # A blank line inside a fence is literal text. It draws, so it is not blank
  # for this purpose.
  defp blank_line?(text, ls),
    do: text |> line_at(ls) |> String.trim() == "" and not inside_fence?(text, ls)

  defp overlaid?(overlays, ls) do
    Enum.any?(overlays || [], fn
      {start, finish, _face} when is_integer(start) and is_integer(finish) ->
        ls >= start and ls <= finish

      _ ->
        false
    end)
  end

  # Preview formatting belongs to llm-mode, not to the Markdown document.
  # Render its response overlay through a temporary blockquote so Earmark can
  # still parse headings, lists, and emphasis inside the answer. The private
  # sentinels let us distinguish this from a blockquote the author typed.
  def overlay_positions(text, overlays) do
    Enum.flat_map(overlays || [], fn
      {start, finish, face}
      when is_integer(start) and is_integer(finish) and face in ["llm-response", :llm_response] ->
        start = start |> max(0) |> min(byte_size(text))
        finish = finish |> max(start) |> min(byte_size(text))

        continuation_prefixes =
          text
          |> binary_part(start, finish - start)
          |> :binary.matches("\n")
          |> Enum.map(fn {offset, _length} -> {start + offset + 1, "> "} end)

        metadata = "#{start}:#{finish}"

        [
          {start, "> " <> @llm_start <> metadata <> @llm_meta_end},
          {finish, @llm_end} | continuation_prefixes
        ]

      _ ->
        []
    end)
  end

  # A rendered row belongs to a source line, and the page is the only place
  # that knows which rows exist: a wrapped paragraph is many rows, a fence
  # line is none. So mark every source line that draws text, at the spot the
  # cursor would take on it. The client reads the nearest marker above the
  # row it moved to, and point follows the source.
  defp line_anchors(text, blank) do
    text
    |> line_starts()
    |> Enum.map(fn ls -> {ls, line_anchor_spot(text, ls, blank)} end)
    |> Enum.filter(fn {ls, spot} -> spot != nil and line_start(text, spot) == ls end)
    |> Enum.map(&elem(&1, 1))
  end

  # The point's blank line draws its own paragraph, so it anchors to itself.
  # Every other blank line draws nothing, and an anchor there would join the
  # line to the block above and end it.
  defp line_anchor_spot(_text, ls, ls), do: ls

  defp line_anchor_spot(text, ls, _blank) do
    if blank_line?(text, ls), do: nil, else: cursor_spot(text, ls)
  end

  defp line_starts(text) do
    [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
    |> Enum.reject(&(&1 > byte_size(text)))
  end

  # The markers come back in source order, so the Nth marker in the page is
  # the Nth anchored line. A parser that drops one would shift every offset
  # after it, so a count that does not match gives up and leaves the page
  # without anchors: the fragment mapping still works.
  defp place_anchors(html, anchors) do
    if length(:binary.matches(html, @anchor)) == length(anchors) do
      html |> String.split(@anchor) |> weave_anchors(anchors)
    else
      String.replace(html, @anchor, "")
    end
  end

  defp weave_anchors([head | parts], anchors) do
    Enum.zip(parts, anchors)
    |> Enum.reduce(head, fn {part, at}, acc ->
      acc <> ~s(<span class="ln" data-p="#{at}"></span>) <> part
    end)
  end

  # Point often sits inside a line's BLOCK marker — byte 0 of "# Title" is
  # where a freshly opened file rests — and a sentinel inside the marker
  # un-headings the line. Snap the cursor to the marker's end.
  #
  # Some lines draw no text of their own: a fence, a rule, a Setext
  # underline, a table's alignment row, an empty line. A sentinel there
  # breaks the block it belongs to, and hiding the cursor loses point. So
  # the cursor moves to the nearest line that DOES draw text — the code
  # inside the fence, the heading above the underline, the first row of the
  # table. The depth guard stops a run of such lines from looping.
  defp cursor_spot(text, p), do: cursor_spot(text, p, 0)

  defp cursor_spot(_text, _p, depth) when depth > 4, do: nil

  defp cursor_spot(text, p, depth) do
    ls = line_start(text, p)
    line = line_at(text, ls)
    trimmed = String.trim_leading(line)
    below = ls + byte_size(line) + 1
    above = ls - 1

    cond do
      # The opening fence draws the block's head, the closing fence draws
      # nothing: put the cursor at the near end of the code itself.
      String.starts_with?(trimmed, "```") ->
        if fence_opens?(text, ls),
          do: spot_below(text, below, p, depth),
          else: spot_above(text, above, p, depth)

      # Inside a fenced block every character is literal, so a sentinel is
      # safe wherever point stands.
      inside_fence?(text, ls) ->
        p

      # An empty line has no Markdown node of its own. Keep it attached to
      # the nearest rendered node so the sentinel cannot turn a blank line
      # into a paragraph and break tables or adjacent blocks.
      String.trim(trimmed) == "" ->
        spot_below(text, below, p, depth)

      # The underline belongs to the heading above it.
      setext_underline?(text, ls, trimmed) ->
        spot_above(text, above, p, depth)

      rule_line?(trimmed) ->
        spot_below(text, below, p, depth)

      # The alignment row makes the table a table, and it draws nothing.
      table_delimiter_row?(trimmed) ->
        spot_below(text, below, p, depth)

      table_row?(trimmed) ->
        line |> table_row_spot(ls, p) |> link_target_spot(line, ls)

      true ->
        p |> marker_spot(line, ls) |> link_target_spot(line, ls)
    end
  end

  defp spot_below(text, below, _p, depth) when below <= byte_size(text),
    do: cursor_spot(text, below, depth + 1)

  defp spot_below(_text, _below, p, _depth), do: p

  defp spot_above(text, above, _p, depth) when above >= 0,
    do: cursor_spot(text, above, depth + 1)

  defp spot_above(_text, _above, p, _depth), do: p

  defp line_start(text, p) do
    case :binary.matches(binary_part(text, 0, p), "\n") do
      [] -> 0
      ms -> ms |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end

  defp line_at(text, ls),
    do: text |> binary_part(ls, byte_size(text) - ls) |> String.split("\n", parts: 2) |> hd()

  # A fence line opens a block when an even number of fences stands above it.
  defp fence_opens?(text, ls), do: rem(fences_above(text, ls), 2) == 0

  defp inside_fence?(text, ls), do: rem(fences_above(text, ls), 2) == 1

  defp fences_above(text, ls) do
    text
    |> binary_part(0, ls)
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(String.trim_leading(&1), "```"))
  end

  # `===` under text is a heading. The same run under a blank line is a rule.
  defp setext_underline?(text, ls, trimmed) do
    Regex.match?(~r/^[=-]+[ \t]*$/, trimmed) and ls > 0 and
      text |> line_at(line_start(text, ls - 1)) |> String.trim() != ""
  end

  defp rule_line?(trimmed),
    do: Regex.match?(~r/^([-*_])[ \t]*(\1[ \t]*){2,}$/, trimmed)

  defp marker_spot(p, line, ls) do
    case Regex.run(~r/^(?:\s{0,3}(?:\#{1,6}|[-*+]|\d+\.|>)\s+)+/, line, return: :index) do
      [{0, len}] when p < ls + len -> ls + len
      _ -> p
    end
  end

  # A link target renders as an attribute, not as text, so a cursor inside
  # it never draws. Keep it at the end of the label the reader can see.
  defp link_target_spot(nil, _line, _ls), do: nil

  defp link_target_spot(p, line, ls) do
    Regex.scan(~r/\]\([^)]*\)/, line, return: :index)
    |> List.flatten()
    |> Enum.reduce(p, fn {at, len}, acc ->
      if acc > ls + at and acc < ls + at + len, do: ls + at, else: acc
    end)
  end

  # A row stays a table row only while its pipes stand at the line edges.
  # Point rests at column 0 after every vertical move, and a sentinel there
  # ends the table at that row: everything below it falls back to raw text.
  # So keep the cursor inside the first and the last cell.
  defp table_row_spot(line, ls, p) do
    first =
      case Regex.run(~r/^\s*\|[ \t]*/, line, return: :index) do
        [{0, len}] -> len
        _ -> 0
      end

    last =
      case Regex.run(~r/[ \t]*\|[ \t]*$/, line, return: :index) do
        [{at, _}] -> at
        _ -> byte_size(line)
      end

    cond do
      first >= last -> nil
      p < ls + first -> ls + first
      p > ls + last -> ls + last
      true -> p
    end
  end

  defp table_row?(trimmed) do
    String.starts_with?(trimmed, "|") and length(:binary.matches(trimmed, "|")) >= 2
  end

  defp table_delimiter_row?(trimmed) do
    String.contains?(trimmed, "-") and Regex.match?(~r/^\|[\s:|-]*$/, trimmed)
  end

  defp preview_html("html", text, faces, authored), do: Html.html_document(text, faces, authored)

  defp preview_html("markdown", text, faces, _authored),
    do: Html.page(earmark_body(text), faces)

  defp preview_html("markdown", text, faces, _authored, opts),
    do: Html.page(earmark_body(text, opts), faces)

  defp earmark_body(text, opts \\ []) do
    fence_labels = markdown_fence_labels(text)
    ctx = opts

    case earmark_ast(markdown_preview_source(text)) do
      {:ok, ast} ->
        ast
        |> label_code_blocks(fence_labels)
        |> tag_llm_responses()
        |> embed_urls(ctx)
        |> Earmark.Transform.transform(compact_output: false)
        |> String.replace(@pt_sentinel, ~s(<span class="pt"></span>))
        |> String.replace("\uE001", ~s(<span class="mk"></span>))

      {:error, why} ->
        unparsed_body(text, why)
    end
  end

  # Earmark raises on some documents instead of answering {:error, ast, _}.
  # An inline `{...}` reads as an attribute list, and one the parser cannot
  # make sense of is a FunctionClauseError deep inside it. The raise reaches
  # the LiveView, which dies, remounts, draws the same buffer and dies again:
  # one document takes the whole client down, and the page never comes back.
  #
  # A parser that cannot read a document must say so and draw the source.
  # The preview shows the document the author typed. A newline the author put
  # inside a paragraph is a line the reader must see, so a soft break draws as
  # a line break. Markdown joins those lines into one paragraph, which
  # reflowed the text and moved every line away from its source.
  defp earmark_ast(src) do
    case Earmark.as_ast(src, compact_output: false, breaks: true) do
      {:ok, ast, _} -> {:ok, ast}
      {:error, ast, _} -> {:ok, ast}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The document as it stands, plus what stopped the renderer. The reader
  # keeps their text and learns why it is not a page.
  defp unparsed_body(text, why) do
    ~s(<div class="preview-error"><strong>This page did not render.</strong> ) <>
      html_escape(why) <>
      ~s(</div><pre class="preview-raw">) <> html_escape(text) <> ~s(</pre>)
  end

  @doc false
  def html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Morg adds Org-style header arguments after a fenced block's language.
  # Earmark accepts one language token only. It otherwise renders the whole
  # fence as inline code. Keep the arguments in the buffer, but hide them
  # from the preview parser so the body remains a real code block.
  defp markdown_preview_source(text) do
    text
    |> then(fn source ->
      Regex.replace(
        ~r/^([ \t]*```[ \t]*[A-Za-z0-9_+.-]+)[ \t]+(?=:[A-Za-z])[^\r\n]*$/m,
        source,
        "\\1"
      )
    end)
    |> recover_unmatched_inline_backticks()
  end

  # Earmark keeps an unmatched inline backtick open until the end of the
  # document. Escape an unmatched delimiter so later blocks still parse.
  # Fenced code blocks keep their backticks because they define structure.
  defp recover_unmatched_inline_backticks(text) do
    {parts, segment, _fenced?} =
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.reduce({[], "", false}, fn {raw_line, index}, {parts, segment, fenced?} ->
        line = if index == 0, do: raw_line, else: "\n" <> raw_line

        if Regex.match?(~r/^\s*```/, raw_line) do
          # parts is reversed at the end, so the fence line goes in FIRST and
          # the text it closes goes in after it. The other order rebuilt the
          # document with every fence line ahead of the text above it: the
          # first fence landed on the first heading, and the whole page
          # rendered as the code that fence opened.
          {[line, recover_inline_backticks(segment) | parts], "", not fenced?}
        else
          if fenced?,
            do: {[line | parts], segment, fenced?},
            else: {parts, segment <> line, fenced?}
        end
      end)

    Enum.reverse([recover_inline_backticks(segment) | parts]) |> IO.iodata_to_binary()
  end

  defp recover_inline_backticks(segment) do
    delimiters = Regex.scan(~r/(?<!`)`(?!`)/, segment)

    if rem(length(delimiters), 2) == 1 do
      Regex.replace(~r/(?<!`)`(?!`)/, segment, fn _ -> "\\`" end)
    else
      segment
    end
  end

  defp markdown_fence_labels(text) do
    Regex.scan(
      ~r/^[ \t]*```[ \t]*([A-Za-z0-9_+.-]+)([^\r\n]*)$/m,
      text,
      capture: :all_but_first
    )
    |> Enum.map(fn [language, arguments] ->
      tangle =
        case Regex.run(~r/:tangle[ \t]+([^ \t]+)/i, arguments, capture: :all_but_first) do
          [target] -> if(String.downcase(target) == "no", do: nil, else: target)
          _ -> nil
        end

      lines =
        case Regex.run(~r/:(?:lines|preview)[ \t]+([0-9]+)/i, arguments, capture: :all_but_first) do
          [count] ->
            case Integer.parse(count) do
              {value, ""} when value > 0 -> value
              _ -> @csv_preview_lines
            end

          _ ->
            @csv_preview_lines
        end

      %{
        language: language,
        morg?: Regex.match?(~r/(^|\s):[A-Za-z]/, arguments),
        tangle: tangle,
        lines: lines
      }
    end)
  end

  defp label_code_blocks(nodes, labels) when is_list(nodes) do
    {nodes, _labels} = Enum.map_reduce(nodes, labels, &label_code_block/2)
    nodes
  end

  defp label_code_block(
         {"pre", _, [{"code", code_attrs, _, _}], _} = pre,
         [%{language: language} = label | labels]
       ) do
    case List.keyfind(code_attrs, "class", 0) do
      {"class", ^language} -> {code_block(pre, label), labels}
      _ -> {pre, [label | labels]}
    end
  end

  defp label_code_block({tag, attrs, children, meta}, labels) when is_list(children) do
    {children, labels} = Enum.map_reduce(children, labels, &label_code_block/2)
    {{tag, attrs, children, meta}, labels}
  end

  defp label_code_block(other, labels), do: {other, labels}

  defp code_block(pre, label) do
    actions =
      if label.morg? do
        run =
          if String.downcase(label.language) in ~w(scheme sh bash zsh shell python py elixir exs js javascript node ruby) do
            [{"span", [{"class", "code-action"}], [{"kbd", [], ["C-c C-c"], %{}}, " run"], %{}}]
          else
            []
          end

        tangle =
          if label.tangle do
            [
              {"span", [{"class", "code-action"}],
               [
                 {"kbd", [], ["C-c C-x"], %{}},
                 " tangle → ",
                 {"code", [], [label.tangle], %{}}
               ], %{}}
            ]
          else
            []
          end

        run ++ tangle
      else
        []
      end

    header =
      {"div", [{"class", "code-block-head"}, {"data-chrome", "1"}],
       [{"span", [{"class", "code-lang"}], [label.language], %{}} | actions], %{}}

    content =
      if String.downcase(label.language) == "result-csv" do
        csv_preview(pre, label.lines, nil)
      else
        pre
      end

    {"div", [{"class", "code-block"}], [header, content], %{}}
  end

  defp csv_preview({"pre", _, [{"code", _, children, _}], _} = pre, limit, source) do
    rows =
      (source || code_text(children))
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.take(limit)
      |> Enum.map(&csv_row/1)

    case rows do
      [] when is_binary(source) ->
        {"table", [{"class", "csv-preview"}], [], %{}}

      [headers | body] ->
        head =
          {"thead", [], [{"tr", [], Enum.map(headers, &{"th", [], [&1], %{}}), %{}}], %{}}

        body =
          {"tbody", [],
           Enum.map(body, fn row ->
             {"tr", [], Enum.map(row, &{"td", [], [&1], %{}}), %{}}
           end), %{}}

        {"table", [{"class", "csv-preview"}], [head, body], %{}}

      _ ->
        pre
    end
  end

  defp code_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &code_text/1)
  defp code_text(text) when is_binary(text), do: text
  defp code_text({_tag, _attrs, children, _meta}), do: code_text(children)
  defp code_text(_), do: ""

  defp csv_row(line), do: csv_row(line, "", [], false)

  defp csv_row(<<>>, field, fields, _quoted), do: Enum.reverse([field | fields])

  defp csv_row(<<?", ?", rest::binary>>, field, fields, true),
    do: csv_row(rest, field <> "\"", fields, true)

  defp csv_row(<<?", rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field, fields, not quoted)

  defp csv_row(<<?,, rest::binary>>, field, fields, false),
    do: csv_row(rest, "", [field | fields], false)

  defp csv_row(<<char::utf8, rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field <> <<char::utf8>>, fields, quoted)

  defp tag_llm_responses(nodes) when is_list(nodes), do: Enum.map(nodes, &tag_llm_response/1)

  defp tag_llm_response({"blockquote", attrs, children, meta}) do
    case llm_range(children) do
      {start, finish} ->
        response_attrs = [
          {"class", "llm-response"},
          {"data-start", Integer.to_string(start)},
          {"data-end", Integer.to_string(finish)}
        ]

        {"blockquote", response_attrs ++ attrs, strip_llm_markers(children), meta}

      nil ->
        {"blockquote", attrs, tag_llm_responses(children), meta}
    end
  end

  defp tag_llm_response({tag, attrs, children, meta}) when is_list(children),
    do: {tag, attrs, tag_llm_responses(children), meta}

  defp tag_llm_response(other), do: other

  defp llm_range(nodes) do
    case Regex.run(
           ~r/#{@llm_start}(\d+):(\d+)#{@llm_meta_end}/u,
           llm_marker_text(nodes),
           capture: :all_but_first
         ) do
      [start, finish] -> {String.to_integer(start), String.to_integer(finish)}
      _ -> nil
    end
  end

  defp llm_marker_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &llm_marker_text/1)
  defp llm_marker_text(text) when is_binary(text), do: text
  defp llm_marker_text({_tag, _attrs, children, _meta}), do: llm_marker_text(children)
  defp llm_marker_text(_), do: ""

  defp strip_llm_markers(nodes) when is_list(nodes), do: Enum.map(nodes, &strip_llm_markers/1)

  defp strip_llm_markers(text) when is_binary(text),
    do:
      text
      |> String.replace(~r/#{@llm_start}\d+:\d+#{@llm_meta_end}/u, "")
      |> String.replace(@llm_end, "")

  defp strip_llm_markers({tag, attrs, children, meta}),
    do: {tag, attrs, strip_llm_markers(children), meta}

  defp strip_llm_markers(other), do: other

  # A bare URL in the source becomes a link whose text is the URL
  # (Earmark pure links). Images and X posts upgrade automatically. A bare
  # YouTube URL upgrades only as a complete paragraph. The #+embed directive
  # also upgrades it. A written
  # link — [text](url) — has text different from the href and stays a
  # link. The point sentinel can sit inside the pasted URL; the compare
  # ignores it and the embed re-emits it as a sibling.
  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  # the share sheet appends ?s=20 and friends; a query or fragment after
  # the status id still names the same tweet
  @tweet_re ~r{\Ahttps?://(?:mobile\.)?(?:twitter|x)\.com/[^/]+/status(?:es)?/\d+(?:[?#]\S*)?\z}

  defp embed_urls(nodes, ctx) when is_list(nodes),
    do: Enum.flat_map(nodes, &embed_node(&1, ctx))

  defp embed_node({"p", atts, children, meta}, ctx) do
    source = llm_marker_text(children)

    clean =
      source
      |> String.replace(@pt_sentinel, "")
      |> String.replace("\uE001", "")
      |> String.replace(@anchor, "")

    url = embed_directive_url(clean) || String.trim(clean)

    case youtube_id(url) do
      nil -> [{"p", atts, embed_urls(children, ctx), meta}]
      id -> [youtube_card_node(url, id, meta), preview_markers(source)]
    end
  end

  defp embed_node({"a", atts, [text], meta} = node, ctx) when is_binary(text) do
    url = String.replace(text, @pt_sentinel, "")

    # the href carries the sentinel percent-encoded; the text carries it raw
    href =
      case List.keyfind(atts, "href", 0) do
        {_, h} ->
          h
          |> String.replace(@pt_sentinel, "")
          |> String.replace(URI.encode(@pt_sentinel), "")

        nil ->
          nil
      end

    tail = if text == url, do: [], else: [@pt_sentinel]

    cond do
      href != url -> [node]
      image_url?(url) -> [{"img", [{"src", url}, {"alt", ""}], [], meta} | tail]
      tweet_url?(url) -> tweet_card(url, meta, ctx) ++ tail
      true -> [node]
    end
  end

  defp embed_node({"img", atts, children, meta}, ctx) do
    atts =
      Enum.map(atts, fn
        {"src", src} when is_binary(src) -> {"src", local_image_src(src, ctx)}
        attr -> attr
      end)

    [{"img", atts, children, meta}]
  end

  defp embed_node({tag, atts, children, meta}, ctx) when is_list(children),
    do: [{tag, atts, embed_urls(children, ctx), meta}]

  defp embed_node(other, _ctx), do: [other]

  # A document's picture is a file path: absolute, or relative to the document
  # itself. A relative link is the one that survives another checkout, so the
  # preview resolves it against the document's directory. A URL is left alone.
  def local_image_src(src, ctx) do
    dir = ctx[:base_dir]
    local_url = ctx[:local_url] || (&Function.identity/1)

    path =
      if String.starts_with?(src, "<") and String.ends_with?(src, ">") do
        binary_part(src, 1, byte_size(src) - 2)
      else
        src
      end

    cond do
      Path.type(path) == :absolute -> local_url.(path)
      not is_nil(URI.parse(path).scheme) -> src
      is_binary(dir) -> local_url.(Path.expand(path, dir))
      true -> src
    end
  end

  defp image_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, path: p} when s in ["http", "https"] and is_binary(p) ->
        (p |> Path.extname() |> String.downcase()) in @image_exts

      _ ->
        false
    end
  end

  defp tweet_url?(url), do: Regex.match?(@tweet_re, url)

  defp embed_directive_url(text) do
    case Regex.run(~r/\A#\+embed:[ \t]+(\S+)[ \t]*\z/i, text, capture: :all_but_first) do
      [url] -> url
      _ -> nil
    end
  end

  defp preview_markers(text) do
    text
    |> String.graphemes()
    |> Enum.filter(&(&1 in [@pt_sentinel, "\uE001", @anchor]))
    |> Enum.join()
  end

  @doc false
  def youtube_id(url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    path = String.split(uri.path || "", "/", trim: true)

    id =
      cond do
        host in ["youtu.be", "www.youtu.be"] ->
          List.first(path)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and path == ["watch"] ->
          youtube_query_id(uri.query)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and
            List.first(path) in ["shorts", "live", "embed"] ->
          Enum.at(path, 1)

        true ->
          nil
      end

    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id), do: id
  end

  defp youtube_query_id(nil), do: nil

  defp youtube_query_id(query) do
    URI.decode_query(query)["v"]
  rescue
    ArgumentError -> nil
  end

  defp youtube_card_node(url, id, meta) do
    {"a",
     [
       {"class", "youtube-card"},
       {"href", url},
       {"target", "_blank"},
       {"rel", "noopener noreferrer"},
       {"aria-label", "Watch this video on YouTube"}
     ],
     [
       {"img", [{"src", youtube_thumbnail(id)}, {"alt", "YouTube video thumbnail"}], [], meta},
       {"span", [{"class", "youtube-play"}, {"aria-hidden", "true"}], ["▶"], meta}
     ], meta}
  end

  @doc "A YouTube URL, or an `#+embed:` line naming one, drawn as a card; nil otherwise."
  def youtube_embed_html(source) do
    url = embed_directive_url(source) || String.trim(source)

    case url && youtube_id(url) do
      nil ->
        nil

      id ->
        safe_url = url |> html_escape() |> String.replace("\"", "&quot;")

        ~s(<a class="youtube-card" href="#{safe_url}" target="_blank" rel="noopener noreferrer" aria-label="Watch this video on YouTube"><img src="#{youtube_thumbnail(id)}" alt="YouTube video thumbnail"><span class="youtube-play" aria-hidden="true">▶</span></a>)
    end
  end

  @doc false
  def youtube_thumbnail(id), do: "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"

  defp tweet_card(url, meta, ctx) do
    card = ctx[:tweet_card] || fn _ -> :error end

    case card.(url) do
      {:ok, html} ->
        # the card html renders verbatim; Oembed strips script tags, and
        # the iframe sandbox runs no scripts either way
        [{"div", [{"class", "tweet"}], [html], Map.put(meta, :verbatim, true)}]

      :pending ->
        [
          {"div", [{"class", "tweet tweet-pending"}],
           ["Loading tweet — ", {"a", [{"href", url}], [url], meta}], meta}
        ]

      :error ->
        [{"a", [{"href", url}], [url], meta}]
    end
  end



end
