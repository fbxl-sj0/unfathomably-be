# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.PostArchiveImport do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query
  import Pleroma.Web.Gettext

  require Logger
  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.User.PostArchiveImport.State
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Workers.PostArchiveImportWorker

  @type policy :: :disabled | :moderated | :open
  @default_max_file_size 100 * 1024 * 1024
  @supported_create_objects ~w[Article Note Page Question Audio Video Image Event]

  schema "post_archive_imports" do
    field(:content_type, :string)
    field(:file_name, :string)
    field(:file_size, :integer, default: 0)
    field(:state, State, default: :invalid)
    field(:processed_number, :integer, default: 0)
    field(:total_items, :integer, default: 0)
    field(:imported_count, :integer, default: 0)
    field(:original_actor, :string)
    field(:error, :string)
    field(:approved_at, :naive_datetime_usec)

    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    belongs_to(:approved_by, User, type: FlakeId.Ecto.CompatType)

    timestamps()
  end

  def create(%User{} = user, %Plug.Upload{} = upload) do
    with :ok <- validate_policy(),
         {:ok, file_size} <- validate_upload(upload),
         {:ok, file_name} <- copy_upload(user, upload) do
      state = if policy() == :moderated, do: :awaiting_review, else: :pending

      result =
        %__MODULE__{}
        |> changeset(%{
          user_id: user.id,
          file_name: file_name,
          content_type: upload.content_type || "application/zip",
          file_size: file_size,
          state: state
        })
        |> Repo.insert()

      case result do
        {:ok, %__MODULE__{state: :pending} = import} ->
          with {:ok, _job} <- PostArchiveImportWorker.process(import) do
            {:ok, import}
          end

        other ->
          other
      end
    end
  end

  def approve(%__MODULE__{state: :awaiting_review} = import, %User{} = admin) do
    with {:ok, import} <-
           import
           |> changeset(%{
             state: :pending,
             approved_by_id: admin.id,
             approved_at: NaiveDateTime.utc_now(),
             error: nil
           })
           |> Repo.update(),
         {:ok, _job} <- PostArchiveImportWorker.process(import) do
      {:ok, import}
    end
  end

  def approve(%__MODULE__{}, %User{}), do: {:error, "Import is not awaiting review"}

  def reject(%__MODULE__{} = import, %User{} = admin, reason \\ nil) do
    result =
      import
      |> changeset(%{
        state: :rejected,
        approved_by_id: admin.id,
        approved_at: NaiveDateTime.utc_now(),
        error: reason || "Rejected by administrator"
      })
      |> Repo.update()

    with {:ok, import} <- result do
      cleanup(import)
      {:ok, import}
    end
  end

  def process(nil), do: {:error, :not_found}

  def process(%__MODULE__{} = import) do
    import = Repo.preload(import, :user)

    with {:ok, import} <- set_state(import, :running, %{processed_number: 0, error: nil}),
         {:ok, result} <- import_archive(import) do
      import
      |> changeset(%{
        state: :complete,
        processed_number: result.processed_number,
        total_items: result.total_items,
        imported_count: result.imported_count,
        original_actor: result.original_actor
      })
      |> Repo.update()
      |> tap(fn _ -> cleanup(import) end)
    else
      {:error, reason} ->
        message = inspect(reason)
        Logger.warning("Post archive import #{import.id} failed: #{message}")

        set_state(import, :failed, %{error: String.slice(message, 0, 2048)})
    end
  end

  def list(%User{id: user_id}) do
    __MODULE__
    |> where(user_id: ^user_id)
    |> order_by(desc: :id)
    |> Repo.all()
  end

  def list_reviewable do
    __MODULE__
    |> where([i], i.state in [:awaiting_review, :running, :failed])
    |> order_by(desc: :id)
    |> limit(100)
    |> Repo.all()
    |> Repo.preload([:user, :approved_by])
  end

  def get(id), do: Repo.get(__MODULE__, id)

  @spec policy() :: policy()
  def policy do
    case Config.get([__MODULE__, :policy], :disabled) do
      policy when policy in [:disabled, :moderated, :open] -> policy
      "disabled" -> :disabled
      "moderated" -> :moderated
      "open" -> :open
      _ -> :disabled
    end
  end

  def max_file_size do
    case Config.get([__MODULE__, :max_file_size], @default_max_file_size) do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_max_file_size
    end
  end

  def enabled?, do: policy() != :disabled

  def path(%__MODULE__{file_name: file_name}), do: path(file_name)

  def path(file_name) when is_binary(file_name) do
    dir = Config.get([__MODULE__, :dir]) || System.tmp_dir!()
    Path.join([dir, "post_archive_imports", file_name])
  end

  defp changeset(import, params) do
    import
    |> cast(params, [
      :user_id,
      :approved_by_id,
      :file_name,
      :content_type,
      :file_size,
      :state,
      :processed_number,
      :total_items,
      :imported_count,
      :original_actor,
      :error,
      :approved_at
    ])
    |> validate_required([:user_id, :file_name, :content_type, :file_size, :state])
  end

  defp validate_policy do
    if enabled?() do
      :ok
    else
      {:error, dgettext("errors", "Post archive imports are disabled")}
    end
  end

  defp validate_upload(%Plug.Upload{path: path, filename: filename}) do
    with :ok <- validate_extension(filename),
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- validate_size(size) do
      {:ok, size}
    end
  end

  defp validate_extension(filename) do
    if Path.extname(filename || "") == ".zip" do
      :ok
    else
      {:error, dgettext("errors", "Post archive imports must be ZIP files")}
    end
  end

  defp validate_size(size) when size <= 0 do
    {:error, dgettext("errors", "Post archive import file is empty")}
  end

  defp validate_size(size) do
    if size <= max_file_size() do
      :ok
    else
      {:error, dgettext("errors", "Post archive import file is too large")}
    end
  end

  defp copy_upload(%User{} = user, %Plug.Upload{path: source}) do
    rand_str = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    datetime = Calendar.NaiveDateTime.Format.iso8601_basic(NaiveDateTime.utc_now())
    file_name = "post-archive-import-#{user.nickname}-#{datetime}-#{rand_str}.zip"
    destination = path(file_name)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _} <- File.copy(source, destination) do
      {:ok, file_name}
    end
  end

  defp set_state(import, state, attrs) do
    import
    |> changeset(Map.merge(attrs, %{state: state}))
    |> Repo.update()
  end

  defp cleanup(%__MODULE__{} = import) do
    import
    |> path()
    |> File.rm()
    |> case do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp import_archive(%__MODULE__{} = import) do
    with {:ok, archive} <- read_archive(import),
         {:ok, actor} <- decode_json_file(archive, "actor.json"),
         {:ok, outbox} <- decode_json_file(archive, "outbox.json"),
         {:ok, items} <- outbox_items(outbox) do
      original_actor = actor["id"]
      total_items = length(items)

      {processed_number, imported_count} =
        Enum.reduce(items, {0, 0}, fn item, {processed, imported} ->
          imported =
            case import_item(item, import.user, original_actor) do
              {:ok, :imported} ->
                imported + 1

              {:ok, :skipped} ->
                imported

              {:error, reason} ->
                Logger.warning("Could not import archive item: #{inspect(reason)}")
                imported
            end

          processed = processed + 1

          if rem(processed, 100) == 0 do
            set_state(import, :running, %{processed_number: processed})
          end

          {processed, imported}
        end)

      {:ok,
       %{
         processed_number: processed_number,
         imported_count: imported_count,
         total_items: total_items,
         original_actor: original_actor
       }}
    end
  end

  defp read_archive(%__MODULE__{} = import) do
    import
    |> path()
    |> String.to_charlist()
    |> :zip.extract([:memory])
    |> case do
      {:ok, files} ->
        archive =
          Map.new(files, fn {name, content} ->
            {name |> to_string() |> Path.basename(), content}
          end)

        {:ok, archive}

      {:error, reason} ->
        {:error, {:zip, reason}}
    end
  end

  defp decode_json_file(archive, name) do
    with {:ok, content} <- Map.fetch(archive, name),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      :error -> {:error, {:missing_file, name}}
      {:error, reason} -> {:error, {:invalid_json, name, reason}}
    end
  end

  defp outbox_items(%{"orderedItems" => items}) when is_list(items), do: {:ok, items}
  defp outbox_items(%{"items" => items}) when is_list(items), do: {:ok, items}
  defp outbox_items(_), do: {:error, :missing_outbox_items}

  defp import_item(
         %{"type" => "Create", "object" => %{"type" => type} = object} = activity,
         user,
         original_actor
       )
       when type in @supported_create_objects do
    with true <- public?(activity, object),
         false <- already_imported?(user, activity, object),
         {:ok, activity_data} <- imported_create(activity, object, user, original_actor),
         {:ok, inserted} <- ActivityPub.insert(activity_data, false, false, true) do
      maybe_count_import(user, inserted)
      {:ok, :imported}
    else
      true -> {:ok, :skipped}
      false -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_item(%{"type" => "Announce", "object" => object} = activity, user, original_actor)
       when is_binary(object) do
    with true <- public?(activity, %{}),
         false <- already_imported?(user, activity, %{"id" => object}),
         {:ok, activity_data} <- imported_announce(activity, user, original_actor),
         {:ok, _inserted} <- ActivityPub.insert(activity_data, false, false, true) do
      {:ok, :imported}
    else
      true -> {:ok, :skipped}
      false -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_item(_, _, _), do: {:ok, :skipped}

  defp imported_create(activity, object, user, original_actor) do
    metadata = import_metadata(activity, object, original_actor)
    published = activity["published"] || object["published"] || Utils.make_date()
    {to, cc} = normalized_recipients(activity, object, user, original_actor)

    object =
      object
      |> Map.drop(["@context"])
      |> Map.put("id", Utils.generate_object_id())
      |> Map.put("actor", user.ap_id)
      |> Map.put("attributedTo", user.ap_id)
      |> Map.put("published", published)
      |> Map.put("to", to)
      |> Map.put("cc", cc)
      |> Map.put("_unfathomably_import", metadata)

    {:ok,
     activity
     |> Map.drop(["@context"])
     |> Map.put("id", Utils.generate_activity_id())
     |> Map.put("actor", user.ap_id)
     |> Map.put("published", published)
     |> Map.put("to", to)
     |> Map.put("cc", cc)
     |> Map.put("object", object)
     |> Map.put("_unfathomably_import", metadata)}
  end

  defp imported_announce(activity, user, original_actor) do
    metadata = import_metadata(activity, %{"id" => activity["object"]}, original_actor)
    published = activity["published"] || Utils.make_date()
    {to, cc} = normalized_recipients(activity, %{}, user, original_actor)

    {:ok,
     activity
     |> Map.drop(["@context"])
     |> Map.put("id", Utils.generate_activity_id())
     |> Map.put("actor", user.ap_id)
     |> Map.put("published", published)
     |> Map.put("to", to)
     |> Map.put("cc", cc)
     |> Map.put("_unfathomably_import", metadata)}
  end

  defp import_metadata(activity, object, original_actor) do
    %{
      "activity_id" => activity["id"],
      "object_id" => object["id"],
      "actor" => activity["actor"] || object["actor"] || original_actor,
      "archive_actor" => original_actor,
      "imported_at" => Utils.make_date()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalized_recipients(activity, object, user, original_actor) do
    to =
      activity
      |> Map.get("to", object["to"] || [Pleroma.Constants.as_public()])
      |> replace_recipients(user, original_actor)

    cc =
      activity
      |> Map.get("cc", object["cc"] || [user.follower_address])
      |> replace_recipients(user, original_actor)

    {to, cc}
  end

  defp replace_recipients(recipients, user, original_actor) do
    recipients
    |> List.wrap()
    |> Enum.flat_map(&recipient_value/1)
    |> Enum.map(&replace_recipient(&1, user, original_actor))
    |> Enum.uniq()
  end

  defp recipient_value(value) when is_binary(value), do: [value]
  defp recipient_value(%{"id" => id}) when is_binary(id), do: [id]
  defp recipient_value(%{"href" => href}) when is_binary(href), do: [href]
  defp recipient_value(values) when is_list(values), do: Enum.flat_map(values, &recipient_value/1)
  defp recipient_value(_), do: []

  defp replace_recipient(recipient, user, original_actor) when is_binary(original_actor) do
    cond do
      recipient == original_actor -> user.ap_id
      recipient == original_actor <> "/followers" -> user.follower_address
      true -> recipient
    end
  end

  defp replace_recipient(recipient, _user, _original_actor), do: recipient

  defp public?(activity, object) do
    public = Pleroma.Constants.as_public()

    [activity["to"], activity["cc"], object["to"], object["cc"]]
    |> Enum.flat_map(&recipient_value/1)
    |> Enum.member?(public)
  end

  defp already_imported?(user, activity, object) do
    old_activity_id = activity["id"]
    old_object_id = object["id"]

    Activity
    |> where(actor: ^user.ap_id)
    |> maybe_restrict_original_activity(old_activity_id)
    |> maybe_or_original_object(old_object_id)
    |> Repo.exists?()
  end

  defp maybe_restrict_original_activity(query, id) when is_binary(id) do
    where(query, [a], fragment("(?->'_unfathomably_import'->>'activity_id') = ?", a.data, ^id))
  end

  defp maybe_restrict_original_activity(query, _), do: where(query, [a], false)

  defp maybe_or_original_object(query, id) when is_binary(id) do
    or_where(query, [a], fragment("(?->'_unfathomably_import'->>'object_id') = ?", a.data, ^id))
  end

  defp maybe_or_original_object(query, _), do: query

  defp maybe_count_import(user, activity) do
    if Visibility.is_public?(activity) do
      User.increase_note_count(user)
    else
      {:ok, user}
    end
  end
end
