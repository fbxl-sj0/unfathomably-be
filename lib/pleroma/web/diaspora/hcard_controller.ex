# Unfathomably BE
# ----------------
#
# File: web/diaspora/hcard_controller.ex
#
# Purpose:
#   Serve the diaspora* hCard for a local account.
#
# Responsibilities:
#   - publish the stable local GUID and RSA public key
#   - expose bounded profile presentation fields
#
# This file intentionally does NOT expose private keys or remote mirror users.

defmodule Pleroma.Web.Diaspora.HCardController do
  use Pleroma.Web, :controller

  alias Pleroma.Diaspora
  alias Pleroma.Diaspora.Identities
  alias Pleroma.User

  def show(conn, %{"nickname" => nickname}) do
    with true <- Diaspora.enabled?(),
         %User{local: true} = user <- User.get_cached_by_nickname(nickname),
         false <- Identities.mirror?(user),
         public_key when is_binary(public_key) <- Diaspora.public_key_pem(user) do
      body = hcard(user, public_key)
      conn |> put_resp_content_type("text/html") |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp hcard(user, public_key) do
    name = escape(user.name || user.nickname)
    nickname = escape(user.nickname)
    guid = escape(Diaspora.guid(user))
    profile_url = escape(user.ap_id)
    key = escape(public_key)

    """
    <!doctype html>
    <html><body>
      <div id="content"><div class="vcard author">
        <span class="uid">#{guid}</span>
        <span class="fn">#{name}</span>
        <span class="nickname">#{nickname}</span>
        <a class="url" href="#{profile_url}">#{profile_url}</a>
        <pre class="key">#{key}</pre>
      </div></div>
    </body></html>
    """
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end

# end of web/diaspora/hcard_controller.ex
