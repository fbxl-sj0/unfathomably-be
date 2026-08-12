# Unfathomably status filter matching
# ------------------------------------
# File: filter_matching_test.exs
# Purpose: Protect literal, whole-word, and context-aware filter matching.
# Responsibilities: Verify in-memory patterns and exact match reporting.
# This file intentionally does NOT contain controller or rendering tests.

defmodule Pleroma.FilterMatchingTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Filter

  test "whole-word filters do not match inside a larger word" do
    filter = %Filter{phrase: "cat", whole_word: true, context: ["home"]}

    assert [] = Filter.matching([filter], "concatenate", "home")
    assert [{^filter, "CAT"}] = Filter.matching([filter], "A CAT arrived", "home")
  end

  test "non-whole-word filters and punctuation-leading phrases remain literal" do
    partial = %Filter{phrase: "cat", whole_word: false, context: ["home"]}
    mention = %Filter{phrase: "@remote.example", whole_word: true, context: ["home"]}

    assert [{^partial, "cat"}] = Filter.matching([partial], "concatenate", "home")

    assert [{^mention, "@Remote.Example"}] =
             Filter.matching([mention], "from @Remote.Example today", "home")
  end

  test "filters apply only in their configured context" do
    filter = %Filter{phrase: "spoiler", whole_word: true, context: ["thread"]}

    assert [] = Filter.matching([filter], "spoiler", "home")
    assert [{^filter, "spoiler"}] = Filter.matching([filter], "spoiler", "thread")
  end
end

# end of filter_matching_test.exs
