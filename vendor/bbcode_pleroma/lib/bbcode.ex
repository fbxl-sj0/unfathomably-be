defmodule BBCode do
  alias BBCode.Generator
  alias BBCode.Parser

  @moduledoc """
  # BBCode

  A library providing BBCode parsing for Elixir applications.
  """

  def to_html(data) do
    with {:ok, tree} <- Parser.parse(data),
         {:ok, html} <- Generator.to_html(tree) do
      {:ok, html}
    else
      {:error, e} ->
        {:error, e}
    end
  end
end
