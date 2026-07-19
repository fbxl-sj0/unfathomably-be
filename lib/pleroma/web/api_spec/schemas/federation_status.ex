# Pleroma: federation status OpenAPI schema
# -----------------------------------------
#
# File: federation_status.ex
#
# Purpose:
#
#     Describe the client-safe local federation-policy status attached to
#     accounts and returned by the federation status endpoint.
#
# Responsibilities:
#
#     * keep the documented API shape aligned with Pleroma.FederationStatus
#     * identify nullable policy details without making clients guess
#     * expose the finite severity values used by frontend controls
#
# This file intentionally does NOT contain:
#
#     * federation-policy evaluation
#     * remote host probing
#     * response rendering logic

defmodule Pleroma.Web.ApiSpec.Schemas.FederationStatus do
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FederationStatus",
    description: "Local federation-policy status for a remote host or actor",
    type: :object,
    required: [:host, :known, :defederated, :direction, :severity, :reason, :message],
    properties: %{
      host: %Schema{type: :string, nullable: true},
      known: %Schema{type: :boolean},
      defederated: %Schema{type: :boolean},
      direction: %Schema{type: :string, nullable: true},
      severity: %Schema{
        type: :string,
        enum: ["none", "reject", "accept_list", "quarantine"]
      },
      reason: %Schema{type: :string, nullable: true},
      message: %Schema{type: :string, nullable: true}
    },
    example: %{
      "host" => "blocked.example",
      "known" => true,
      "defederated" => true,
      "direction" => "local_policy",
      "severity" => "reject",
      "reason" => "Federation paused",
      "message" => "Federation paused"
    }
  })
end

# end of lib/pleroma/web/api_spec/schemas/federation_status.ex
