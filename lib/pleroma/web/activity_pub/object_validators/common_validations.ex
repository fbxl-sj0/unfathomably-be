# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations do
  import Ecto.Changeset

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ReplyPolicy
  alias Pleroma.Web.ActivityPub.Visibility

  @spec validate_any_presence(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_any_presence(cng, fields) do
    non_empty =
      fields
      |> Enum.map(fn field -> get_field(cng, field) end)
      |> Enum.any?(fn
        nil -> false
        [] -> false
        _ -> true
      end)

    if non_empty do
      cng
    else
      fields
      |> Enum.reduce(cng, fn field, cng ->
        cng
        |> add_error(field, "none of #{inspect(fields)} present")
      end)
    end
  end

  @spec validate_actor_presence(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_actor_presence(cng, options \\ []) do
    field_name = Keyword.get(options, :field_name, :actor)

    cng
    |> validate_change(field_name, fn field_name, actor_ref ->
      case actor_ref |> ap_id() |> User.get_cached_by_ap_id() do
        %User{is_active: false} ->
          [{field_name, "user is deactivated"}]

        %User{} ->
          []

        _ ->
          [{field_name, "can't find user"}]
      end
    end)
  end

  @spec validate_object_presence(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_object_presence(cng, options \\ []) do
    field_name = Keyword.get(options, :field_name, :object)
    allowed_types = Keyword.get(options, :allowed_types, false)

    cng
    |> validate_change(field_name, fn field_name, object_ref ->
      object_id = ap_id(object_ref)

      object =
        object_id && (Object.get_cached_by_ap_id(object_id) || Activity.get_by_ap_id(object_id))

      cond do
        !object ->
          [{field_name, "can't find object"}]

        allowed_types && object.data["type"] not in allowed_types ->
          [{field_name, "object not in allowed types"}]

        true ->
          []
      end
    end)
  end

  @doc "Rejects an interaction when its actor cannot see the referenced object."
  @spec validate_object_visibility(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_object_visibility(cng, options \\ []) do
    actor_field = Keyword.get(options, :actor_field, :actor)
    object_field = Keyword.get(options, :field_name, :object)
    actor_id = get_field(cng, actor_field) |> ap_id()

    cng
    |> validate_change(object_field, fn object_field, object_ref ->
      object_id = ap_id(object_ref)

      object =
        object_id && (Object.get_cached_by_ap_id(object_id) || Activity.get_by_ap_id(object_id))

      with %User{} = actor <- User.get_cached_by_ap_id(actor_id),
           object when not is_nil(object) <- object,
           false <- Visibility.visible_for_user?(object, actor) do
        [{object_field, "object is not visible to actor"}]
      else
        _ -> []
      end
    end)
  end

  @doc "Rejects protected replies whose recipients are broader than their parent audience."
  @spec validate_reply_scope(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_reply_scope(cng, options \\ []) do
    field_name = Keyword.get(options, :field_name, :inReplyTo)

    validate_change(cng, field_name, fn field_name, parent_ref ->
      parent_id = ap_id(parent_ref)
      parent = parent_id && Object.get_cached_by_ap_id(parent_id)
      child_recipients = changeset_recipient_ids(cng)

      case parent do
        %Object{} = parent ->
          validate_parent_audience(cng, field_name, parent, child_recipients)

        nil ->
          if protected_recipient_set?(child_recipients) do
            [{field_name, "protected reply parent is unavailable"}]
          else
            []
          end
      end
    end)
  end

  @doc "Rejects replies below a locked object unless the actor manages its local group."
  @spec validate_reply_open(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_reply_open(cng, options \\ []) do
    field_name = Keyword.get(options, :field_name, :inReplyTo)

    validate_change(cng, field_name, fn field_name, parent_ref ->
      case ReplyPolicy.allowed?(parent_ref, get_field(cng, :actor)) do
        :ok -> []
        {:error, :locked} -> [{field_name, "reply thread is locked"}]
      end
    end)
  end

  @spec validate_object_or_user_presence(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_object_or_user_presence(cng, options \\ []) do
    field_name = Keyword.get(options, :field_name, :object)
    options = Keyword.put(options, :field_name, field_name)

    actor_cng =
      cng
      |> validate_actor_presence(options)

    object_cng =
      cng
      |> validate_object_presence(options)

    if actor_cng.valid?, do: actor_cng, else: object_cng
  end

  @spec validate_host_match(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_host_match(cng, fields \\ [:id, :actor]) do
    if same_domain?(cng, fields) do
      cng
    else
      fields
      |> Enum.reduce(cng, fn field, cng ->
        cng
        |> add_error(field, "hosts of #{inspect(fields)} aren't matching")
      end)
    end
  end

  @spec validate_fields_match(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_fields_match(cng, fields) do
    if map_unique?(cng, fields) do
      cng
    else
      fields
      |> Enum.reduce(cng, fn field, cng ->
        cng
        |> add_error(field, "Fields #{inspect(fields)} aren't matching")
      end)
    end
  end

  defp map_unique?(cng, fields, func \\ & &1) do
    Enum.reduce_while(fields, nil, fn field, acc ->
      value =
        cng
        |> get_field(field)
        |> func.()

      case {value, acc} do
        {value, nil} -> {:cont, value}
        {value, value} -> {:cont, value}
        _ -> {:halt, false}
      end
    end)
  end

  @spec same_domain?(Ecto.Changeset.t(), [atom()]) :: boolean()
  def same_domain?(cng, fields \\ [:actor, :object]) do
    hosts =
      Enum.map(fields, fn field ->
        cng
        |> get_field(field)
        |> uri_host()
      end)

    Enum.all?(hosts, &is_binary/1) && hosts |> Enum.uniq() |> length() == 1
  end

  # This figures out if a user is able to create, delete or modify something
  # based on the domain and superuser status
  @spec validate_modification_rights(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_modification_rights(cng, privilege) do
    actor = User.get_cached_by_ap_id(get_field(cng, :actor))

    if User.privileged?(actor, privilege) || same_domain?(cng) do
      cng
    else
      cng
      |> add_error(:actor, "is not allowed to modify object")
    end
  end

  defp ap_id(ap_id) when is_binary(ap_id), do: ap_id
  defp ap_id(%{"id" => ap_id}) when is_binary(ap_id), do: ap_id
  defp ap_id(_), do: nil

  defp validate_parent_audience(cng, field_name, parent, child_recipients) do
    if Visibility.get_visibility(parent) in ["private", "direct"] do
      parent_recipients = object_recipient_ids(parent)
      parent_actor = ap_id(parent.data["actor"] || parent.data["attributedTo"])
      child_actor = get_field(cng, :actor) |> ap_id()

      allowed_recipients =
        [parent_actor, child_actor | parent_recipients]
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      unexpected =
        child_recipients
        |> MapSet.new()
        |> MapSet.difference(allowed_recipients)

      if MapSet.size(unexpected) == 0 do
        []
      else
        [{field_name, "reply audience is broader than parent audience"}]
      end
    else
      []
    end
  end

  defp protected_recipient_set?(recipients) do
    recipients != [] and Pleroma.Constants.as_public() not in recipients
  end

  defp changeset_recipient_ids(cng) do
    [:to, :cc, :bto, :bcc, :audience]
    |> Enum.flat_map(fn field -> recipient_ids(get_field(cng, field)) end)
    |> Enum.uniq()
  end

  defp object_recipient_ids(%Object{data: data}) do
    ~w[to cc bto bcc audience]
    |> Enum.flat_map(fn field -> recipient_ids(data[field]) end)
    |> Enum.uniq()
  end

  defp recipient_ids(values) when is_list(values),
    do: values |> Enum.flat_map(&recipient_ids/1) |> Enum.uniq()

  defp recipient_ids(value) when is_binary(value), do: [value]
  defp recipient_ids(%{"id" => value}) when is_binary(value), do: [value]
  defp recipient_ids(_value), do: []

  defp uri_host(%{"id" => uri}) when is_binary(uri), do: uri_host(uri)

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end

  defp uri_host(_), do: nil
end
