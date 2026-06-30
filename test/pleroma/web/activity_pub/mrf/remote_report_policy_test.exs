defmodule Pleroma.Web.ActivityPub.MRF.RemoteReportPolicyTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.MRF.RemoteReportPolicy

  setup do
    clear_config([:mrf_remote_report, :reject_all], false)
    clear_config([:mrf_remote_report, :reject_third_party], false)
  end

  test "doesn't impact local report" do
    clear_config([:mrf_remote_report, :reject_anonymous], true)
    clear_config([:mrf_remote_report, :reject_empty_message], true)

    activity = %{
      "type" => "Flag",
      "actor" => "http://localhost:4001/actor",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end

  test "rejects anonymous report if `reject_anonymous: true`" do
    clear_config([:mrf_remote_report, :reject_anonymous], true)
    clear_config([:mrf_remote_report, :reject_empty_message], true)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/actor",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:reject, _} = RemoteReportPolicy.filter(activity)
  end

  test "preserves anonymous report if `reject_anonymous: false`" do
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/actor",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end

  test "rejects report on third-party if `reject_third_party: true`" do
    clear_config([:mrf_remote_report, :reject_third_party], true)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:reject, _} = RemoteReportPolicy.filter(activity)
  end

  test "preserves report on local user if `reject_third_party: true`" do
    clear_config([:mrf_remote_report, :reject_third_party], true)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "object" => ["http://localhost:4001/users/alice"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end

  test "rejects empty message report if `reject_empty_message: true`" do
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], true)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:reject, "[RemoteReportPolicy] No content"} = RemoteReportPolicy.filter(activity)
  end

  test "rejects empty message report (\"\") if `reject_empty_message: true`" do
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], true)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "object" => ["https://mastodon.online/users/Gargron"],
      "content" => ""
    }

    assert {:reject, "[RemoteReportPolicy] No content"} = RemoteReportPolicy.filter(activity)
  end

  test "preserves empty message report if `reject_empty_message: false`" do
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end

  test "preserves anonymous, empty message report with all settings disabled" do
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/actor",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end

  test "reject remote report if `reject_all: true`" do
    clear_config([:mrf_remote_report, :reject_all], true)
    clear_config([:mrf_remote_report, :reject_anonymous], false)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => "https://mastodon.social/users/Gargron",
      "content" => "Transphobia",
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:reject, _} = RemoteReportPolicy.filter(activity)
  end

  test "malformed report actor does not crash the policy" do
    clear_config([:mrf_remote_report, :reject_anonymous], true)
    clear_config([:mrf_remote_report, :reject_empty_message], false)

    activity = %{
      "type" => "Flag",
      "actor" => %{"id" => "https://mastodon.social/actor"},
      "object" => ["https://mastodon.online/users/Gargron"]
    }

    assert {:ok, _} = RemoteReportPolicy.filter(activity)
  end
end
