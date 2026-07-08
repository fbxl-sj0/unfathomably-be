# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.DeeplTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Language.Translation.Deepl

  test "it translates text" do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    clear_config([Pleroma.Language.Translation.Deepl, :base_url], "https://api-free.deepl.com")
    clear_config([Pleroma.Language.Translation.Deepl, :api_key], "API_KEY")

    {:ok, res} =
      Deepl.translate(
        "USUNĄĆ ŚLEDZIKA!Wklej to na swojego śledzika. Jeżeli uzbieramy 70% użytkowników nk...to usuną śledzika!!!",
        "pl",
        "en"
      )

    assert %{
             detected_source_language: "PL",
             provider: "DeepL"
           } = res
  end

  test "it sends translation requests as JSON with a text array" do
    Tesla.Mock.mock(fn env ->
      assert env.method == :post
      assert env.url == "https://api-free.deepl.com/v2/translate"
      assert {"Content-Type", "application/json"} in env.headers
      assert {"Authorization", "DeepL-Auth-Key API_KEY"} in env.headers

      assert %{
               "text" => ["bonjour"],
               "source_lang" => "FR",
               "target_lang" => "en",
               "tag_handling" => "html"
             } = Jason.decode!(env.body)

      {:ok,
       %Tesla.Env{
         status: 200,
         body:
           Jason.encode!(%{
             "translations" => [
               %{"text" => "hello", "detected_source_language" => "FR"}
             ]
           })
       }}
    end)

    clear_config([Pleroma.Language.Translation.Deepl, :base_url], "https://api-free.deepl.com")
    clear_config([Pleroma.Language.Translation.Deepl, :api_key], "API_KEY")

    assert {:ok, %{content: "hello", detected_source_language: "FR", provider: "DeepL"}} =
             Deepl.translate("bonjour", "fr", "en")
  end

  test "it returns languages list" do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    clear_config([Pleroma.Language.Translation.Deepl, :base_url], "https://api-free.deepl.com")
    clear_config([Pleroma.Language.Translation.Deepl, :api_key], "API_KEY")

    assert {:ok, [language | _languages]} = Deepl.supported_languages(:target)

    assert is_binary(language)
  end

  test "malformed translation responses are provider errors" do
    Tesla.Mock.mock(fn _env -> {:ok, %Tesla.Env{status: 200, body: "not json"}} end)
    clear_config([Pleroma.Language.Translation.Deepl, :base_url], "https://api-free.deepl.com")
    clear_config([Pleroma.Language.Translation.Deepl, :api_key], "API_KEY")

    assert {:error, :internal_server_error} = Deepl.translate("bonjour", "fr", "en")
  end

  test "malformed language responses are provider errors" do
    Tesla.Mock.mock(fn _env -> {:ok, %Tesla.Env{status: 200, body: "not json"}} end)
    clear_config([Pleroma.Language.Translation.Deepl, :base_url], "https://api-free.deepl.com")
    clear_config([Pleroma.Language.Translation.Deepl, :api_key], "API_KEY")

    assert {:error, :internal_server_error} = Deepl.supported_languages(:target)
  end
end
