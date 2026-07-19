# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# Code based on CreateChatMessageValidator
# NOTES
# - doesn't embed, will only get the object id
defmodule Pleroma.Web.ActivityPub.ObjectValidators.CreateGenericValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

  require Pleroma.Constants

  @primary_key false
  @addressing_fields ~w[to cc bto bcc audience]

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:expires_at, ObjectValidators.DateTime)

    # Should be moved to object, done for CommonAPI.Utils.make_context
    field(:context, :string)
  end

  def cast_data(data, meta \\ []) do
    data = fix(data, meta)

    %__MODULE__{}
    |> changeset(data)
  end

  def cast_and_apply(data) do
    data
    |> cast_data
    |> apply_action(:insert)
  end

  def cast_and_validate(data, meta \\ []) do
    data
    |> cast_data(meta)
    |> validate_data(meta)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, __schema__(:fields))
  end

  # Wanderer puts a public Trail's audience on the outer Create only.  The
  # inbox controller may then splice its local recipient into the embedded
  # object before validation, together with the producer's existing outer cc.
  # Copy the outer audience into an absent, empty, or trusted-delivery-only
  # object audience before the object is cast, but keep only public and
  # producer-owned recipients.  Arbitrary remote actors must still be rejected
  # by the ordinary Create addressing comparison.
  def inherit_public_object_addressing(object, activity)
      when is_map(object) and is_map(activity) do
    if inheritable_object_addressing?(object) and public_activity?(activity) do
      Enum.reduce(@addressing_fields, object, fn field, addressed_object ->
        recipients =
          activity[field]
          |> List.wrap()
          |> Enum.filter(&safe_inherited_public_recipient?(&1, object))

        Map.put(addressed_object, field, recipients)
      end)
    else
      object
    end
  end

  def inherit_public_object_addressing(object, _activity), do: object

  # CommonFixes.fix_activity_addressing adapted for Create specific behavior
  defp fix_addressing(data, object) do
    data =
      case User.get_cached_by_ap_id(data["actor"]) do
        %User{follower_address: follower_collection} ->
          data
          |> fix_create_recipients(object, follower_collection)
          |> Transmogrifier.fix_implicit_addressing(follower_collection)

        _ ->
          fix_create_recipients(data, object, nil)
      end

    data
    |> fix_equivalent_public_recipient_partition(object)
    |> fix_public_local_delivery_recipients(object)
  end

  defp fix_create_recipients(data, object, follower_collection) do
    data
    |> CommonFixes.cast_and_filter_recipients("to", follower_collection, object["to"])
    |> CommonFixes.cast_and_filter_recipients("cc", follower_collection, object["cc"])
    |> CommonFixes.cast_and_filter_recipients("bto", follower_collection, object["bto"])
    |> CommonFixes.cast_and_filter_recipients("bcc", follower_collection, object["bcc"])
    |> CommonFixes.cast_and_filter_recipients("audience", follower_collection, object["audience"])
  end

  # Lemmy-family producers may put a community in Create.cc while putting the
  # same community in object.to.  The delivery audience is unchanged, but an
  # exact field-by-field comparison rejects the post.  Normalize to the
  # object's partition only when the combined public recipient set is equal;
  # an activity that adds or removes any recipient still fails validation.
  defp fix_equivalent_public_recipient_partition(data, object) do
    if public_recipient_set(data) == public_recipient_set(object) do
      data
      |> Map.put("to", List.wrap(object["to"]))
      |> Map.put("cc", List.wrap(object["cc"]))
    else
      data
    end
  end

  defp public_recipient_set(data) do
    ["to", "cc"]
    |> Enum.flat_map(fn field -> List.wrap(data[field]) end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  # Gancio sends a public Event once through the shared inbox and once to each
  # follower inbox.  Mobilizon likewise addresses public group content to its
  # member and follower collections on the outer Create.  ZenPub addresses a
  # public Document to its collection context but omits addressing from the
  # embedded object.  Those extra addresses are delivery hints, not a different
  # object audience.  Discard them only for public objects and only when every
  # added recipient is a local actor, an exact same-origin object context, or a
  # producer-owned members/followers collection.  Arbitrary remote actors and
  # private objects remain strict failures.  The narrowly bounded absent or
  # local-only object case is handled before casting by
  # inherit_public_object_addressing/2.
  defp fix_public_local_delivery_recipients(data, object) do
    activity_recipients = public_recipient_set(data)
    object_recipients = public_recipient_set(object)
    added_recipients = MapSet.difference(activity_recipients, object_recipients)

    if MapSet.member?(object_recipients, Pleroma.Constants.as_public()) and
         MapSet.subset?(object_recipients, activity_recipients) and
         MapSet.size(added_recipients) > 0 and
         Enum.all?(added_recipients, &trusted_public_delivery_recipient?(&1, object)) do
      data
      |> Map.put("to", List.wrap(object["to"]))
      |> Map.put("cc", List.wrap(object["cc"]))
    else
      data
    end
  end

  defp local_actor?(ap_id) when is_binary(ap_id) do
    match?(%User{local: true}, User.get_cached_by_ap_id(ap_id))
  end

  defp local_actor?(_ap_id), do: false

  defp trusted_public_delivery_recipient?(ap_id, object) do
    local_actor?(ap_id) or producer_delivery_recipient?(ap_id, object)
  end

  defp producer_delivery_recipient?(ap_id, object) when is_binary(ap_id) do
    producers =
      [object["actor"], object["attributedTo"]]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&is_binary/1)

    contexts =
      object["context"]
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    producer_hosts =
      producers
      |> Enum.map(&uri_host/1)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    recipient_host = uri_host(ap_id)
    producer_actor = ap_id in producers
    producer_context = ap_id in contexts
    producer_collection = String.ends_with?(ap_id, ["/followers", "/members"])

    is_binary(recipient_host) and MapSet.member?(producer_hosts, recipient_host) and
      (producer_actor or producer_context or producer_collection)
  end

  defp producer_delivery_recipient?(_ap_id, _object), do: false

  defp inheritable_object_addressing?(object) do
    Enum.all?(@addressing_fields, fn field ->
      object
      |> Map.get(field)
      |> List.wrap()
      |> Enum.all?(&trusted_existing_object_delivery_recipient?(&1, object))
    end)
  end

  defp trusted_existing_object_delivery_recipient?(recipient, object) do
    local_actor?(recipient) or producer_delivery_recipient?(recipient, object)
  end

  defp public_activity?(activity) do
    activity
    |> public_recipient_set()
    |> Enum.any?(&public_recipient?/1)
  end

  defp safe_inherited_public_recipient?(recipient, object) when is_binary(recipient) do
    public_recipient?(recipient) or producer_delivery_recipient?(recipient, object)
  end

  defp safe_inherited_public_recipient?(_recipient, _object), do: false

  defp public_recipient?(recipient) do
    recipient in [Pleroma.Constants.as_public(), "Public", "as:Public"]
  end

  def fix(data, meta) do
    object = meta[:object_data]

    data
    |> CommonFixes.fix_actor()
    |> Map.put("context", object["context"])
    |> fix_addressing(object)
  end

  defp validate_data(cng, meta) do
    object = meta[:object_data]

    cng
    |> validate_required([:actor, :type, :object, :to, :cc])
    |> validate_inclusion(:type, ["Create"])
    |> CommonValidations.validate_actor_presence()
    |> validate_actors_match(object)
    |> validate_context_match(object)
    |> validate_addressing_match(object)
    |> validate_object_nonexistence()
    |> validate_object_containment()
  end

  def validate_object_containment(cng) do
    actor = get_field(cng, :actor)

    cng
    |> validate_change(:object, fn :object, object_id ->
      object_id_host = uri_host(object_id)
      actor_host = uri_host(actor)

      if is_binary(object_id_host) and object_id_host == actor_host do
        []
      else
        [{:object, "The host of the object id doesn't match with the host of the actor"}]
      end
    end)
  end

  def validate_object_nonexistence(cng) do
    cng
    |> validate_change(:object, fn :object, object_id ->
      if Object.get_cached_by_ap_id(object_id) do
        [{:object, "The object to create already exists"}]
      else
        []
      end
    end)
  end

  def validate_actors_match(cng, object) do
    attributed_to = object["attributedTo"] || object["actor"]

    cng
    |> validate_change(:actor, fn :actor, actor ->
      if actor == attributed_to do
        []
      else
        [{:actor, "Actor doesn't match with object attributedTo"}]
      end
    end)
  end

  def validate_context_match(cng, %{"context" => object_context}) do
    cng
    |> validate_change(:context, fn :context, context ->
      if context == object_context do
        []
      else
        [{:context, "context field not matching between Create and object (#{object_context})"}]
      end
    end)
  end

  def validate_addressing_match(cng, object) do
    [:to, :cc, :bcc, :bto, :audience]
    |> Enum.reduce(cng, fn field, cng ->
      object_data = object[to_string(field)]

      validate_change(cng, field, fn field, data ->
        if data == object_data do
          []
        else
          [{field, "field doesn't match with object (#{inspect(object_data)})"}]
        end
      end)
    end)
  end

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end

  defp uri_host(_), do: nil
end
