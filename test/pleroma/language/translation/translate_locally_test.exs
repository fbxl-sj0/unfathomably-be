# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.TranslateLocallyTest do
  use Pleroma.DataCase

  alias Pleroma.Language.Translation.TranslateLocally

  @example_models %{
    "de" => %{
      "en" => "de-en-base"
    },
    "en" => %{
      "de" => "en-de-base",
      "pl" => "en-pl-tiny"
    },
    "cs" => %{
      "en" => "cs-en-base"
    },
    "pl" => %{
      "en" => "pl-en-tiny"
    }
  }

  test "it is disabled without a model map" do
    clear_config([Pleroma.Language.Translation.TranslateLocally, :models], nil)

    refute TranslateLocally.configured?()
    assert {:error, :not_found} = TranslateLocally.languages_matrix()
  end

  test "it returns source and target languages" do
    clear_config([Pleroma.Language.Translation.TranslateLocally, :models], @example_models)

    assert {:ok, source_languages} = TranslateLocally.supported_languages(:source)
    assert ["cs", "de", "en", "pl"] = Enum.sort(source_languages)

    assert {:ok, target_languages} = TranslateLocally.supported_languages(:target)
    assert ["de", "en", "pl"] = Enum.sort(target_languages)
  end

  describe "it returns languages matrix" do
    test "without intermediary language" do
      clear_config([Pleroma.Language.Translation.TranslateLocally, :models], @example_models)

      assert {:ok,
              %{
                "cs" => ["en"],
                "de" => ["en"],
                "en" => ["de", "pl"],
                "pl" => ["en"]
              }} = TranslateLocally.languages_matrix()
    end

    test "with intermediary language" do
      clear_config([Pleroma.Language.Translation.TranslateLocally, :models], @example_models)
      clear_config([Pleroma.Language.Translation.TranslateLocally, :intermediary_language], "en")

      assert {:ok,
              %{
                "cs" => ["en", "de", "pl"],
                "de" => ["en", "pl"],
                "en" => ["de", "pl"],
                "pl" => ["en", "de"]
              }} = TranslateLocally.languages_matrix()
    end
  end

  test "it returns a clean error when no route exists" do
    clear_config([Pleroma.Language.Translation.TranslateLocally, :models], @example_models)

    assert {:error, :unsupported_language} =
             TranslateLocally.translate("Bonjour le monde", "fr", "en")
  end
end
