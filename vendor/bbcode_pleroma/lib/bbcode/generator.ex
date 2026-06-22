defmodule BBCode.Generator do
  @moduledoc """
  Generate HTML from BBCode fragments in AST form.

  The BBCode syntax supported is described at [bbcode.org][bbcode].

     [bbcode]: https://www.bbcode.org/reference.php
  """

  defp start_tag(tagname), do: Enum.join(["<", tagname, ">"])
  defp end_tag(tagname), do: Enum.join(["</", tagname, ">"])

  defp simple_tag(tagname, subtree) do
    {:ok, text} = reduce_subtree(subtree)
    {:ok, [start_tag(tagname), text, end_tag(tagname)] |> Enum.join()}
  end

  defp link_tag(url), do: Enum.join(["<a href=\"", url, "\">"])

  defp reduce_subtree({:b, subtree}), do: simple_tag("strong", subtree)
  defp reduce_subtree({:i, subtree}), do: simple_tag("em", subtree)
  defp reduce_subtree({:u, subtree}), do: simple_tag("u", subtree)
  defp reduce_subtree({:s, subtree}), do: simple_tag("del", subtree)
  defp reduce_subtree({:ul, subtree}), do: simple_tag("ul", subtree)
  defp reduce_subtree({:ol, subtree}), do: simple_tag("ol", subtree)
  defp reduce_subtree({:li, subtree}), do: simple_tag("li", subtree)
  defp reduce_subtree({:code, subtree}), do: simple_tag("pre", subtree)
  defp reduce_subtree({:quote, subtree}), do: simple_tag("blockquote", subtree)
  defp reduce_subtree({:table, subtree}), do: simple_tag("table", subtree)
  defp reduce_subtree({:tr, subtree}), do: simple_tag("tr", subtree)
  defp reduce_subtree({:th, subtree}), do: simple_tag("th", subtree)
  defp reduce_subtree({:td, subtree}), do: simple_tag("td", subtree)

  defp reduce_subtree({:url, text}),
    do: {:ok, [link_tag(text), text, end_tag("a")] |> Enum.join()}

  defp reduce_subtree({:url, address, text}),
    do: {:ok, [link_tag(address), text, end_tag("a")] |> Enum.join()}

  defp reduce_subtree({:img, address}),
    do: {:ok, "<img src=\"#{address}\">"}

  defp reduce_subtree({:img, width, height, address}),
    do: {:ok, "<img src=\"#{address}\" width=\"#{width}\" height=\"#{height}\">"}

  defp reduce_subtree({:br}), do: {:ok, "<br>"}

  defp reduce_subtree(text_node) when is_binary(text_node),
    do: {:ok, text_node}

  defp reduce_subtree(children) when is_list(children) do
    with {:ok, new_tree} <-
           Enum.reduce_while(children, {:ok, []}, fn x, {:ok, acc} ->
             with {:ok, new_tree} <- reduce_subtree(x) do
               {:cont, {:ok, acc ++ [new_tree]}}
             else
               {:error, e} ->
                 {:halt, {:error, e}}
             end
           end) do
      {:ok, Enum.join(new_tree)}
    else
      {:error, e} ->
        {:error, e}
    end
  end

  defp reduce_subtree(tree), do: {:error, "unknown input #{inspect(tree)}"}

  def to_html(tree) when is_list(tree), do: reduce_subtree(tree)

  def to_html(_), do: {:error, "not a valid tree"}
end
