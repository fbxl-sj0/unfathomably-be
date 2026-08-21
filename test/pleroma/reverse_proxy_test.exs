# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxyTest do
  use Pleroma.Web.ConnCase

  @moduletag capture_log: true

  import ExUnit.CaptureLog
  import Mox

  alias Pleroma.ReverseProxy
  alias Pleroma.ReverseProxy.ClientMock
  alias Plug.Conn

  setup_all do
    {:ok, _} = Registry.start_link(keys: :unique, name: ClientMock)
    :ok
  end

  setup :verify_on_exit!

  defp request_mock(invokes) do
    ClientMock
    |> expect(:request, fn :get, url, headers, _body, _opts ->
      Registry.register(ClientMock, url, 0)
      body = headers |> Enum.into(%{}) |> Jason.encode!()

      {:ok, 200,
       [
         {"content-type", "application/json"},
         {"content-length", byte_size(body) |> to_string()}
       ], %{url: url, body: body}}
    end)
    |> expect(:stream_body, invokes, fn %{url: url, body: body} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          {:ok, body, client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          :done
      end
    end)
  end

  describe "reverse proxy" do
    test "do not track successful request", %{conn: conn} do
      request_mock(2)
      url = "/success"

      conn = ReverseProxy.call(conn, url)

      assert conn.status == 200
      assert Cachex.get(:failed_proxy_url_cache, url) == {:ok, nil}
    end
  end

  test "use Pleroma's user agent in the request; don't pass the client's", %{conn: conn} do
    request_mock(2)

    conn =
      conn
      |> Plug.Conn.put_req_header("user-agent", "fake/1.0")
      |> ReverseProxy.call("/user-agent")

    assert json_response(conn, 200) == %{"user-agent" => Pleroma.Application.user_agent()}
  end

  test "closed connection", %{conn: conn} do
    ClientMock
    |> expect(:request, fn :get, "/closed", _, _, _ -> {:ok, 200, [], %{}} end)
    |> expect(:stream_body, fn _ -> {:error, :closed} end)
    |> expect(:close, fn _ -> :ok end)

    assert_raise ReverseProxy.StreamError, fn ->
      ReverseProxy.call(conn, "/closed")
    end
  end

  test "request connection close is not logged as an application error", %{conn: conn} do
    url = "/request-closed"

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:error, :closed} end)

    log =
      capture_log([level: :debug], fn ->
        conn = ReverseProxy.call(conn, url)

        assert conn.status == 502
        assert conn.halted
      end)

    assert log =~
             "[debug] Elixir.Pleroma.ReverseProxy: request to \"/request-closed\" failed: :closed"

    refute log =~ "[error]"

    assert Cachex.get(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
             {:ok, %{status: 502, body: "Upstream request failed"}}

    cached_conn = ReverseProxy.call(recycle(conn), url)
    assert cached_conn.status == 502
    assert cached_conn.resp_body == "Upstream request failed"
  end

  test "a failed HEAD probe does not suppress a later GET", %{conn: conn} do
    url = "/method-scoped-failure"

    ClientMock
    |> expect(:request, fn :head, ^url, _, _, _ -> {:error, :closed} end)

    head_conn = ReverseProxy.call(%{conn | method: "HEAD"}, url)
    assert head_conn.status == 502

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:ok, 200, [], %{url: url, body: "ok"}} end)
    |> expect(:stream_body, fn %{body: "ok"} = client -> {:ok, "ok", %{client | body: ""}} end)
    |> expect(:stream_body, fn %{body: ""} -> :done end)

    get_conn = ReverseProxy.call(recycle(conn), url)
    assert get_conn.status == 200
    assert get_conn.resp_body == "ok"
  end

  test "an old URL-only failure entry does not suppress a request", %{conn: conn} do
    url = "/legacy-url-only-failure"

    Cachex.put(:failed_proxy_url_cache, url, true, expire: :timer.seconds(60))
    on_exit(fn -> Cachex.del(:failed_proxy_url_cache, url) end)

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:ok, 200, [], %{url: url, body: "ok"}} end)
    |> expect(:stream_body, fn %{body: "ok"} = client -> {:ok, "ok", %{client | body: ""}} end)
    |> expect(:stream_body, fn %{body: ""} -> :done end)

    get_conn = ReverseProxy.call(conn, url)
    assert get_conn.status == 200
    assert get_conn.resp_body == "ok"
  end

  test "uses the image fallback for an animated PNG during an origin cooldown", %{conn: conn} do
    url = "https://media-apng.example/posts/animation.apng"
    cooldown_key = {:media_origin_throttle, {"https", "media-apng.example", 443}}

    Cachex.put(
      :failed_proxy_url_cache,
      cooldown_key,
      %{retry_at: System.system_time(:second) + 60},
      expire: :timer.seconds(60)
    )

    on_exit(fn -> Cachex.del(:failed_proxy_url_cache, cooldown_key) end)

    conn = ReverseProxy.media_call(conn, url, image_fallback_on_failure: true)

    assert conn.status == 200
    assert Conn.get_resp_header(conn, "content-type") == ["image/svg+xml"]

    assert Conn.get_resp_header(conn, "content-disposition") ==
             ["inline; filename=\"remote-media-unavailable.svg\""]

    assert Conn.get_resp_header(conn, "retry-after") != []
    assert conn.resp_body =~ "<svg"
  end

  test "uses the image fallback when an opaque media path has an image query name", %{
    conn: conn
  } do
    url = "https://media.example/files/opaque?name=preview.png"

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:error, :timeout} end)

    conn =
      ReverseProxy.media_call(conn, url,
        attachment_name: "opaque",
        image_fallback_on_failure: true
      )

    assert conn.status == 200
    assert Conn.get_resp_header(conn, "content-type") == ["image/svg+xml"]
    assert conn.resp_body =~ "<svg"
  end

  test "uses the image fallback for an extensionless image request", %{conn: conn} do
    url = "https://media.example/files/opaque"

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:error, :timeout} end)

    conn =
      conn
      |> Conn.put_req_header("accept", "image/avif,image/webp,image/*,*/*;q=0.8")
      |> ReverseProxy.media_call(url,
        attachment_name: "opaque",
        image_fallback_on_failure: true
      )

    assert conn.status == 200
    assert Conn.get_resp_header(conn, "content-type") == ["image/svg+xml"]
    assert conn.resp_body =~ "<svg"
  end

  test "preserves an extensionless failure for a non-image request", %{conn: conn} do
    url = "https://media.example/files/opaque"

    ClientMock
    |> expect(:request, fn :get, ^url, _, _, _ -> {:error, :timeout} end)

    conn =
      conn
      |> Conn.put_req_header("accept", "application/json")
      |> ReverseProxy.media_call(url,
        attachment_name: "opaque",
        image_fallback_on_failure: true
      )

    assert conn.status == 504
  end

  defp stream_mock(invokes, with_close? \\ false) do
    ClientMock
    |> expect(:request, fn :get, "/stream-bytes/" <> length, _, _, _ ->
      Registry.register(ClientMock, "/stream-bytes/" <> length, 0)

      {:ok, 200, [{"content-type", "application/octet-stream"}],
       %{url: "/stream-bytes/" <> length}}
    end)
    |> expect(:stream_body, invokes, fn %{url: "/stream-bytes/" <> length} = client ->
      max = String.to_integer(length)

      case Registry.lookup(ClientMock, "/stream-bytes/" <> length) do
        [{_, current}] when current < max ->
          Registry.update_value(
            ClientMock,
            "/stream-bytes/" <> length,
            &(&1 + 10)
          )

          {:ok, "0123456789", client}

        [{_, ^max}] ->
          Registry.unregister(ClientMock, "/stream-bytes/" <> length)
          :done
      end
    end)

    if with_close? do
      expect(ClientMock, :close, fn _ -> :ok end)
    end
  end

  describe "max_body" do
    test "length returns error if content-length more than option", %{conn: conn} do
      request_mock(0)
      expect(ClientMock, :close, fn _ -> :ok end)

      log =
        capture_log([level: :debug], fn ->
          ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
        end)

      assert log =~
               "[debug] Elixir.Pleroma.ReverseProxy: request to \"/huge-file\" failed: :body_too_large"

      refute log =~ "[error]"

      assert {:ok, %{status: 502, body: "Upstream request failed"}} ==
               Cachex.get(
                 :failed_proxy_url_cache,
                 {:failed_proxy_request, "GET", "/huge-file"}
               )

      assert capture_log(fn ->
               ReverseProxy.call(conn, "/huge-file", max_body_length: 4)
             end) == ""
    end

    test "max_body_length returns error if streaming body more than that option", %{conn: conn} do
      stream_mock(4, true)

      log =
        capture_log(fn ->
          assert_raise ReverseProxy.StreamError, fn ->
            ReverseProxy.call(conn, "/stream-bytes/50", max_body_length: 30)
          end
        end)

      assert log =~
               "Elixir.Pleroma.ReverseProxy request to /stream-bytes/50 failed while reading/chunking: :body_too_large"
    end
  end

  describe "HEAD requests" do
    test "common", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :head, "/head", _, _, _ ->
        {:ok, 200, [{"content-type", "text/html; charset=utf-8"}]}
      end)

      conn = ReverseProxy.call(Map.put(conn, :method, "HEAD"), "/head")
      assert html_response(conn, 200) == ""
    end
  end

  defp error_mock(status) when is_integer(status) do
    ClientMock
    |> expect(:request, fn :get, "/status/" <> _, _, _, _ ->
      {:ok, status, [], %{}}
    end)
    |> expect(:close, fn %{} -> :ok end)
  end

  describe "returns error on" do
    test "500", %{conn: conn} do
      error_mock(500)
      url = "/status/500"

      assert capture_log(fn -> ReverseProxy.call(conn, url) end) =~
               "[warning] Elixir.Pleroma.ReverseProxy: request to \"/status/500\" failed with HTTP status 500"

      assert Cachex.get(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
               {:ok, %{status: 500, body: "Request failed: Internal Server Error"}}

      {:ok, ttl} =
        Cachex.ttl(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url})

      assert ttl <= 60_000
    end

    test "400", %{conn: conn} do
      error_mock(400)
      url = "/status/400"

      assert capture_log(fn -> ReverseProxy.call(conn, url) end) =~
               "[warning] Elixir.Pleroma.ReverseProxy: request to \"/status/400\" failed with HTTP status 400"

      assert Cachex.get(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
               {:ok, %{status: 400, body: "Request failed: Bad Request"}}

      assert Cachex.ttl(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
               {:ok, nil}
    end

    test "403", %{conn: conn} do
      error_mock(403)
      url = "/status/403"

      log =
        capture_log([level: :debug], fn ->
          ReverseProxy.call(conn, url, failed_request_ttl: :timer.seconds(120))
        end)

      assert log =~
               "[debug] Elixir.Pleroma.ReverseProxy: request to \"/status/403\" failed with HTTP status 403"

      refute log =~ "[error]"

      {:ok, ttl} =
        Cachex.ttl(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url})

      assert ttl > 100_000
    end

    test "204", %{conn: conn} do
      url = "/status/204"

      ClientMock
      |> expect(:request, fn :get, _url, _, _, _ -> {:ok, 204, [], %{}} end)
      |> expect(:close, fn %{} -> :ok end)

      assert capture_log(fn ->
               conn = ReverseProxy.call(conn, url)
               assert conn.resp_body == "Request failed: No Content"
               assert conn.halted
             end) =~
               "[warning] Elixir.Pleroma.ReverseProxy: request to \"/status/204\" failed with HTTP status 204"

      assert Cachex.get(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
               {:ok, %{status: 204, body: "Request failed: No Content"}}

      assert Cachex.ttl(:failed_proxy_url_cache, {:failed_proxy_request, "GET", url}) ==
               {:ok, nil}
    end
  end

  test "streaming", %{conn: conn} do
    stream_mock(21)
    conn = ReverseProxy.call(conn, "/stream-bytes/200")
    assert conn.state == :chunked
    assert byte_size(conn.resp_body) == 200
    assert Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  defp headers_mock(_) do
    ClientMock
    |> expect(:request, fn :get, "/headers", headers, _, _ ->
      Registry.register(ClientMock, "/headers", 0)
      {:ok, 200, [{"content-type", "application/json"}], %{url: "/headers", headers: headers}}
    end)
    |> expect(:stream_body, 2, fn %{url: url, headers: headers} = client ->
      case Registry.lookup(ClientMock, url) do
        [{_, 0}] ->
          Registry.update_value(ClientMock, url, &(&1 + 1))
          headers = for {k, v} <- headers, into: %{}, do: {String.capitalize(k), v}
          {:ok, Jason.encode!(%{headers: headers}), client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, url)
          :done
      end
    end)

    :ok
  end

  describe "keep request headers" do
    setup [:headers_mock]

    test "header passes", %{conn: conn} do
      conn =
        Conn.put_req_header(
          conn,
          "accept",
          "text/html"
        )
        |> ReverseProxy.call("/headers")

      %{"headers" => headers} = json_response(conn, 200)
      assert headers["Accept"] == "text/html"
    end

    test "header is filtered", %{conn: conn} do
      conn =
        Conn.put_req_header(
          conn,
          "accept-language",
          "en-US"
        )
        |> ReverseProxy.call("/headers")

      %{"headers" => headers} = json_response(conn, 200)
      refute headers["Accept-Language"]
    end
  end

  test "returns 400 on non GET, HEAD requests", %{conn: conn} do
    conn = ReverseProxy.call(Map.put(conn, :method, "POST"), "/ip")
    assert conn.status == 400
  end

  describe "cache resp headers" do
    test "add cache-control", %{conn: conn} do
      ClientMock
      |> expect(:request, fn :get, "/cache", _, _, _ ->
        {:ok, 200, [{"ETag", "some ETag"}], %{}}
      end)
      |> expect(:stream_body, fn _ -> :done end)

      conn = ReverseProxy.call(conn, "/cache")

      assert {"cache-control", "public, max-age=1209600, immutable, no-transform"} in conn.resp_headers
    end
  end

  defp disposition_headers_mock(headers) do
    ClientMock
    |> expect(:request, fn :get, "/disposition", _, _, _ ->
      Registry.register(ClientMock, "/disposition", 0)

      {:ok, 200, headers, %{url: "/disposition"}}
    end)
    |> expect(:stream_body, 2, fn %{url: "/disposition"} = client ->
      case Registry.lookup(ClientMock, "/disposition") do
        [{_, 0}] ->
          Registry.update_value(ClientMock, "/disposition", &(&1 + 1))
          {:ok, "", client}

        [{_, 1}] ->
          Registry.unregister(ClientMock, "/disposition")
          :done
      end
    end)
  end

  describe "response content disposition header" do
    test "not atachment", %{conn: conn} do
      disposition_headers_mock([
        {"content-type", "image/gif"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-type", "image/gif"} in conn.resp_headers
    end

    test "with content-disposition header", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=\"filename.jpg\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"filename.jpg\""} in conn.resp_headers
    end

    test "with unquoted content-disposition filename", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=filename.jpg"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"filename.jpg\""} in conn.resp_headers
    end

    test "with escaped quotation marks in content-disposition filename", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=\"quote\\\"name.jpg\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"quote\\\"name.jpg\""} in conn.resp_headers
    end

    test "with encoded content-disposition filename", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename*=UTF-8''file%20name.jpg"},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"file name.jpg\""} in conn.resp_headers
    end

    test "with unsafe content-disposition filename characters", %{conn: conn} do
      disposition_headers_mock([
        {"content-disposition", "attachment; filename=\"line\nname.jpg\""},
        {"content-length", "0"}
      ])

      conn = ReverseProxy.call(conn, "/disposition")

      assert {"content-disposition", "attachment; filename=\"line_name.jpg\""} in conn.resp_headers
    end
  end
end
