# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.EctoType.ActivityPub.ObjectValidators.LanguageCodeTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.EctoType.ActivityPub.ObjectValidators.LanguageCode

  test "accepts language code" do
    text = "pl"
    assert {:ok, ^text} = LanguageCode.cast(text)
  end

  test "accepts language code with region" do
    text = "pl-PL"
    assert {:ok, ^text} = LanguageCode.cast(text)
  end

  test "rejects invalid language code" do
    assert {:error, [validation: :invalid_language]} = LanguageCode.cast("ru_RU")
    assert {:error, [validation: :invalid_language]} = LanguageCode.cast(" ")
    assert {:error, [validation: :invalid_language]} = LanguageCode.cast("en-US\n")
  end

  test "rejects non-text" do
    assert :error == LanguageCode.cast(42)
  end
end
