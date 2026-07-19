# Pleroma: A lightweight social networking server
# SPDX-FileCopyrightText: 2026 Unfathomably Authors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.MessageSignatures do
  @moduledoc """
  Implements the RSA ActivityPub subset of RFC 9421 HTTP Message Signatures.

  The module intentionally accepts one selected signature and the components
  needed by federation requests. It does not implement response signatures,
  symmetric MACs, or arbitrary Structured Field component parameters.
  """

  alias Plug.Conn
  alias Pleroma.Web.Endpoint

  @algorithm "rsa-v1_5-sha256"
  @clock_skew :timer.hours(1) |> div(1000)
  @default_lifetime :timer.minutes(5) |> div(1000)
  @expiration_window :timer.hours(12) |> div(1000)
  @label_pattern ~r/\A[a-zA-Z*][a-zA-Z0-9_.*-]*\z/
  @component_pattern ~r/\A[@a-z0-9!#$%&'*+\-.^_|~]+\z/
  @parameter_pattern ~r/\A([a-z][a-z0-9_-]*)=("(?:\\.|[^"])*"|-?[0-9]+|[A-Za-z*][A-Za-z0-9_.*:\/-]*)(.*)\z/s
  @signature_pattern ~r/\A([a-zA-Z*][a-zA-Z0-9_.*-]*)=:([A-Za-z0-9+\/=]+):\z/

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def present?(request), do: header_values(request, "signature-input") != []

  def key_id(request) do
    with {:ok, signature} <- parse_request(request),
         key_id when is_binary(key_id) and key_id != "" <- signature.parameters["keyid"] do
      {:ok, key_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_key_id}
    end
  end

  def validate(request, public_key) do
    validate_result(request, public_key) == :ok
  end

  def validate_result(request, public_key) do
    with {:ok, signature} <- parse_request(request),
         :ok <- validate_parameters(signature.parameters),
         :ok <- validate_components(request, signature.components),
         :ok <- validate_body_digest(request, signature.components),
         {:ok, signature_base} <-
           signature_base(request, signature.components, signature.signature_parameters),
         true <- verify(signature_base, signature.signature, public_key) do
      :ok
    else
      false -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :malformed_signature}
  catch
    _, _ -> {:error, :malformed_signature}
  end

  def sign(private_key, key_id, method, target_uri, headers, opts \\ [])
      when is_binary(key_id) and is_binary(target_uri) do
    created = Keyword.get(opts, :created, System.system_time(:second))

    components =
      if header_values(%{headers: headers}, "content-digest") == [] do
        ["@method", "@target-uri"]
      else
        ["@method", "@target-uri", "content-digest"]
      end

    signature_parameters =
      "(" <>
        Enum.map_join(components, " ", &quoted/1) <>
        ");created=#{created};keyid=#{quoted(key_id)}"

    request = %{method: method, target_uri: target_uri, headers: headers}

    with {:ok, base} <- signature_base(request, components, signature_parameters),
         signature when is_binary(signature) <- :public_key.sign(base, :sha256, private_key) do
      {:ok,
       [
         {"Signature-Input", "sig1=#{signature_parameters}"},
         {"Signature", "sig1=:#{Base.encode64(signature)}:"}
       ]}
    else
      _ -> {:error, :signature_failed}
    end
  rescue
    _ -> {:error, :signature_failed}
  catch
    _, _ -> {:error, :signature_failed}
  end

  def content_digest(body) when is_binary(body) do
    "sha-256=:#{:crypto.hash(:sha256, body) |> Base.encode64()}:"
  end

  # ---------------------------------------------------------------------------
  # Signature parsing
  # ---------------------------------------------------------------------------

  defp parse_request(request) do
    with [signature_input] <- header_values(request, "signature-input"),
         [signature_header] <- header_values(request, "signature"),
         {:ok, inputs} <- parse_input_dictionary(signature_input),
         {:ok, signatures} <- parse_signature_dictionary(signature_header),
         {:ok, label} <- select_label(inputs, signatures),
         {:ok, input} <- Map.fetch(inputs, label),
         {:ok, signature} <- Map.fetch(signatures, label) do
      {:ok, Map.put(input, :signature, signature)}
    else
      _ -> {:error, :malformed_signature}
    end
  end

  defp parse_input_dictionary(value) do
    with {:ok, members} <- split_dictionary(value) do
      reduce_dictionary(members, &parse_input_member/1)
    end
  end

  defp parse_signature_dictionary(value) do
    with {:ok, members} <- split_dictionary(value) do
      reduce_dictionary(members, &parse_signature_member/1)
    end
  end

  defp reduce_dictionary(members, parser) do
    Enum.reduce_while(members, {:ok, %{}}, fn member, {:ok, acc} ->
      with {:ok, {label, value}} <- parser.(member),
           false <- Map.has_key?(acc, label) do
        {:cont, {:ok, Map.put(acc, label, value)}}
      else
        _ -> {:halt, {:error, :malformed_dictionary}}
      end
    end)
  end

  defp parse_input_member(member) do
    with [label, value] <- String.split(member, "=", parts: 2),
         label <- String.trim(label),
         true <- Regex.match?(@label_pattern, label),
         value <- String.trim(value),
         true <- String.starts_with?(value, "("),
         {closing_offset, 1} <- :binary.match(value, ")"),
         inner <- binary_part(value, 1, closing_offset - 1),
         parameters_text <-
           binary_part(value, closing_offset + 1, byte_size(value) - closing_offset - 1),
         {:ok, components} <- parse_components(inner),
         {:ok, parameters} <- parse_parameters(parameters_text) do
      {:ok,
       {label,
        %{
          components: components,
          parameters: parameters,
          signature_parameters: value
        }}}
    else
      _ -> {:error, :malformed_signature_input}
    end
  end

  defp parse_components(inner) do
    components =
      Regex.scan(~r/"([^"]+)"/, inner, capture: :all_but_first)
      |> List.flatten()

    canonical = Enum.map_join(components, " ", &quoted/1)

    if components != [] and canonical == inner and
         Enum.all?(components, &Regex.match?(@component_pattern, &1)) do
      {:ok, components}
    else
      {:error, :unsupported_components}
    end
  end

  defp parse_parameters(text), do: parse_parameters(text, %{})

  defp parse_parameters("", parameters), do: {:ok, parameters}

  defp parse_parameters(";" <> text, parameters) do
    case Regex.run(@parameter_pattern, text, capture: :all_but_first) do
      [name, raw_value, remaining] ->
        with false <- Map.has_key?(parameters, name),
             {:ok, value} <- parse_parameter_value(raw_value) do
          parse_parameters(remaining, Map.put(parameters, name, value))
        else
          _ -> {:error, :duplicate_parameter}
        end

      _ ->
        {:error, :malformed_parameter}
    end
  end

  defp parse_parameters(_, _), do: {:error, :malformed_parameter}

  defp parse_parameter_value("\"" <> _ = raw_value) do
    if String.ends_with?(raw_value, "\"") do
      raw_value
      |> binary_part(1, byte_size(raw_value) - 2)
      |> unescape_string([])
    else
      {:error, :malformed_string}
    end
  end

  defp parse_parameter_value(raw_value) do
    case Integer.parse(raw_value) do
      {value, ""} -> {:ok, value}
      _ -> {:ok, raw_value}
    end
  end

  defp unescape_string(<<>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp unescape_string(<<?\\, char, rest::binary>>, acc) when char in [?", ?\\],
    do: unescape_string(rest, [<<char>> | acc])

  defp unescape_string(<<?\\, _char, _rest::binary>>, _acc),
    do: {:error, :malformed_escape}

  defp unescape_string(<<char, rest::binary>>, acc),
    do: unescape_string(rest, [<<char>> | acc])

  defp parse_signature_member(member) do
    case Regex.run(@signature_pattern, String.trim(member), capture: :all_but_first) do
      [label, encoded_signature] ->
        case Base.decode64(encoded_signature) do
          {:ok, signature} -> {:ok, {label, signature}}
          :error -> {:error, :invalid_base64}
        end

      _ ->
        {:error, :malformed_signature}
    end
  end

  defp select_label(inputs, signatures) do
    common_labels =
      inputs
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(signatures, &1))

    cond do
      "sig1" in common_labels -> {:ok, "sig1"}
      length(common_labels) == 1 -> {:ok, hd(common_labels)}
      true -> {:error, :ambiguous_signature}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation and canonicalization
  # ---------------------------------------------------------------------------

  defp validate_parameters(parameters) do
    created = parameters["created"]
    expires = parameters["expires"]
    algorithm = parameters["alg"]
    now = System.system_time(:second)

    effective_expires =
      case expires do
        value when is_integer(value) -> min(value, created + @expiration_window)
        nil when is_integer(created) -> created + @default_lifetime
        _ -> nil
      end

    cond do
      not is_binary(parameters["keyid"]) or parameters["keyid"] == "" ->
        {:error, :missing_key_id}

      not is_integer(created) ->
        {:error, :missing_created}

      algorithm not in [nil, @algorithm, "rsa-sha256"] ->
        {:error, :unsupported_algorithm}

      created > now + @clock_skew ->
        {:error, :created_in_future}

      not is_integer(effective_expires) or now > effective_expires + @clock_skew ->
        {:error, :expired}

      true ->
        :ok
    end
  end

  defp validate_components(request, components) do
    method = request_method(request)

    cond do
      length(components) != MapSet.size(MapSet.new(components)) ->
        {:error, :duplicate_component}

      "@method" not in components or "@target-uri" not in components ->
        {:error, :missing_required_component}

      method in ["POST", "PUT", "PATCH"] and "content-digest" not in components ->
        {:error, :missing_content_digest}

      true ->
        :ok
    end
  end

  defp validate_body_digest(request, components) do
    if "content-digest" in components do
      case request do
        %{assigns: %{content_digest_valid: true}} -> :ok
        %{assigns: %{content_digest_valid: false}} -> {:error, :invalid_content_digest}
        _ -> validate_content_digest_header(request)
      end
    else
      :ok
    end
  end

  defp validate_content_digest_header(request) do
    case header_values(request, "content-digest") do
      [value] ->
        case Regex.run(~r/\Asha-256=:([A-Za-z0-9+\/=]+):\z/, value,
               capture: :all_but_first
             ) do
          [encoded] ->
            case Base.decode64(encoded) do
              {:ok, digest} when byte_size(digest) == 32 -> :ok
              _ -> {:error, :invalid_content_digest}
            end

          _ ->
            {:error, :invalid_content_digest}
        end

      _ ->
        {:error, :invalid_content_digest}
    end
  end

  defp signature_base(request, components, signature_parameters) do
    with {:ok, lines} <-
           Enum.reduce_while(components, {:ok, []}, fn component, {:ok, acc} ->
             case component_value(request, component) do
               {:ok, value} -> {:cont, {:ok, [quoted(component) <> ": " <> value | acc]}}
               error -> {:halt, error}
             end
           end) do
      base =
        lines
        |> Enum.reverse()
        |> Kernel.++([quoted("@signature-params") <> ": " <> signature_parameters])
        |> Enum.join("\n")

      {:ok, base}
    end
  end

  defp component_value(request, "@method"), do: {:ok, request_method(request)}
  defp component_value(request, "@target-uri"), do: target_uri(request)

  defp component_value(request, component) do
    case header_values(request, component) do
      [] -> {:error, :missing_component}
      values -> {:ok, Enum.join(values, ", ")}
    end
  end

  defp verify(base, signature, {:RSAPublicKey, _, _} = public_key) do
    :public_key.verify(base, :sha256, signature, public_key)
  end

  defp verify(_base, _signature, _public_key), do: false

  # ---------------------------------------------------------------------------
  # Request access helpers
  # ---------------------------------------------------------------------------

  defp request_method(%{method: method}) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp request_method(%{method: method}) when is_binary(method), do: String.upcase(method)
  defp request_method(_), do: ""

  defp target_uri(%{target_uri: target_uri}) when is_binary(target_uri),
    do: {:ok, target_uri}

  defp target_uri(%Conn{} = conn) do
    with [authority] <- header_values(conn, "host"),
         scheme when scheme in ["http", "https"] <- endpoint_scheme(),
         true <- valid_authority?(scheme, authority) do
      path = if conn.request_path in [nil, ""], do: "/", else: conn.request_path
      query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
      {:ok, scheme <> "://" <> authority <> path <> query}
    else
      _ -> {:error, :invalid_target_uri}
    end
  end

  defp target_uri(_), do: {:error, :invalid_target_uri}

  defp endpoint_scheme do
    Endpoint.url()
    |> URI.parse()
    |> Map.get(:scheme)
  rescue
    URI.Error -> nil
  end

  defp valid_authority?(scheme, authority) do
    not String.contains?(authority, ["\r", "\n", "/", " "]) and
      match?(%URI{host: host} when is_binary(host), URI.parse(scheme <> "://" <> authority))
  rescue
    URI.Error -> false
  end

  defp header_values(%Conn{} = conn, name), do: Conn.get_req_header(conn, name)

  defp header_values(%{req_headers: headers}, name) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: [value], else: []

      _ ->
        []
    end)
  end

  defp header_values(%{headers: headers}, name) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      if key |> to_string() |> String.downcase() == name do
        List.wrap(value) |> Enum.map(&to_string/1)
      else
        []
      end
    end)
  end

  defp header_values(_, _), do: []

  defp quoted(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  # Structured Field dictionaries can contain commas inside strings and inner
  # lists. Splitting only at top-level commas avoids label confusion.
  defp split_dictionary(value) when is_binary(value) do
    do_split_dictionary(value, [], [], false, false, 0)
  end

  defp split_dictionary(_), do: {:error, :malformed_dictionary}

  defp do_split_dictionary(<<>>, current, parts, false, false, 0) do
    append_dictionary_member(current, parts)
  end

  defp do_split_dictionary(<<>>, _current, _parts, _quoted, _escaped, _depth),
    do: {:error, :malformed_dictionary}

  defp do_split_dictionary(<<char, rest::binary>>, current, parts, quoted, escaped, depth) do
    cond do
      escaped ->
        do_split_dictionary(rest, [<<char>> | current], parts, quoted, false, depth)

      quoted and char == ?\\ ->
        do_split_dictionary(rest, [<<char>> | current], parts, quoted, true, depth)

      char == ?" ->
        do_split_dictionary(rest, [<<char>> | current], parts, not quoted, false, depth)

      not quoted and char == ?( ->
        do_split_dictionary(rest, [<<char>> | current], parts, quoted, false, depth + 1)

      not quoted and char == ?) and depth > 0 ->
        do_split_dictionary(rest, [<<char>> | current], parts, quoted, false, depth - 1)

      not quoted and char == ?) ->
        {:error, :malformed_dictionary}

      not quoted and char == ?, and depth == 0 ->
        with {:ok, parts} <- append_dictionary_member(current, parts) do
          do_split_dictionary(rest, [], Enum.reverse(parts), false, false, 0)
        end

      true ->
        do_split_dictionary(rest, [<<char>> | current], parts, quoted, false, depth)
    end
  end

  defp append_dictionary_member(current, parts) do
    member =
      current
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> String.trim()

    if member == "" do
      {:error, :empty_dictionary_member}
    else
      {:ok, Enum.reverse([member | parts])}
    end
  end
end

# end of message_signatures.ex
