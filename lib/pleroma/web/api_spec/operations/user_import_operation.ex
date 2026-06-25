# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.UserImportOperation do
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Schema
  alias Pleroma.Web.ApiSpec.Schemas.ApiError

  import Pleroma.Web.ApiSpec.Helpers

  @spec open_api_operation(atom) :: Operation.t()
  def open_api_operation(action) do
    operation = String.to_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def follow_operation do
    %Operation{
      tags: ["Data import"],
      summary: "Import follows",
      operationId: "UserImportController.follow",
      requestBody: request_body("Parameters", import_request(), required: true),
      responses: %{
        200 => ok_response(),
        403 => Operation.response("Error", "application/json", ApiError),
        500 => Operation.response("Error", "application/json", ApiError)
      },
      security: [%{"oAuth" => ["write:follow"]}]
    }
  end

  def blocks_operation do
    %Operation{
      tags: ["Data import"],
      summary: "Import blocks",
      operationId: "UserImportController.blocks",
      requestBody: request_body("Parameters", import_request(), required: true),
      responses: %{
        200 => ok_response(),
        500 => Operation.response("Error", "application/json", ApiError)
      },
      security: [%{"oAuth" => ["write:blocks"]}]
    }
  end

  def mutes_operation do
    %Operation{
      tags: ["Data import"],
      summary: "Import mutes",
      operationId: "UserImportController.mutes",
      requestBody: request_body("Parameters", import_request(), required: true),
      responses: %{
        200 => ok_response(),
        500 => Operation.response("Error", "application/json", ApiError)
      },
      security: [%{"oAuth" => ["write:mutes"]}]
    }
  end

  def post_archive_imports_operation do
    %Operation{
      tags: ["Data import"],
      summary: "List post archive imports",
      operationId: "UserImportController.post_archive_imports",
      responses: %{
        200 =>
          Operation.response("Post archive imports", "application/json", %Schema{
            type: :array,
            items: post_archive_import()
          })
      },
      security: [%{"oAuth" => ["read:accounts"]}]
    }
  end

  def post_archive_operation do
    %Operation{
      tags: ["Data import"],
      summary: "Import posts from an ActivityPub archive",
      operationId: "UserImportController.post_archive",
      requestBody: request_body("Parameters", post_archive_request(), required: true),
      responses: %{
        200 =>
          Operation.response("Post archive import", "application/json", post_archive_import()),
        400 => Operation.response("Error", "application/json", ApiError),
        403 => Operation.response("Error", "application/json", ApiError),
        500 => Operation.response("Error", "application/json", ApiError)
      },
      security: [%{"oAuth" => ["write:statuses"]}]
    }
  end

  defp import_request do
    %Schema{
      type: :object,
      required: [:list],
      properties: %{
        list: %Schema{
          description:
            "STRING or FILE containing a whitespace-separated list of accounts to import.",
          anyOf: [
            %Schema{type: :string, format: :binary},
            %Schema{type: :string}
          ]
        }
      }
    }
  end

  defp post_archive_request do
    %Schema{
      type: :object,
      required: [:archive],
      properties: %{
        archive: %Schema{
          description: "ZIP archive containing actor.json and outbox.json.",
          type: :string,
          format: :binary
        }
      }
    }
  end

  defp post_archive_import do
    %Schema{
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        content_type: %Schema{type: :string},
        file_name: %Schema{type: :string},
        file_size: %Schema{type: :integer},
        state: %Schema{
          type: :string,
          enum: [
            "pending",
            "awaiting_review",
            "approved",
            "running",
            "complete",
            "failed",
            "rejected",
            "invalid"
          ]
        },
        processed_number: %Schema{type: :integer},
        total_items: %Schema{type: :integer},
        imported_count: %Schema{type: :integer},
        original_actor: %Schema{type: :string, nullable: true},
        error: %Schema{type: :string, nullable: true},
        approved_at: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string}
      }
    }
  end

  defp ok_response do
    Operation.response("Ok", "application/json", %Schema{type: :string, example: "ok"})
  end
end
