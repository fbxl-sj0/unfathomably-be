defmodule BBCode.Parser.Test do
  use ExUnit.Case
  alias BBCode.Parser

  describe "simple tags" do
    test "it parses [b] tags correctly" do
      assert {:ok, [b: "testing"]} = Parser.parse("[b]testing[/b]")
    end

    test "it parses [i] tags correctly" do
      assert {:ok, [i: "testing"]} = Parser.parse("[i]testing[/i]")
    end

    test "it parses [u] tags correctly" do
      assert {:ok, [u: "testing"]} = Parser.parse("[u]testing[/u]")
    end

    test "it parses [s] tags correctly" do
      assert {:ok, [s: "testing"]} = Parser.parse("[s]testing[/s]")
    end

    test "it parses [code] tags correctly" do
      assert {:ok, [code: "testing"]} = Parser.parse("[code]testing[/code]")
    end

    test "it parses [quote] tags correctly" do
      assert {:ok, [quote: "testing"]} = Parser.parse("[quote]testing[/quote]")
    end
  end

  describe "nested tags" do
    test "it parses [ul] lists correctly" do
      assert {:ok, [{:ul, [{:li, "a"}, {:li, "b"}]}]} =
               Parser.parse("[ul][li]a[/li][li]b[/li][/ul]")
    end

    test "it parses [ol] lists correctly" do
      assert {:ok, [{:ol, [{:li, "a"}, {:li, "b"}]}]} =
               Parser.parse("[ol][li]a[/li][li]b[/li][/ol]")
    end
  end

  describe "multiline" do
    test "it parses a multiline [li] list" do
      data = """
      [ul]
      [li]a[/li]
      [li]b[/li]
      [/ul]
      """

      assert {:ok, [{:ul, [{:li, "a"}, {:li, "b"}]}]} = Parser.parse(data)
    end

    test "it parses a multiline [*] list" do
      data = """
      [ul]
      [*]a
      [*]b
      [/ul]
      """

      assert {:ok, [{:ul, [{:li, ["a"]}, {:li, ["b"]}]}]} = Parser.parse(data)
    end

    test "it parses a multiline [*] list with children" do
      data = """
      [ul]
      [*][url=http://example.com]Example[/url]
      [/ul]
      """

      assert {:ok, [{:ul, {:li, [{:url, "http://example.com", "Example"}]}}]} = Parser.parse(data)
    end
  end

  describe "property tags" do
    test "it parses [url=] tags correctly" do
      assert {:ok, [{:url, "http://example.com", "Example"}]} =
               Parser.parse("[url=http://example.com]Example[/url]")
    end
  end

  describe "non-tags" do
    test "it properly handles bracket text" do
      data = "oh no!  [swearing intensifies]"

      assert {:ok, ["oh no!  ", "[swearing intensifies]"]} = Parser.parse(data)
    end
  end
end
