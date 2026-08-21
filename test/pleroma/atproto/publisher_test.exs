# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/publisher_test.exs
#
# Purpose:
#   Verify local ActivityPub post preparation for AT Protocol repositories.
#
# Responsibilities:
#   - recover explicit mentions from addressed local projection actors
#   - preserve authored plain-text spacing instead of rendered HTML artifacts
#
# This file intentionally does NOT contact a PDS or exercise credentials.

defmodule Pleroma.ATProto.PublisherTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  require Pleroma.Constants

  alias Pleroma.ATProto.Identity
  alias Pleroma.ATProto.Publisher
  alias Pleroma.Repo

  test "publishes an explicitly addressed Bluesky projection as a native mention" do
    projection = insert(:user, local: true, nickname: "atproto_alice")

    %Identity{}
    |> Identity.changeset(%{
      user_id: projection.id,
      did: "did:plc:alice",
      handle: "alice.example"
    })
    |> Repo.insert!()

    data = %{
      "actor" => "https://local.example/users/author",
      "content" =>
        ~s(hello <span class="h-card"><a class="mention" href="#{projection.ap_id}">@atproto_alice</a></span> there),
      "source" => %{
        "content" => "hello @atproto_alice there",
        "mediaType" => "text/plain"
      },
      "tag" => [],
      "to" => [Pleroma.Constants.as_public(), projection.ap_id]
    }

    assert {"hello @alice.example there", [facet]} = Publisher.prepare_rich_text(data)

    assert facet["features"] == [
             %{
               "$type" => "app.bsky.richtext.facet#mention",
               "did" => "did:plc:alice"
             }
           ]

    assert facet["index"] == %{"byteStart" => 6, "byteEnd" => 20}
  end
end

# end of test/pleroma/atproto/publisher_test.exs
