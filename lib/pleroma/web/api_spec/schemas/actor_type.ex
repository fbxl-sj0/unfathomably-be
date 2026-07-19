# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ApiSpec.Schemas.ActorType do
  require Pleroma.Constants
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ActorType",
    type: :string,
    enum: Pleroma.Constants.actor_types()
  })
end
