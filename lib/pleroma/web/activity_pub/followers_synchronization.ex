# Unfathomably follower collection synchronization
#
# File: followers_synchronization.ex
#
# Purpose:
#   Implement the signed digest and partial-collection protocol from FEP-8fcf.
#
# Responsibilities:
#   - build origin-scoped follower digests and delivery headers
#   - validate signed synchronization headers on incoming activities
#   - expose a bounded partial follower collection for a signed requester
#
# This file intentionally does not enable synchronization without an explicit
# managed-origin attestation or infer support from a software product name.

defmodule Pleroma.Web.ActivityPub.FollowersSynchronization do
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.Repo
  alias Pleroma.User

  @header "collection-synchronization"
  @maximum_header_bytes 2_048
  @header_pattern ~r/^collectionId="(?<collection>[^"]+)",\s*url="(?<url>[^"]+)",\s*digest="(?<digest>[0-9a-f]{64})"$/

  def enabled? do
    managed_origin = Config.get([__MODULE__, :managed_origin])

    Config.get([__MODULE__, :enabled], false) and is_binary(managed_origin) and
      origin(managed_origin) == origin(Pleroma.Web.Endpoint.url())
  end

  def outbound_header(
        %User{local: true, follower_address: followers} = actor,
        inbox
      )
      when is_binary(followers) and is_binary(inbox) do
    if enabled?() do
      ids = partial_follower_ids(actor, inbox)

      ~s(collectionId="#{followers}", url="#{synchronization_url(actor)}", digest="#{digest(ids)}")
    end
  end

  def outbound_header(_actor, _inbox), do: nil

  def synchronization_url(%User{ap_id: ap_id}), do: ap_id <> "/followers_synchronization"

  def partial_collection(%User{local: true} = actor, %User{} = requester) do
    ids = partial_follower_ids(actor, requester.ap_id)

    %{
      "id" => synchronization_url(actor),
      "type" => "OrderedCollection",
      "totalItems" => length(ids),
      "orderedItems" => ids
    }
  end

  def maybe_enqueue(conn, params) do
    with true <- enabled?(),
         true <- conn.assigns[:valid_signature] == true,
         %User{local: false} = sender <- conn.assigns[:user],
         sender_id when is_binary(sender_id) <- reference_id(params["actor"]),
         true <- sender_id == sender.ap_id,
         [header] <- Plug.Conn.get_req_header(conn, @header),
         true <- byte_size(header) <= @maximum_header_bytes,
         true <- header_covered?(conn),
         {:ok, values} <- parse_header(header),
         true <- values.collection == sender.follower_address,
         true <- same_origin?(values.collection, values.url),
         false <- digest(local_follower_ids(sender)) == values.digest do
      %{"actor" => sender.ap_id, "url" => values.url, "digest" => values.digest}
      |> Pleroma.Workers.FollowersSynchronizationWorker.new()
      |> Oban.insert()

      :ok
    else
      _ -> :ok
    end
  end

  def digest(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(<<0::256>>, fn id, accumulator ->
      xor_bytes(accumulator, :crypto.hash(:sha256, id))
    end)
    |> Base.encode16(case: :lower)
  end

  def local_follower_ids(%User{} = actor) do
    actor
    |> FollowingRelationship.followers_query()
    |> where([_relationship, follower], follower.local == true)
    |> select([_relationship, follower], follower.ap_id)
    |> Repo.all()
  end

  def parse_header(header) when is_binary(header) do
    case Regex.named_captures(@header_pattern, header) do
      %{"collection" => collection, "url" => url, "digest" => digest} ->
        if valid_https_url?(collection) and valid_https_url?(url) do
          {:ok, %{collection: collection, url: url, digest: digest}}
        else
          {:error, :invalid_url}
        end

      _ ->
        {:error, :invalid_header}
    end
  end

  def parse_header(_header), do: {:error, :invalid_header}

  def same_origin?(left, right), do: origin(left) != nil and origin(left) == origin(right)

  defp partial_follower_ids(actor, receiver) do
    FollowingRelationship.followers_ap_ids(actor)
    |> Enum.filter(&same_origin?(&1, receiver))
  end

  defp header_covered?(conn) do
    legacy_header_covered?(conn) or rfc9421_header_covered?(conn)
  end

  defp legacy_header_covered?(conn) do
    signature = HTTPSignatures.signature_for_conn(conn)
    headers = signature["headers"] || signature[:headers]
    is_binary(headers) and @header in (headers |> String.downcase() |> String.split())
  rescue
    _ -> false
  end

  defp rfc9421_header_covered?(conn) do
    conn
    |> Plug.Conn.get_req_header("signature-input")
    |> Enum.any?(fn value -> String.contains?(String.downcase(value), ~s("#{@header}")) end)
  end

  defp valid_https_url?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) -> true
      _ -> false
    end
  end

  defp origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        {scheme, String.downcase(host), port || URI.default_port(scheme)}

      _ ->
        nil
    end
  end

  defp origin(_value), do: nil

  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(id) when is_binary(id), do: id
  defp reference_id(_value), do: nil

  defp xor_bytes(left, right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.map(fn {left_byte, right_byte} -> Bitwise.bxor(left_byte, right_byte) end)
    |> :erlang.list_to_binary()
  end
end

# end of followers_synchronization.ex
