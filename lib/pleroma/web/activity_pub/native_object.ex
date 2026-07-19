# Unfathomably BE
# ----------------
#
# File: native_object.ex
#
# Purpose:
#   Build locally authored ActivityPub objects for the bounded presentation
#   families exposed by the Worlds frontend.
#
# Responsibilities:
#   - validate the small public authoring schema
#   - map each template to a fixed ActivityPub vocabulary and field set
#   - reuse normal post formatting, addressing, MRF, storage, and delivery
#
# This file intentionally does not accept arbitrary JSON-LD, fetch reference
# URLs, or implement object rendering.

defmodule Pleroma.Web.ActivityPub.NativeObject do
  @moduledoc """
  Creates safe, locally authored objects for the Worlds interface.

  The public API selects a template rather than supplying an ActivityPub type
  or field names. This keeps the JSON-LD trust boundary on the server while the
  resulting Create activity still follows the ordinary posting pipeline.
  """

  alias Pleroma.Formatter
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.CommonAPI.ActivityDraft

  @family_field "https://unfathomably.social/ns#family"
  @kind_field "https://unfathomably.social/ns#kind"
  @detail_field "https://unfathomably.social/ns#detail"
  @secondary_field "https://unfathomably.social/ns#secondary"
  @reference_field "https://unfathomably.social/ns#reference"

  @templates %{
    "books" => %{type: "Review", kind: "book_review"},
    "software" => %{type: "Ticket", kind: "software_ticket"},
    "models" => %{type: "Model", kind: "three_dimensional_model"},
    "markets" => %{type: "maid:Offer", kind: "market_offer"},
    "games" => %{type: "Game", kind: "game"},
    "routes" => %{type: "Route", kind: "route"},
    "culture" => %{type: "Movie", kind: "culture_item"},
    "coordination" => %{type: "ValueFlows:Proposal", kind: "coordination_proposal"},
    "publishing" => %{type: "Document", kind: "publication"}
  }

  @maximum_title_length 200
  @maximum_reference_length 2_048
  @maximum_detail_length 120
  @software_states ~w[open in_progress resolved closed]
  @route_difficulties ~w[easy moderate hard expert]
  @coordination_actions ~w[offer request propose coordinate]
  @visibility_values ~w[public unlisted private]

  @spec create(User.t(), map()) :: {:ok, Pleroma.Activity.t()} | {:error, term()}
  def create(%User{} = user, params) when is_map(params) do
    with {:ok, family, template} <- validate_template(param(params, :template)),
         {:ok, title} <- validate_required_text(param(params, :title), "Title", @maximum_title_length),
         {:ok, content} <- validate_required_text(param(params, :content), "Description", nil),
         {:ok, reference} <- validate_reference(param(params, :reference_url)),
         {:ok, detail} <- validate_detail(family, param(params, :detail)),
         {:ok, secondary} <- validate_secondary(family, detail, param(params, :secondary)),
         {:ok, visibility} <- validate_visibility(param(params, :visibility)),
         {:ok, draft} <-
           ActivityDraft.create(user, %{
             content_type: "text/plain",
             sensitive: false,
             spoiler_text: "",
             status: content,
             visibility: visibility
           }),
         object <- build_object(draft.object, user, family, template, title, reference, detail, secondary),
         recipients <- Enum.uniq(draft.to ++ draft.cc),
         {:ok, create_data, _meta} <- Builder.create(user, object, recipients),
         {:ok, activity, _meta} <- Pipeline.common_pipeline(create_data, local: true) do
      {:ok, activity}
    end
  end

  def create(_user, _params), do: {:error, "Invalid native object request"}

  defp build_object(object, user, family, template, title, reference, detail, secondary) do
    object
    |> Map.put("id", Utils.generate_object_id())
    |> Map.put("published", Utils.make_date())
    |> Map.put("type", template.type)
    |> Map.put("actor", user.ap_id)
    |> Map.put("attributedTo", user.ap_id)
    |> Map.put("name", Formatter.html_escape(title, "text/plain"))
    |> Map.put(@family_field, family)
    |> Map.put(@kind_field, template.kind)
    |> maybe_put(@detail_field, detail)
    |> maybe_put(@secondary_field, secondary)
    |> maybe_put(@reference_field, reference)
    |> put_template_fields(family, title, reference, detail, secondary)
  end

  defp put_template_fields(object, "books", _title, reference, detail, _secondary) do
    object |> maybe_put("book", reference) |> maybe_put("rating", detail)
  end

  defp put_template_fields(object, "software", _title, reference, detail, _secondary) do
    object |> maybe_put("target", reference) |> maybe_put("state", detail)
  end

  defp put_template_fields(object, "models", _title, reference, detail, _secondary) do
    object |> maybe_put("latestVersion", reference) |> maybe_put("version", detail)
  end

  defp put_template_fields(object, "markets", title, reference, detail, secondary) do
    object
    |> Map.put("pair:label", title)
    |> maybe_put("maid:offerOfResourceType", reference)
    |> maybe_put("price", detail)
    |> maybe_put("priceCurrency", secondary)
  end

  defp put_template_fields(object, "games", _title, reference, detail, _secondary) do
    object |> maybe_put("target", reference) |> maybe_put("state", detail)
  end

  defp put_template_fields(object, "routes", _title, reference, detail, secondary) do
    object
    |> maybe_put("target", reference)
    |> maybe_put("distance", detail)
    |> maybe_put("difficulty", secondary)
  end

  defp put_template_fields(object, "culture", _title, reference, detail, _secondary) do
    object |> maybe_put("target", reference) |> maybe_put("category", detail)
  end

  defp put_template_fields(object, "coordination", _title, reference, detail, _secondary) do
    object |> maybe_put("target", reference) |> maybe_put("action", detail)
  end

  defp put_template_fields(object, "publishing", title, reference, detail, _secondary) do
    object
    |> Map.put("author", object["actor"])
    |> Map.put("subject", title)
    |> maybe_put("relatedLink", reference)
    |> maybe_put("license", detail)
  end

  defp validate_template(value) when is_binary(value) do
    family = String.trim(value)

    case Map.fetch(@templates, family) do
      {:ok, template} -> {:ok, family, template}
      :error -> {:error, "Unsupported native object template"}
    end
  end

  defp validate_template(_value), do: {:error, "A native object template is required"}

  defp validate_required_text(value, label, maximum) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, "#{label} is required"}
      is_integer(maximum) and String.length(value) > maximum -> {:error, "#{label} is too long"}
      true -> {:ok, value}
    end
  end

  defp validate_required_text(_value, label, _maximum), do: {:error, "#{label} is required"}

  defp validate_reference(nil), do: {:ok, nil}
  defp validate_reference(""), do: {:ok, nil}

  defp validate_reference(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:ok, nil}
    else
      uri = URI.parse(value)

      if byte_size(value) <= @maximum_reference_length and uri.scheme in ["http", "https"] and
           is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) do
        {:ok, value}
      else
        {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}
      end
    end
  rescue
    URI.Error -> {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}
  end

  defp validate_reference(_value), do: {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}

  defp validate_detail("books", value) do
    case Integer.parse(to_string(value || "")) do
      {rating, ""} when rating in 1..5 -> {:ok, rating}
      _result -> {:error, "Rating must be a whole number from 1 to 5"}
    end
  end

  defp validate_detail("software", value),
    do: validate_enum(value, @software_states, "Ticket state", "open")

  defp validate_detail("markets", value) do
    with {:ok, price} <- validate_optional_text(value, "Price", @maximum_detail_length) do
      if is_nil(price) or Regex.match?(~r/^\d{1,9}(?:\.\d{1,2})?$/, price) do
        {:ok, price}
      else
        {:error, "Price must be a positive amount with at most two decimal places"}
      end
    end
  end

  defp validate_detail("routes", value) do
    with {:ok, distance} <- validate_optional_text(value, "Distance", @maximum_detail_length) do
      if is_nil(distance) or Regex.match?(~r/^\d{1,7}(?:\.\d{1,2})?\s*(?:km|mi|m)?$/i, distance) do
        {:ok, distance}
      else
        {:error, "Distance must be a number optionally followed by km, mi, or m"}
      end
    end
  end

  defp validate_detail("coordination", value),
    do: validate_enum(value, @coordination_actions, "Coordination action", "propose")

  defp validate_detail(_family, value), do: validate_optional_text(value, "Detail", @maximum_detail_length)

  defp validate_secondary("markets", nil, value), do: validate_optional_text(value, "Currency", 3)

  defp validate_secondary("markets", _price, value) when is_binary(value) do
    currency = value |> String.trim() |> String.upcase()

    if Regex.match?(~r/^[A-Z]{3}$/, currency) do
      {:ok, currency}
    else
      {:error, "Currency must be a three-letter code when a price is supplied"}
    end
  end

  defp validate_secondary("markets", _price, _value),
    do: {:error, "Currency must be supplied when a price is supplied"}

  defp validate_secondary("routes", _detail, value),
    do: validate_enum(value, @route_difficulties, "Route difficulty", nil)

  defp validate_secondary(_family, _detail, value),
    do: validate_optional_text(value, "Secondary detail", @maximum_detail_length)

  defp validate_enum(value, allowed, label, default) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()
    normalized = if normalized == "", do: default, else: normalized

    cond do
      is_nil(normalized) -> {:ok, nil}
      normalized in allowed -> {:ok, normalized}
      true -> {:error, "#{label} is not supported"}
    end
  end

  defp validate_optional_text(nil, _label, _maximum), do: {:ok, nil}
  defp validate_optional_text("", _label, _maximum), do: {:ok, nil}

  defp validate_optional_text(value, label, maximum) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) > maximum -> {:error, "#{label} is too long"}
      true -> {:ok, value}
    end
  end

  defp validate_optional_text(_value, label, _maximum), do: {:error, "#{label} is invalid"}

  defp validate_visibility(nil), do: {:ok, "public"}
  defp validate_visibility(""), do: {:ok, "public"}

  defp validate_visibility(value) when is_binary(value) do
    value = String.trim(value)

    if value in @visibility_values, do: {:ok, value}, else: {:error, "Visibility is not supported"}
  end

  defp validate_visibility(_value), do: {:error, "Visibility is not supported"}

  defp param(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of lib/pleroma/web/activity_pub/native_object.ex
