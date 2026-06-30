# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.EventHandlingTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  require Pleroma.Constants

  alias Pleroma.Object.Fetcher

  test "Mobilizon Event object" do
    Tesla.Mock.mock(fn
      %{url: "https://mobilizon.org/events/252d5816-00a3-4a89-a66f-15bf65c33e39"} ->
        %Tesla.Env{
          status: 200,
          body: File.read!("test/fixtures/tesla_mock/mobilizon.org-event.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      %{url: "https://mobilizon.org/@tcit"} ->
        %Tesla.Env{
          status: 200,
          body: File.read!("test/fixtures/tesla_mock/mobilizon.org-user.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    assert {:ok, object} =
             Fetcher.fetch_object_from_id(
               "https://mobilizon.org/events/252d5816-00a3-4a89-a66f-15bf65c33e39"
             )

    assert object.data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
    assert object.data["cc"] == ["https://mobilizon.org/@tcit/followers"]

    assert object.data["url"] ==
             "https://mobilizon.org/events/252d5816-00a3-4a89-a66f-15bf65c33e39"

    assert object.data["published"] == "2019-12-17T11:33:56Z"
    assert object.data["name"] == "Mobilizon Launching Party"
    assert object.data["startTime"] == "2019-12-18T13:00:00Z"
    assert object.data["endTime"] == "2019-12-18T14:00:00Z"
  end

  test "Gancio Event object with a string place address" do
    actor_url = "https://gancio.example/federation/u/gancio"
    event_url = "https://gancio.example/federation/m/6777"

    actor = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url,
      "type" => "Application",
      "preferredUsername" => "gancio",
      "name" => "Gancio",
      "inbox" => actor_url <> "/inbox",
      "outbox" => actor_url <> "/outbox",
      "followers" => actor_url <> "/followers",
      "publicKey" => %{
        "id" => actor_url <> "#main-key",
        "owner" => actor_url,
        "publicKeyPem" => """
        -----BEGIN RSA PUBLIC KEY-----
        MIIBCgKCAQEAtzuZFviv5f12SuA0wZFMuwKS8RIlT3IjPCMLRDhiorZeV3UJ1lik
        DYO6mEh22KDXYgJtNVSYGF0Q5LJivgcvuvU+VQ048iTB1B2x0rHMr47KPByPjfVb
        KDeHt6fkHcLY0JK8UkIxW542wXAg4jX5w3gJi3pgTQrCT8VNyPbH1CaA0uW//9jc
        qzZQVFzpfdJoVOM9E3Urc/u58HC4xOptlM7+B/594ZI9drYwy5m+ZxHwlQUYCva4
        34dvwsfOGxkQyIrzXoep80EnWnFpYCLMcCiz+sEhPYxqLgNE+Cmn/6pv7SIscz6p
        eVlQXIchdw+J4yl07paJDkFc6CNTCmaIHQIDAQAB
        -----END RSA PUBLIC KEY-----
        """
      }
    }

    event = %{
      "id" => event_url,
      "type" => "Event",
      "name" => "Stanze Fredde Fest 3",
      "url" => "https://gancio.example/event/stanze-fredde-fest-3",
      "startTime" => "2026-11-21T17:00:00.000+01:00",
      "location" => [
        %{
          "type" => "VirtualLocation",
          "url" => "https://gancio.example/stream"
        },
        %{
          "id" => "https://gancio.example/federation/p/5",
          "type" => "Place",
          "name" => "El Paso Occupato",
          "address" => "Via Passo Buole, 47, Torino",
          "latitude" => 45.02343145,
          "longitude" => 7.65609886065984
        }
      ],
      "published" => "2026-05-12T20:01:23.951Z",
      "updated" => "2026-05-12T20:01:23.951Z",
      "attributedTo" => actor_url,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor_url <> "/followers"],
      "content" => "<p>Stanze Fredde e un'etichetta indipendente.</p>",
      "summary" => "<p>El Paso Occupato, sabato 21 novembre alle ore 17:00 CET</p>"
    }

    Tesla.Mock.mock(fn
      %{url: ^event_url} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(event),
          headers: HttpRequestMock.activitypub_object_headers()
        }

      %{url: ^actor_url} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(actor),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    assert {:ok, object} = Fetcher.fetch_object_from_id(event_url)

    assert object.data["type"] == "Event"
    assert object.data["location"]["address"]["type"] == "PostalAddress"
    assert object.data["location"]["address"]["streetAddress"] == "Via Passo Buole, 47, Torino"
  end
end
