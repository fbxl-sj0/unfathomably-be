defmodule Pleroma.Web.LemmyAPI.CommunityController do
  use Pleroma.Web, :controller

  import Ecto.Query

  alias Pleroma.Repo
  alias Pleroma.User

  @default_limit 50
  @max_limit 100

  def list(conn, params) do
    communities =
      params
      |> community_query()
      |> Repo.all()
      |> Enum.map(&community_view/1)

    json(conn, %{communities: communities})
  end

  defp community_query(params) do
    User
    |> where(
      [user],
      user.local == true and
        user.actor_type == "Group" and
        user.is_active == true and
        user.invisible == false and
        user.is_discoverable == true
    )
    |> restrict_type(params)
    |> sort(params)
    |> page(params)
  end

  defp restrict_type(query, %{"type_" => type}) when type in ["Subscribed", "Moderator"] do
    from(user in query, where: false)
  end

  defp restrict_type(query, _params), do: query

  defp sort(query, %{"sort" => "Old"}) do
    from(user in query, order_by: [asc: user.inserted_at, asc: user.id])
  end

  defp sort(query, %{"sort" => "New"}) do
    from(user in query, order_by: [desc: user.inserted_at, desc: user.id])
  end

  defp sort(query, _params) do
    from(user in query, order_by: [desc: user.updated_at, desc: user.id])
  end

  defp page(query, params) do
    page = positive_integer(params["page"], 1)
    limit = params["limit"] |> positive_integer(@default_limit) |> min(@max_limit)

    from(user in query, limit: ^limit, offset: ^((page - 1) * limit))
  end

  defp community_view(group) do
    published_at = iso8601(group.inserted_at)
    updated_at = iso8601(group.updated_at)

    %{
      community: %{
        id: group.id,
        name: group.nickname,
        title: group.name || group.nickname,
        description: group.raw_bio || group.bio || "",
        removed: false,
        published: published_at,
        updated: updated_at,
        deleted: false,
        nsfw: false,
        actor_id: group.ap_id,
        local: true,
        icon: nil,
        banner: nil,
        hidden: false,
        posting_restricted_to_mods: !!group.posting_restricted_to_mods,
        instance_id: 1,
        visibility: "Public"
      },
      subscribed: "NotSubscribed",
      blocked: false,
      counts: %{
        community_id: group.id,
        subscribers: group.follower_count || 0,
        posts: group.note_count || 0,
        comments: 0,
        published: published_at,
        users_active_day: 0,
        users_active_week: 0,
        users_active_month: 0,
        users_active_half_year: 0
      }
    }
  end

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp iso8601(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil
end
