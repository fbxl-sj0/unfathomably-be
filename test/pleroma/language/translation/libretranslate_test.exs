# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.LibretranslateTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.Language.Translation.Libretranslate

  test "malformed translation responses are provider errors" do
    Tesla.Mock.mock(fn _env -> {:ok, %Tesla.Env{status: 200, body: "not json"}} end)

    clear_config(
      [Pleroma.Language.Translation.Libretranslate, :base_url],
      "https://libretranslate.example"
    )

    clear_config([Pleroma.Language.Translation.Libretranslate, :api_key], "API_KEY")

    assert {:error, :internal_server_error} = Libretranslate.translate("bonjour", "fr", "en")
  end

  test "malformed language responses are provider errors" do
    Tesla.Mock.mock(fn _env -> {:ok, %Tesla.Env{status: 200, body: "not json"}} end)

    clear_config(
      [Pleroma.Language.Translation.Libretranslate, :base_url],
      "https://libretranslate.example"
    )

    clear_config([Pleroma.Language.Translation.Libretranslate, :api_key], "API_KEY")

    assert {:error, :internal_server_error} = Libretranslate.supported_languages(:target)
  end
end
