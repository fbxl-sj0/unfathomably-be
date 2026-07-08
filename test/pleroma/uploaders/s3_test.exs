# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Uploaders.S3Test do
  use Pleroma.DataCase

  alias Pleroma.Uploaders.S3

  import ExUnit.CaptureLog
  import Mox

  setup do
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.S3)
    clear_config([Pleroma.Upload, :base_url], "https://s3.amazonaws.com")
    clear_config([Pleroma.Uploaders.S3])
    clear_config([Pleroma.Uploaders.S3, :bucket], "test_bucket")
    clear_config([Pleroma.Uploaders.S3, :ex_aws_impl], Pleroma.Uploaders.S3.ExAwsMock)
  end

  describe "get_file/1" do
    test "it returns path to local folder for files" do
      assert S3.get_file("test_image.jpg") == {
               :ok,
               {:url, "https://s3.amazonaws.com/test_bucket/test_image.jpg"}
             }
    end

    test "it returns path without bucket when truncated_namespace set to ''" do
      s3_config = [
        bucket: "test_bucket",
        bucket_namespace: "myaccount",
        truncated_namespace: ""
      ]

      clear_config([Pleroma.Uploaders.S3], s3_config)

      clear_config([Pleroma.Upload, :base_url], "https://s3.amazonaws.com")

      assert S3.get_file("test_image.jpg") == {
               :ok,
               {:url, "https://s3.amazonaws.com/test_image.jpg"}
             }
    end

    test "it returns path with bucket namespace when namespace is set" do
      s3_config = [
        bucket: "test_bucket",
        bucket_namespace: "family"
      ]

      clear_config([Pleroma.Uploaders.S3], s3_config)

      assert S3.get_file("test_image.jpg") == {
               :ok,
               {:url, "https://s3.amazonaws.com/family:test_bucket/test_image.jpg"}
             }
    end

    test "it returns a media proxy URL when force_media_proxy is enabled" do
      clear_config([:media_proxy, :enabled], true)
      clear_config([Pleroma.Uploaders.S3, :force_media_proxy], true)

      {:ok, {:url, url}} = S3.get_file("test_image.jpg")

      assert url ==
               Pleroma.Web.MediaProxy.url("https://s3.amazonaws.com/test_bucket/test_image.jpg")
    end
  end

  describe "put_file/1" do
    setup do
      file_upload = %Pleroma.Upload{
        name: "image-tet.jpg",
        content_type: "image/jpeg",
        path: "test_folder/image-tet.jpg",
        tempfile: Path.absname("test/instance_static/add/shortcode.png")
      }

      [file_upload: file_upload]
    end

    test "save file", %{file_upload: file_upload} do
      expect(Pleroma.Uploaders.S3.ExAwsMock, :request, fn _ -> {:ok, :ok} end)

      assert S3.put_file(file_upload) == {:ok, {:file, "test_folder/image-tet.jpg"}}
    end

    test "returns a media proxy URL spec when force_media_proxy is enabled", %{
      file_upload: file_upload
    } do
      clear_config([:media_proxy, :enabled], true)
      clear_config([Pleroma.Uploaders.S3, :force_media_proxy], true)

      expect(Pleroma.Uploaders.S3.ExAwsMock, :request, fn _ -> {:ok, :ok} end)

      expected_url =
        Pleroma.Web.MediaProxy.url(
          "https://s3.amazonaws.com/test_bucket/test_folder/image-tet.jpg"
        )

      assert S3.put_file(file_upload) == {:ok, {:url, expected_url}}
    end

    test "returns error", %{file_upload: file_upload} do
      expect(Pleroma.Uploaders.S3.ExAwsMock, :request, fn _ -> {:error, "S3 Upload failed"} end)

      assert capture_log(fn ->
               assert S3.put_file(file_upload) == {:error, "S3 Upload failed"}
             end) =~ "Elixir.Pleroma.Uploaders.S3: {:error, \"S3 Upload failed\"}"
    end
  end

  describe "delete_file/1" do
    test "deletes file" do
      expect(Pleroma.Uploaders.S3.ExAwsMock, :request, fn _req -> {:ok, %{status_code: 204}} end)

      assert :ok = S3.delete_file("image.jpg")
    end
  end
end
