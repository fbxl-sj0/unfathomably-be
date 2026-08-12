# Unfathomably BE
# ----------------
#
# File: atproto/validation.ex
#
# Purpose:
#   Validate the identifiers that cross the AT Protocol trust boundary.
#
# Responsibilities:
#   - validate blessed AT Protocol DIDs and account handles
#   - validate repository collection NSIDs and record keys
#   - parse normalized record-level at:// URIs
#
# This file intentionally does NOT resolve identities, contact a PDS, or
# decide which records should be retained locally.

defmodule Pleroma.ATProto.Validation do
  @moduledoc false

  @maximum_did_bytes 2_048
  @handle_pattern ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @plc_did_pattern ~r/\Adid:plc:[a-z0-9._-]+\z/
  @nsid_pattern ~r/\A[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\.[a-zA-Z](?:[a-zA-Z0-9]{0,62})?\z/
  @record_key_pattern ~r/\A[A-Za-z0-9._:~-]+\z/

  def valid_did?("did:plc:" <> _rest = did) do
    byte_size(did) <= @maximum_did_bytes and Regex.match?(@plc_did_pattern, did)
  end

  def valid_did?("did:web:" <> host = did) do
    byte_size(did) <= @maximum_did_bytes and valid_handle?(host)
  end

  def valid_did?(_did), do: false

  def valid_handle?(handle) when is_binary(handle) do
    normalized = String.downcase(handle)

    normalized == handle and normalized != "handle.invalid" and
      Regex.match?(@handle_pattern, normalized)
  end

  def valid_handle?(_handle), do: false

  def valid_nsid?(nsid) when is_binary(nsid) and byte_size(nsid) <= 317,
    do: Regex.match?(@nsid_pattern, nsid)

  def valid_nsid?(_nsid), do: false

  def valid_record_key?(rkey) when is_binary(rkey) and byte_size(rkey) in 1..512 do
    rkey not in [".", ".."] and Regex.match?(@record_key_pattern, rkey)
  end

  def valid_record_key?(_rkey), do: false

  def split_record_uri("at://" <> path) do
    case String.split(path, "/", parts: 3) do
      [did, collection, rkey] ->
        if valid_did?(did) and valid_nsid?(collection) and valid_record_key?(rkey) do
          {:ok, did, collection, rkey}
        else
          {:error, :invalid_at_uri}
        end

      _parts ->
        {:error, :invalid_at_uri}
    end
  end

  def split_record_uri(_uri), do: {:error, :invalid_at_uri}
end

# end of atproto/validation.ex
