defmodule Pleroma.Web.XMLTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.XML

  import ExUnit.CaptureLog

  test "refuses to parse any entities from XML" do
    data = File.read!("test/fixtures/xml_billion_laughs.xml")

    capture_log(fn ->
      assert(:error == XML.parse_document(data))
    end)
  end

  test "refuses to load external entities from XML" do
    data = File.read!("test/fixtures/xml_external_entities.xml")

    capture_log(fn ->
      assert(:error == XML.parse_document(data))
    end)
  end
end
