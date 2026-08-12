# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedTargetControllerTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  alias Pleroma.Instances.Instance

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/discovery/targets" do
    setup do: oauth_access(["read:accounts", "read:follows"])

    test "returns ranked groups and sources in the shared discovery envelope", %{conn: conn} do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "shared@forum.example",
          ap_id: "https://forum.example/c/shared",
          name: "Shared Target"
        )

      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "shared@publisher.example",
          ap_id: "https://publisher.example/wp-json/activitypub/1.0/actors/shared",
          name: "Shared Target"
        )

      native_sources =
        [
          {"bonfire valueflows", "coordination"},
          {"castling", "games"},
          {"forgefed", "development"},
          {"gancio", "events"},
          {"manyfold", "models"},
          {"mobilizon", "events"},
          {"mutual aid", "coordination"},
          {"neodb", "culture"},
          {"vervis", "development"},
          {"wanderer", "routes"},
          {"zenpub", "publishing"}
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {{software_name, platform_family}, index} ->
          host = "native#{index}.example"

          insert(:instance,
            host: host,
            metadata: %Instance.Pleroma.Instances.Metadata{
              software_name: software_name,
              software_version: "1.0.0"
            }
          )

          user =
            insert(:user,
              actor_type: "Person",
              local: false,
              nickname: "shared@#{host}",
              ap_id: "https://#{host}/users/shared",
              name: "Shared Target"
            )

          {user, platform_family}
        end)

      profile =
        insert(:user,
          actor_type: "Person",
          local: false,
          nickname: "shared@profile.example",
          ap_id: "https://profile.example/users/shared",
          name: "Shared Target"
        )

      response =
        conn
        |> get("/api/v1/discovery/targets?q=shared")
        |> json_response(200)

      assert Enum.map(response, & &1["target_type"]) |> MapSet.new() ==
               MapSet.new(["group", "source"])

      assert %{"target_kind" => _, "target_type" => "group"} =
               Enum.find(response, &(&1["id"] == to_string(group.id)))

      assert %{"source_profile" => _, "target_type" => "source"} =
               Enum.find(response, &(&1["id"] == to_string(source.id)))

      for {native_source, platform_family} <- native_sources do
        assert %{
                 "platform_family" => ^platform_family,
                 "source_profile" => "native_publisher",
                 "target_type" => "source"
               } = Enum.find(response, &(&1["id"] == to_string(native_source.id)))
      end

      refute Enum.any?(response, &(&1["id"] == to_string(profile.id)))
    end
  end
end
