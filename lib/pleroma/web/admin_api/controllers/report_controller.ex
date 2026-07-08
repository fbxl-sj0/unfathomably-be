# Pleroma: A lightweight social networking server
# Copyright Ã‚Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.ReportController do
  use Pleroma.Web, :controller

  alias Pleroma.Activity
  alias Pleroma.ModerationLog
  alias Pleroma.ReportNote
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.AdminAPI
  alias Pleroma.Web.AdminAPI.Report
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.Plugs.OAuthScopesPlug

  require Logger

  plug(Pleroma.Web.ApiSpec.CastAndValidate)
  plug(OAuthScopesPlug, %{scopes: ["admin:read:reports"]} when action in [:index, :show])

  plug(
    OAuthScopesPlug,
    %{scopes: ["admin:write:reports"]}
    when action in [:update, :assign_account, :notes_create, :notes_delete]
  )

  action_fallback(AdminAPI.FallbackController)

  defdelegate open_api_operation(action), to: Pleroma.Web.ApiSpec.Admin.ReportOperation
  defp json_response(conn, status, json), do: ControllerHelper.json_response(conn, status, json)

  def index(conn, params) do
    reports = Utils.get_reports(params, params.page, params.page_size)

    render(conn, "index.json", reports: reports)
  end

  def show(conn, params) do
    id = get_param(params, "id")

    with %Activity{} = report <- Activity.get_report(id) do
      render(conn, "show.json", Report.extract_report_info(report))
    else
      _ -> {:error, :not_found}
    end
  end

  def update(%{assigns: %{user: admin}} = conn, _) do
    reports = conn |> request_body() |> get_param("reports", []) |> Enum.map(&normalize_report/1)

    result =
      Enum.map(reports, fn report ->
        case CommonAPI.update_report_state(report.id, report.state) do
          {:ok, activity} ->
            report = Activity.get_by_id_with_user_actor(activity.id)

            ModerationLog.insert_log(%{
              action: "report_update",
              actor: admin,
              subject: activity,
              subject_actor: report.user_actor
            })

            activity

          {:error, message} ->
            %{id: report.id, error: message}
        end
      end)

    if Enum.any?(result, &Map.has_key?(&1, :error)) do
      json_response(conn, :bad_request, result)
    else
      json_response(conn, :no_content, "")
    end
  end

  def assign_account(%{assigns: %{user: admin}} = conn, _) do
    reports = conn |> request_body() |> get_param("reports", []) |> Enum.map(&normalize_report/1)
    result = Enum.map(reports, &do_assign_account(&1, admin))

    if Enum.any?(result, &Map.has_key?(&1, :error)) do
      json_response(conn, :bad_request, result)
    else
      json_response(conn, :no_content, "")
    end
  end

  def notes_create(%{assigns: %{user: user}} = conn, params) do
    content = conn |> request_body() |> get_param("content")
    report_id = get_param(params, "id")

    with {:ok, _} <- ReportNote.create(user.id, report_id, content),
         report <- Activity.get_by_id_with_user_actor(report_id) do
      ModerationLog.insert_log(%{
        action: "report_note",
        actor: user,
        subject: report,
        subject_actor: report.user_actor,
        text: content
      })

      json_response(conn, :no_content, "")
    else
      _ -> json_response(conn, :bad_request, "")
    end
  end

  def notes_delete(%{assigns: %{user: user}} = conn, params) do
    note_id = get_param(params, "id")
    report_id = get_param(params, "report_id")

    with {:ok, note} <- ReportNote.destroy(note_id),
         report <- Activity.get_by_id_with_user_actor(report_id) do
      ModerationLog.insert_log(%{
        action: "report_note_delete",
        actor: user,
        subject: report,
        subject_actor: report.user_actor,
        text: note.content
      })

      json_response(conn, :no_content, "")
    else
      _ -> json_response(conn, :bad_request, "")
    end
  end

  defp do_assign_account(%{assigned_account: nil, id: id}, admin) do
    with {:ok, activity} <- CommonAPI.assign_report_to_account(id, nil),
         report <- Activity.get_by_id_with_user_actor(activity.id) do
      ModerationLog.insert_log(%{
        action: "report_unassigned",
        actor: admin,
        subject: activity,
        subject_actor: report.user_actor
      })

      activity
    else
      {:error, message} ->
        %{id: id, error: message}
    end
  end

  defp do_assign_account(%{assigned_account: assigned_account, id: id}, admin) do
    with %User{id: account} = user <- User.get_cached_by_nickname(assigned_account),
         {:ok, activity} <- CommonAPI.assign_report_to_account(id, account),
         report <- Activity.get_by_id_with_user_actor(activity.id) do
      ModerationLog.insert_log(%{
        action: "report_assigned",
        actor: admin,
        subject: activity,
        subject_actor: report.user_actor,
        assigned_account: user.nickname
      })

      activity
    else
      {:error, message} ->
        %{id: id, error: message}
    end
  end

  defp request_body(%{
         body_params: body,
         private: %{open_api_spex: %{body_params: spec_body}}
       })
       when is_map(body) and map_size(body) == 0 and is_map(spec_body),
       do: spec_body

  defp request_body(%{body_params: body}) when is_map(body), do: body

  defp request_body(%{private: %{open_api_spex: %{body_params: body}}}) when is_map(body),
    do: body

  defp request_body(_), do: %{}

  defp normalize_report(report) when is_map(report) do
    %{
      id: get_param(report, "id"),
      state: get_param(report, "state"),
      assigned_account: get_param(report, "assigned_account")
    }
  end

  defp get_param(map, key, default \\ nil)

  defp get_param(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  defp get_param(_map, _key, default), do: default
end
