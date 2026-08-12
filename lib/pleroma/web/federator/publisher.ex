# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Federator.Publisher do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.User
  alias Pleroma.Workers.PublisherWorker

  require Logger

  @moduledoc """
  Defines the contract used by federation implementations to publish messages to
  their peers.
  """

  @doc """
  Determine whether an activity can be relayed using the federation module.
  """
  @callback is_representable?(Pleroma.Activity.t()) :: boolean()

  @doc """
  Relays an activity to a specified peer, determined by the parameters.  The
  parameters used are controlled by the federation module.
  """
  @callback publish_one(map()) ::
              {:ok, map()} | {:error, any()} | {:cancel, any()} | {:snooze, non_neg_integer()}

  @doc """
  Enqueue publishing a single activity.
  """
  @spec enqueue_one(module(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | :federation_disabled}
  def enqueue_one(module, %{} = params, worker_args \\ []) do
    with :ok <- Pleroma.Federation.ensure_enabled() do
      worker_args =
        Keyword.put_new(worker_args, :unique,
          period: 86_400,
          states: [:available, :scheduled, :executing, :retryable, :suspended, :completed],
          keys: [:module, :params]
        )

      PublisherWorker.enqueue(
        "publish_one",
        %{"module" => to_string(module), "params" => params},
        worker_args
      )
    end
  end

  @doc """
  Relays an activity to all specified peers.
  """
  @callback publish(User.t(), Activity.t()) :: :ok | {:error, any()}

  @spec publish(User.t(), Activity.t()) :: :ok | {:error, any()}
  def publish(%User{} = user, %Activity{} = activity) do
    if Pleroma.Federation.enabled?() do
      errors =
        Config.get([:instance, :federation_publisher_modules])
        |> Enum.reduce([], fn module, errors ->
          if module.is_representable?(activity) do
            Logger.debug("Publishing #{activity.data["id"]} using #{inspect(module)}")

            case module.publish(user, activity) do
              :ok -> errors
              {:ok, _result} -> errors
              {:error, reason} -> [{module, reason} | errors]
              result -> [{module, {:invalid_publish_result, result}} | errors]
            end
          else
            errors
          end
        end)

      case errors do
        [] -> :ok
        errors -> {:error, {:publisher_failures, Enum.reverse(errors)}}
      end
    else
      :ok
    end
  end

  @doc """
  Gathers links used by an outgoing federation module for WebFinger output.
  """
  @callback gather_webfinger_links(User.t()) :: list()

  @spec gather_webfinger_links(User.t()) :: list()
  def gather_webfinger_links(%User{} = user) do
    if Pleroma.Federation.enabled?() do
      Config.get([:instance, :federation_publisher_modules])
      |> Enum.reduce([], fn module, links ->
        links ++ module.gather_webfinger_links(user)
      end)
    else
      []
    end
  end

  @doc """
  Gathers nodeinfo protocol names supported by the federation module.
  """
  @callback gather_nodeinfo_protocol_names() :: list()

  @spec gather_nodeinfo_protocol_names() :: list()
  def gather_nodeinfo_protocol_names do
    if Pleroma.Federation.enabled?() do
      Config.get([:instance, :federation_publisher_modules])
      |> Enum.reduce([], fn module, links ->
        links ++ module.gather_nodeinfo_protocol_names()
      end)
    else
      []
    end
  end

  @doc """
  Gathers a set of remote users given an IR envelope.
  """
  def remote_users(%User{id: user_id}, %{data: %{"to" => to} = data}) do
    cc = Map.get(data, "cc", [])

    bcc =
      data
      |> Map.get("bcc", [])
      |> Enum.reduce([], fn ap_id, bcc ->
        case Pleroma.List.get_by_ap_id(ap_id) do
          %Pleroma.List{user_id: ^user_id} = list ->
            {:ok, following} = Pleroma.List.get_following(list)
            bcc ++ Enum.map(following, & &1.ap_id)

          _ ->
            bcc
        end
      end)

    [to, cc, bcc]
    |> Enum.concat()
    |> Enum.map(&User.get_cached_by_ap_id/1)
    |> Enum.filter(fn user -> user && !user.local end)
  end
end
