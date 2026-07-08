# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.MozhiTest do
  use Pleroma.DataCase

  alias Pleroma.Language.Translation.Mozhi

  setup do
    clear_config([Pleroma.Language.Translation.Mozhi, :base_url], "https://mozhi.example")
    clear_config([Pleroma.Language.Translation.Mozhi, :engine], "libretranslate")

    Tesla.Mock.mock_global(fn
      %Tesla.Env{
        method: :get,
        url: "https://mozhi.example/api/translate?" <> query
      } ->
        params = URI.decode_query(query)

        assert params["engine"] == "libretranslate"
        assert params["text"] == "Bonjour le monde"
        assert params["from"] == "fr"
        assert params["to"] == "en"

        {:ok,
         %Tesla.Env{
           status: 200,
           body: ~s({"translated-text":"Hello world"}),
           headers: [{"content-type", "application/json"}]
         }}

      %Tesla.Env{
        method: :get,
        url: "https://mozhi.example/api/source_languages?" <> query
      } ->
        assert %{"engine" => "libretranslate"} = URI.decode_query(query)

        {:ok,
         %Tesla.Env{
           status: 200,
           body: ~s([{"Id":"fr"},{"Id":"en"}]),
           headers: [{"content-type", "application/json"}]
         }}

      %Tesla.Env{
        method: :get,
        url: "https://mozhi.example/api/target_languages?" <> query
      } ->
        assert %{"engine" => "libretranslate"} = URI.decode_query(query)

        {:ok,
         %Tesla.Env{
           status: 200,
           body: ~s([{"Id":"en"},{"Id":"es"}]),
           headers: [{"content-type", "application/json"}]
         }}
    end)

    :ok
  end

  test "it is configured with a base URL and engine" do
    assert Mozhi.configured?()
  end

  test "it translates text through a Mozhi service" do
    assert {:ok,
            %{
              content: "Hello world",
              detected_source_language: "fr",
              provider: "Mozhi"
            }} = Mozhi.translate("Bonjour le monde", "fr", "en")
  end

  test "it returns languages from the configured Mozhi engine" do
    assert {:ok, ["fr", "en"]} = Mozhi.supported_languages(:source)
    assert {:ok, ["en", "es"]} = Mozhi.supported_languages(:target)
  end

  test "it builds a language matrix from Mozhi source and target languages" do
    assert {:ok,
            %{
              "fr" => ["en", "es"],
              "en" => ["es"]
            }} = Mozhi.languages_matrix()
  end
end
