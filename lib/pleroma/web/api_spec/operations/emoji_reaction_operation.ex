# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.EmojiReactionOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.Schemas.Account
  alias Pleroma.Web.ApiSpec.Schemas.ApiError
  alias Pleroma.Web.ApiSpec.Schemas.FlakeID
  alias Pleroma.Web.ApiSpec.Schemas.Status

  def open_api_operation(action) do
    operation = String.to_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def index_operation do
    %Operation{
      tags: ["Emoji reactions"],
      summary:
        "Get an object of emoji to account mappings with accounts that reacted to the post",
      parameters: [
        Operation.parameter(:id, :path, FlakeID, "Status ID", required: true),
        Operation.parameter(:emoji, :path, :string, "Filter by a single unicode emoji",
          required: nil
        ),
        Operation.parameter(
          :with_muted,
          :query,
          :boolean,
          "Include reactions from muted acccounts."
        )
      ],
      security: [%{"oAuth" => ["read:statuses"]}],
      operationId: "EmojiReactionController.index",
      responses: %{
        200 => array_of_reactions_response()
      }
    }
  end

  def create_operation do
    %Operation{
      tags: ["Emoji reactions"],
      summary: "React to a post with a unicode emoji",
      parameters: [
        Operation.parameter(:id, :path, FlakeID, "Status ID", required: true),
        Operation.parameter(:emoji, :path, :string, "A single character unicode emoji",
          required: true
        )
      ],
      security: [%{"oAuth" => ["write:statuses"]}],
      operationId: "EmojiReactionController.create",
      responses: %{
        200 => Operation.response("Status", "application/json", Status),
        400 => Operation.response("Bad Request", "application/json", ApiError)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["Emoji reactions"],
      summary: "Remove a reaction to a post with a unicode emoji",
      parameters: [
        Operation.parameter(:id, :path, FlakeID, "Status ID", required: true),
        Operation.parameter(:emoji, :path, :string, "A single character unicode emoji",
          required: true
        )
      ],
      security: [%{"oAuth" => ["write:statuses"]}],
      operationId: "EmojiReactionController.delete",
      responses: %{
        200 => Operation.response("Status", "application/json", Status)
      }
    }
  end

  def dislike_operation do
    dislike_change_operation("Dislike a status", "EmojiReactionController.dislike")
  end

  def undislike_operation do
    dislike_change_operation(
      "Remove a dislike from a status",
      "EmojiReactionController.undislike"
    )
  end

  def disliked_by_operation do
    %Operation{
      tags: ["Emoji reactions"],
      summary: "View accounts that disliked a status",
      parameters: [Operation.parameter(:id, :path, FlakeID, "Status ID", required: true)],
      security: [%{"oAuth" => ["read:statuses"]}],
      operationId: "EmojiReactionController.disliked_by",
      responses: %{
        200 =>
          Operation.response("Accounts", "application/json", %Schema{type: :array, items: Account})
      }
    }
  end

  defp dislike_change_operation(summary, operation_id) do
    %Operation{
      tags: ["Emoji reactions"],
      summary: summary,
      parameters: [Operation.parameter(:id, :path, FlakeID, "Status ID", required: true)],
      security: [%{"oAuth" => ["write:statuses"]}],
      operationId: operation_id,
      responses: %{
        200 => Operation.response("Status", "application/json", Status),
        400 => Operation.response("Bad Request", "application/json", ApiError)
      }
    }
  end

  defp array_of_reactions_response do
    Operation.response("Array of Emoji reactions", "application/json", %Schema{
      type: :array,
      items: emoji_reaction(),
      example: [emoji_reaction().example]
    })
  end

  defp emoji_reaction do
    %Schema{
      title: "EmojiReaction",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Emoji"},
        count: %Schema{type: :integer, description: "Count of reactions with this emoji"},
        me: %Schema{type: :boolean, description: "Did I react with this emoji?"},
        accounts: %Schema{
          type: :array,
          items: Account,
          description: "Array of accounts reacted with this emoji"
        }
      },
      example: %{
        "name" => "😱",
        "count" => 1,
        "me" => false,
        "accounts" => [Account.schema().example]
      }
    }
  end
end
