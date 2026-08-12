# Unfathomably BE
# ----------------
#
# File: type_test.exs
#
# Purpose:
#   Cover bounded JSON-LD type selection used by incoming federation dispatch.
#
# Responsibilities:
#   - prove scalar and list compatibility
#   - prefer concrete and known ActivityStreams types
#   - preserve specialized compact-vocabulary object types
#
# This file intentionally does not exercise network federation or persistence.

defmodule Pleroma.Web.ActivityPub.TypeTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.Type

  @known ~w[Create Note Event Person Group]

  test "accepts scalar and singleton type values" do
    assert Type.first_known("Note", @known) == "Note"
    assert Type.first_known(["Event"], @known) == "Event"
  end

  test "prefers a known concrete type regardless of list order" do
    assert Type.first_known(["Object", "Note"], @known) == "Note"
    assert Type.first_known(["foaf:Person", "Person"], @known) == "Person"
    assert Type.first_known(["as:Activity", "as:Create"], @known) == "Create"
  end

  test "preserves an unknown specialized type instead of a generic base" do
    assert Type.first_known(["Object", "maid:Offer"], @known) == "maid:Offer"
  end

  test "drops malformed values without inventing a type" do
    assert Type.first_known([nil, %{"id" => "Note"}], @known) == nil
    assert Type.first_known([], @known) == nil
  end
end

# end of type_test.exs
