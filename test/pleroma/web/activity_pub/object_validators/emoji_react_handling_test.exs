# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.EmojiReactHandlingTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  describe "EmojiReacts" do
    setup do
      user = insert(:user)
      {:ok, post_activity} = CommonAPI.post(user, %{status: "uguu"})

      object = Pleroma.Object.get_by_ap_id(post_activity.data["object"])

      {:ok, valid_emoji_react, []} = Builder.emoji_react(user, object, "👌")

      %{user: user, post_activity: post_activity, valid_emoji_react: valid_emoji_react}
    end

    test "it validates a valid EmojiReact", %{valid_emoji_react: valid_emoji_react} do
      assert valid_emoji_react["_misskey_reaction"] == valid_emoji_react["content"]

      assert {:ok, %{"_misskey_reaction" => reaction}, _} =
               ObjectValidator.validate(valid_emoji_react, [])

      assert reaction == valid_emoji_react["content"]
    end

    test "it decodes bounded numeric HTML emoji entities", %{
      valid_emoji_react: valid_emoji_react
    } do
      encoded =
        valid_emoji_react
        |> Map.put("content", "&#128076;")
        |> Map.put("_misskey_reaction", "&#x1F44C;")

      assert {:ok, normalized, _meta} = ObjectValidator.validate(encoded, [])
      assert normalized["content"] == "\u{1F44C}"
      assert normalized["_misskey_reaction"] == "\u{1F44C}"

      non_emoji = Map.put(valid_emoji_react, "content", "&#60;")
      assert {:error, changeset} = ObjectValidator.validate(non_emoji, [])
      assert {:content, {"is not a valid emoji", []}} in changeset.errors
    end

    test "it is not valid without a 'content' field", %{valid_emoji_react: valid_emoji_react} do
      without_content =
        valid_emoji_react
        |> Map.delete("content")

      {:error, cng} = ObjectValidator.validate(without_content, [])

      refute cng.valid?
      assert {:content, {"can't be blank", [validation: :required]}} in cng.errors
    end

    test "it rejects reaction names beyond the shared storage bound", %{
      valid_emoji_react: valid_emoji_react
    } do
      oversized =
        valid_emoji_react
        |> Map.put("content", ":" <> String.duplicate("a", 100) <> ":")
        |> Map.put("_misskey_reaction", ":" <> String.duplicate("a", 100) <> ":")

      assert {:error, changeset} = ObjectValidator.validate(oversized, [])
      assert {:content, {"is too long", []}} in changeset.errors
    end

    test "it rejects malformed object references without raising", %{
      valid_emoji_react: valid_emoji_react
    } do
      malformed_object =
        valid_emoji_react
        |> Map.put("object", ["not", "an", "object"])

      assert {:error, cng} = ObjectValidator.validate(malformed_object, [])
      refute cng.valid?
    end

    test "it is valid when custom emoji is used", %{valid_emoji_react: valid_emoji_react} do
      without_emoji_content =
        valid_emoji_react
        |> Map.put("content", ":hello:")
        |> Map.put("tag", [
          %{
            "type" => "Emoji",
            "name" => ":hello:",
            "icon" => %{"url" => "http://somewhere", "type" => "Image"}
          }
        ])

      {:ok, _, _} = ObjectValidator.validate(without_emoji_content, [])
    end

    test "it is not valid when custom emoji don't have a matching tag", %{
      valid_emoji_react: valid_emoji_react
    } do
      without_emoji_content =
        valid_emoji_react
        |> Map.put("content", ":hello:")
        |> Map.put("tag", [
          %{
            "type" => "Emoji",
            "name" => ":whoops:",
            "icon" => %{"url" => "http://somewhere", "type" => "Image"}
          }
        ])

      {:error, cng} = ObjectValidator.validate(without_emoji_content, [])

      refute cng.valid?

      assert {:tag, {"does not contain an Emoji tag", []}} in cng.errors
    end

    test "it is not valid when custom emoji have no tags", %{
      valid_emoji_react: valid_emoji_react
    } do
      without_emoji_content =
        valid_emoji_react
        |> Map.put("content", ":hello:")
        |> Map.put("tag", [])

      {:error, cng} = ObjectValidator.validate(without_emoji_content, [])

      refute cng.valid?

      assert {:tag, {"does not contain an Emoji tag", []}} in cng.errors
    end

    test "it is not valid when custom emoji doesn't match a shortcode format", %{
      valid_emoji_react: valid_emoji_react
    } do
      without_emoji_content =
        valid_emoji_react
        |> Map.put("content", "hello")
        |> Map.put("tag", [])

      {:error, cng} = ObjectValidator.validate(without_emoji_content, [])

      refute cng.valid?

      assert {:tag, {"does not contain an Emoji tag", []}} in cng.errors
    end
  end
end
