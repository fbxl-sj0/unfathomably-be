# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.UploadedMediaPlugTest do
  use Pleroma.Web.ConnCase, async: false
  alias Pleroma.Upload

  defmodule FailingUploader do
    def get_file(_file), do: {:error, :enoent}
  end

  defp upload_file(context) do
    Pleroma.DataCase.ensure_local_uploader(context)
    File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

    file = %Plug.Upload{
      content_type: "image/jpeg",
      path: Path.absname("test/fixtures/image_tmp.jpg"),
      filename: "nice_tf.jpg"
    }

    {:ok, data} = Upload.store(file)
    [%{"href" => attachment_url} | _] = data["url"]
    [attachment_url: attachment_url]
  end

  setup_all :upload_file

  test "does not send Content-Disposition header when name param is not set", %{
    attachment_url: attachment_url
  } do
    conn = get(build_conn(), attachment_url)
    refute Enum.any?(conn.resp_headers, &(elem(&1, 0) == "content-disposition"))
  end

  test "sends Content-Disposition header when name param is set", %{
    attachment_url: attachment_url
  } do
    conn = get(build_conn(), attachment_url <> ~s[?name="cofe".gif])

    assert Enum.any?(
             conn.resp_headers,
             &(&1 == {"content-disposition", ~s[inline; filename="\\"cofe\\".gif"]})
           )
  end

  test "Filters out dangerous content types" do
    context = %{module: __MODULE__, case: __MODULE__}

    test_files = [
      "test/fixtures/lain.xml",
      "test/fixtures/nypd-facial-recognition-children-teenagers.html",
      "test/fixtures/snow.js"
    ]

    Enum.each(test_files, fn t ->
      Pleroma.DataCase.ensure_local_uploader(context)
      filename = String.split(t, "/") |> List.last()

      upload = %Plug.Upload{
        path: Path.absname(t),
        filename: filename
      }

      {:ok, %{"url" => [%{"href" => attachment_url}]}} = Upload.store(upload)

      conn = get(build_conn(), attachment_url)

      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end)
  end

  test "returns not found when the uploader cannot resolve a media path" do
    clear_config([Pleroma.Upload, :uploader], FailingUploader)

    conn = get(build_conn(), "/media/missing.jpg")

    assert response(conn, 404) == "Not found"
  end
end
