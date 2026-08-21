# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.StealEmojiPolicyTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  alias Pleroma.Config
  alias Pleroma.Emoji
  alias Pleroma.Web.ActivityPub.MRF.StealEmojiPolicy
  alias Pleroma.Workers.StealEmojiWorker

  setup do
    emoji_path = [:instance, :static_dir] |> Config.get() |> Path.join("emoji/stolen")

    Emoji.reload()

    message = %{
      "type" => "Create",
      "object" => %{
        "emoji" => [{"firedfox", "https://example.org/emoji/firedfox.png"}],
        "actor" => "https://example.org/users/admin"
      }
    }

    on_exit(fn ->
      File.rm_rf!(emoji_path)
    end)

    [message: message, path: emoji_path]
  end

  test "does nothing by default", %{message: message} do
    refute "firedfox" in installed()

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    refute "firedfox" in installed()
  end

  test "ignores malformed actor hosts", %{message: message} do
    message = put_in(message, ["object", "actor"], "https://%")

    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 284_468)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)
    refute "firedfox" in installed()
  end

  test "Steals emoji on unknown shortcode from allowed remote host", %{
    message: message,
    path: path
  } do
    refute "firedfox" in installed()
    refute File.exists?(path)

    Tesla.Mock.mock(fn %{method: :get, url: "https://example.org/emoji/firedfox.png"} ->
      %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.jpg")}
    end)

    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 284_468)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    assert_enqueued(worker: StealEmojiWorker, args: emoji_job_args())
    assert :ok = perform_job(StealEmojiWorker, emoji_job_args())

    assert "firedfox" in installed()
    assert File.exists?(path)

    assert path
           |> Path.join("firedfox.png")
           |> File.exists?()
  end

  test "repeated deliveries enqueue one incomplete installation", %{message: message} do
    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 284_468)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)
    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    assert length(all_enqueued(worker: StealEmojiWorker)) == 1
  end

  test "reject regex shortcode", %{message: message} do
    refute "firedfox" in installed()

    clear_config_section(:mrf_steal_emoji,
      hosts: ["example.org"],
      size_limit: 284_468,
      rejected_shortcodes: [~r/firedfox/]
    )

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    assert :discard = perform_job(StealEmojiWorker, emoji_job_args())

    refute "firedfox" in installed()
  end

  test "rejects invalid shortcodes", %{path: path} do
    message = %{
      "type" => "Create",
      "object" => %{
        "emoji" => [{"fired/fox", "https://example.org/emoji/firedfox.png"}],
        "actor" => "https://example.org/users/admin"
      }
    }

    fullpath = Path.join(path, "fired/fox.png")

    Tesla.Mock.mock(fn %{method: :get, url: "https://example.org/emoji/firedfox.png"} ->
      %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.jpg")}
    end)

    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 284_468)

    refute "fired/fox" in installed()
    refute File.exists?(path)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    refute "fired/fox" in installed()
    refute File.exists?(fullpath)
  end

  test "reject string shortcode", %{message: message} do
    refute "firedfox" in installed()

    clear_config_section(:mrf_steal_emoji,
      hosts: ["example.org"],
      size_limit: 284_468,
      rejected_shortcodes: ["firedfox"]
    )

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    refute "firedfox" in installed()
  end

  test "reject if size is above the limit", %{message: message} do
    refute "firedfox" in installed()

    Tesla.Mock.mock(fn %{method: :get, url: "https://example.org/emoji/firedfox.png"} ->
      %Tesla.Env{status: 200, body: File.read!("test/fixtures/image.jpg")}
    end)

    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 50_000)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)

    refute "firedfox" in installed()
  end

  test "reject if host returns error", %{message: message} do
    refute "firedfox" in installed()

    Tesla.Mock.mock(fn %{method: :get, url: "https://example.org/emoji/firedfox.png"} ->
      {:ok, %Tesla.Env{status: 404, body: "Not found"}}
    end)

    clear_config_section(:mrf_steal_emoji, hosts: ["example.org"], size_limit: 284_468)

    assert {:ok, _message} = StealEmojiPolicy.filter(message)
    assert :discard = perform_job(StealEmojiWorker, emoji_job_args())

    refute "firedfox" in installed()
  end

  test "worker revalidates the source host before fetching" do
    Tesla.Mock.mock(fn _env -> flunk("a removed allowlist host must not be fetched") end)
    clear_config_section(:mrf_steal_emoji, hosts: [])

    assert :discard = perform_job(StealEmojiWorker, emoji_job_args())
  end

  defp emoji_job_args do
    %{
      "shortcode" => "firedfox",
      "url" => "https://example.org/emoji/firedfox.png",
      "source_host" => "example.org"
    }
  end

  defp installed, do: Emoji.get_all() |> Enum.map(fn {k, _} -> k end)
end
