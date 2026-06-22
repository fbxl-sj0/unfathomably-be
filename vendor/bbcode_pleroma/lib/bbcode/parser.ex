defmodule BBCode.Parser do
  import NimbleParsec

  @moduledoc """
  Parse BBCode into an abstract tree.
  """

  tag = utf8_string([?a..?z, ?A..?Z, ?0..?9], min: 1)
  text = utf8_string([not: ?[, not: ?], not: ?\r, not: ?\n], min: 1)

  end_tag =
    ignore(string("[/"))
    |> concat(tag)
    |> ignore(string("]"))

  # block tags
  quote_tag = string("quote")
  ul_tag = string("ul")
  ol_tag = string("ol")
  li_tag = string("li")
  code_tag = string("code")
  table_tag = string("table")
  tr_tag = string("tr")
  th_tag = string("th")
  td_tag = string("td")

  # span tags
  b_tag = string("b")
  i_tag = string("i")
  u_tag = string("u")
  s_tag = string("s")
  url_tag = string("url")
  img_tag = string("img")

  # special tags
  star_tag = ignore(string("[*]"))

  # newline
  newline = utf8_char([?\r, ?\n])

  defcombinatorp(
    :block_tag,
    ignore(string("["))
    |> choice([quote_tag, ul_tag, ol_tag, li_tag, code_tag, table_tag, tr_tag, th_tag, td_tag])
    |> ignore(string("]"))
    |> ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2)))
  )

  defcombinatorp(
    :block_stanza,
    parsec(:block_tag)
    |> repeat(lookahead_not(string("[/")) |> choice([parsec(:child_stanza), text]))
    |> wrap()
    |> concat(end_tag)
    |> ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2)))
    |> post_traverse(:emit_tree_node)
  )

  defcombinatorp(
    :span_tag,
    ignore(string("["))
    |> choice([url_tag, img_tag, b_tag, i_tag, u_tag, s_tag])
    |> ignore(string("]"))
    |> ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2)))
  )

  defcombinatorp(
    :span_tag_with_property,
    ignore(string("["))
    |> concat(url_tag)
    |> ignore(string("="))
    |> concat(text)
    |> ignore(string("]"))
    |> ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2)))
  )

  defcombinatorp(
    :img_tag_with_size_property,
    ignore(string("["))
    |> concat(img_tag)
    |> ignore(string("="))
    |> integer(min: 1)
    |> ignore(string("x"))
    |> integer(min: 1)
    |> ignore(string("]"))
    |> ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2)))
  )

  defcombinatorp(
    :span_stanza,
    parsec(:span_tag)
    |> repeat(lookahead_not(string("[/")) |> choice([parsec(:child_stanza), text]))
    |> wrap()
    |> concat(end_tag)
    |> post_traverse(:emit_tree_node)
  )

  defcombinatorp(
    :text_stanza,
    text
    |> wrap()
    |> post_traverse(:emit_tree_node)
  )

  defcombinatorp(
    :star_stanza,
    star_tag
    |> repeat(
      lookahead_not(string("\n"))
      |> choice([parsec(:child_stanza), text])
    )
    |> wrap()
    |> concat(ignore(optional(utf8_string([?\n, ?\r], min: 1, max: 2))))
    |> post_traverse(:emit_tree_node_star)
  )

  defcombinatorp(
    :span_stanza_with_property,
    parsec(:span_tag_with_property)
    |> repeat(lookahead_not(string("[/")) |> choice([parsec(:child_stanza), text]))
    |> wrap()
    |> concat(end_tag)
    |> post_traverse(:emit_tree_node_property)
  )

  defcombinatorp(
    :img_stanza_with_size_property,
    parsec(:img_tag_with_size_property)
    |> repeat(lookahead_not(string("[/")) |> choice([parsec(:child_stanza), text]))
    |> wrap()
    |> concat(end_tag)
    |> post_traverse(:emit_tree_node_size_property)
  )

  defcombinatorp(
    :newline_stanza,
    newline
    |> post_traverse(:emit_tree_node_newline)
  )

  defcombinatorp(
    :bracket_text_stanza,
    string("[")
    |> concat(text)
    |> string("]")
    |> wrap()
    |> post_traverse(:emit_tree_node)
  )

  defcombinatorp(
    :child_stanza,
    choice([
      parsec(:newline_stanza),
      parsec(:star_stanza),
      parsec(:block_stanza),
      parsec(:img_stanza_with_size_property),
      parsec(:span_stanza_with_property),
      parsec(:span_stanza),
      parsec(:bracket_text_stanza)
    ])
  )

  defcombinatorp(
    :root_stanza,
    choice([parsec(:child_stanza), parsec(:text_stanza)])
  )

  defparsecp(
    :parse_tree,
    repeat(lookahead_not(string("[/")) |> parsec(:root_stanza)) |> eos()
  )

  defp emit_tree_node_newline(rest, _args, context, _line, _offset),
    do: {rest, [{:br}], context}

  defp emit_tree_node_star(rest, [nodes], context, _line, _offset),
    do: {rest, [{:li, nodes}], context}

  defp emit_tree_node_size_property(
         rest,
         [tag, [tag, width, height, inside]],
         context,
         _line,
         _offset
       ),
       do: {rest, [{String.to_atom(tag), width, height, inside}], context}

  defp emit_tree_node_property(rest, [tag, [tag, property, inside]], context, _line, _offset),
    do: {rest, [{String.to_atom(tag), property, inside}], context}

  defp emit_tree_node_property(rest, [tag, [tag, property | nodes]], context, _line, _offset),
    do: {rest, [{String.to_atom(tag), property, nodes}], context}

  defp emit_tree_node(rest, [tag, [tag, inside]], context, _line, _offset),
    do: {rest, [{String.to_atom(tag), inside}], context}

  defp emit_tree_node(rest, [tag, [tag | nodes]], context, _line, _offset),
    do: {rest, [{String.to_atom(tag), nodes}], context}

  defp emit_tree_node(rest, [[text]], context, _line, _offset),
    do: {rest, [text], context}

  defp emit_tree_node(rest, [["[", text, "]"]], context, _line, _offset),
    do: {rest, ["[" <> text <> "]"], context}

  def parse(text) do
    with {:ok, nodes, _, _, _, _} <- parse_tree(text) do
      {:ok, nodes}
    else
      {:error, e, _, _, _, _} ->
        {:error, e}
    end
  end
end
