defmodule BBCode.Generator.Test do
  use ExUnit.Case

  describe "simple tags" do
    test "[b] tags are translated to <strong>" do
      assert {:ok, "<strong>testing</strong>"} = BBCode.to_html("[b]testing[/b]")
    end

    test "[i] tags are translated to <em>" do
      assert {:ok, "<em>testing</em>"} = BBCode.to_html("[i]testing[/i]")
    end

    test "[u] tags are translated to <u>" do
      assert {:ok, "<u>testing</u>"} = BBCode.to_html("[u]testing[/u]")
    end

    test "[s] tags are translated to <del>" do
      assert {:ok, "<del>testing</del>"} = BBCode.to_html("[s]testing[/s]")
    end

    test "[code] tags are translated to <pre>" do
      assert {:ok, "<pre>testing</pre>"} = BBCode.to_html("[code]testing[/code]")
    end

    test "[quote] tags are translated to <blockquote>" do
      assert {:ok, "<blockquote>testing</blockquote>"} = BBCode.to_html("[quote]testing[/quote]")
    end

    test "compounding simple tags works as expected" do
      assert {:ok, "<strong><em>testing</em></strong>"} = BBCode.to_html("[b][i]testing[/i][/b]")
    end
  end

  describe "lists" do
    test "[ul] lists are rendered properly" do
      data = """
      [ul]
      [*]a
      [*]b
      [*]c
      [/ul]
      """

      expected = "<ul><li>a</li><li>b</li><li>c</li></ul>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end

    test "[ol] lists are rendered properly" do
      data = """
      [ol]
      [*]a
      [*]b
      [*]c
      [/ol]
      """

      expected = "<ol><li>a</li><li>b</li><li>c</li></ol>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end
  end

  describe "tables" do
    test "[table] tables are rendered properly" do
      data = """
      [table]
      [tr]
      [th]header[/th]
      [/tr]
      [tr]
      [td]cell[/td]
      [/tr]
      [/table]
      """

      expected = "<table><tr><th>header</th></tr><tr><td>cell</td></tr></table>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end
  end

  describe "links" do
    test "bare [url] links are rendered properly" do
      data = """
      [url]http://example.com[/url]
      """

      expected = "<a href=\"http://example.com\">http://example.com</a><br>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end

    test "named [url] links are rendered properly" do
      data = """
      [url=http://example.com]Example[/url]
      """

      expected = "<a href=\"http://example.com\">Example</a><br>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end
  end

  describe "images" do
    test "bare [img] links are rendered properly" do
      data = """
      [img]http://example.com/image.jpg[/img]
      """

      expected = "<img src=\"http://example.com/image.jpg\"><br>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end

    test "sized [img] links are rendered properly" do
      data = """
      [img=32x32]http://example.com/image.jpg[/img]
      """

      expected = "<img src=\"http://example.com/image.jpg\" width=\"32\" height=\"32\"><br>"

      assert {:ok, ^expected} = BBCode.to_html(data)
    end
  end

  describe "documents" do
    test "it correctly renders a complex document" do
      data = """
      [quote]
      A multiline quote.
      This is the second line.
      [/quote]

      [ul]
      [*]a
      [*]b
      [*]c
      [/ul]

      [b]bold[/b]
      [i]italic[/i]
      [u]underline[/u]
      [s]strikethrough[/s]

      [url=http://example.com]a link[/url]

      @kaniini (a mention)
      """

      {:ok, output} = BBCode.to_html(data)

      assert output ==
               "<blockquote>A multiline quote.<br>This is the second line.<br></blockquote><ul><li>a</li><li>b</li><li>c</li></ul><strong>bold</strong><br><em>italic</em><br><u>underline</u><br><del>strikethrough</del><br><br><a href=\"http://example.com\">a link</a><br><br>@kaniini (a mention)<br>"
    end
  end
end
