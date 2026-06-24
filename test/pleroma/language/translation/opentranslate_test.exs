# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.OpentranslateTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  alias Pleroma.Language.Translation
  alias Pleroma.Language.Translation.Opentranslate
  alias Pleroma.Web.CommonAPI

  setup do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)

    clear_config(
      [Pleroma.Language.Translation.Opentranslate, :base_url],
      "http://127.0.0.1:5000"
    )

    clear_config([Pleroma.Language.Translation.Opentranslate, :api_key], nil)

    :ok
  end

  test "it is configured with only an internal base URL" do
    assert Opentranslate.configured?()
  end

  test "it translates text through a self-hosted OpenTranslate service" do
    {:ok, res} =
      Opentranslate.translate(
        "Bonjour le monde",
        "fr",
        "en"
      )

    assert %{
             content: "Hello world",
             detected_source_language: "fr",
             provider: "OpenTranslate"
           } = res
  end

  test "it lets OpenTranslate detect an unknown source language" do
    {:ok, res} =
      Opentranslate.translate(
        "Unknown source text",
        nil,
        "en"
      )

    assert %{
             content: "Hello world",
             detected_source_language: "fr",
             provider: "OpenTranslate"
           } = res
  end

  test "it infers Japanese source language before provider auto-detection" do
    {:ok, res} =
      Opentranslate.translate(
        "14th\u8a87\u5f35\u3057\u305fDay1",
        nil,
        "en"
      )

    assert %{
             content: "Day one has the exaggerated Tachibana.",
             detected_source_language: "ja",
             provider: "OpenTranslate"
           } = res
  end

  test "it only advertises English as a translation target" do
    assert {:ok, ["en"]} = Opentranslate.supported_languages(:target)
  end

  test "it returns source languages from the OpenTranslate service" do
    assert {:ok,
            ["ar", "de", "en", "es", "fr", "ga", "hi", "it", "ja", "ko", "pt", "ru", "zh-Hans"]} =
             Opentranslate.supported_languages(:source)
  end

  test "it builds an English-only language matrix" do
    assert {:ok, matrix} = Opentranslate.languages_matrix()

    assert matrix["fr"] == ["en"]
    assert matrix["zh-Hans"] == ["en"]
    assert matrix["en"] == []
  end

  test "it rejects non-English targets" do
    assert {:error, :unsupported_language} =
             Opentranslate.translate(
               "Hello world",
               "en",
               "fr"
             )
  end

  test "status translation returns a clean error for unsupported targets" do
    clear_config([Translation, :provider], UnsupportedLanguageTranslationMock)

    user = insert(:user, language: "fr")
    %{conn: conn} = oauth_access(["read:statuses"], user: user)
    another_user = insert(:user)

    {:ok, activity} =
      CommonAPI.post(another_user, %{
        status: "Bonjour!",
        visibility: "public",
        language: "fr"
      })

    response =
      conn
      |> post("/api/v1/statuses/#{activity.id}/translate")
      |> json_response_and_validate_schema(400)

    assert response == %{"error" => "Target language is not supported"}
  end

  test "status translation returns a service error when the provider is unavailable" do
    clear_config([Translation, :provider], UnavailableTranslationMock)

    user = insert(:user, language: "en")
    %{conn: conn} = oauth_access(["read:statuses"], user: user)
    another_user = insert(:user)

    {:ok, activity} =
      CommonAPI.post(another_user, %{
        status: "Bonjour!",
        visibility: "public",
        language: "fr"
      })

    response =
      conn
      |> post("/api/v1/statuses/#{activity.id}/translate")
      |> json_response_and_validate_schema(503)

    assert response == %{"error" => "Translation service not available"}
  end
end
