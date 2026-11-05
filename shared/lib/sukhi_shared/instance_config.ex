# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceConfig do
  @moduledoc """
  The non-secret instance configuration shared by the gateway and API.

  A mounted JSON file keeps branding and web topology together while secrets
  remain environment variables or Podman secrets. The file is mandatory.
  """

  @default_path "/etc/sukhi/instance.json"
  @frontend_names ~w(relay web-next web-simple web-board web-lobby)
  @string_keys ~w(site_name site_logo site_icon unauthenticated_redirect)
  # Printed into /terms and /privacy, so the shape is checked here, once, at
  # the boundary: a name, one "@", a host. Nothing that could carry markup
  # or whitespace gets through. An ActivityPub handle may start with "@".
  @legal_patterns %{
    "contact_email" => ~r/\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\z/,
    "contact_activitypub" => ~r/\A@?[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\z/
  }

  @type t :: %{optional(String.t()) => term()}

  @spec path() :: String.t()
  def path, do: System.get_env("SUKHI_INSTANCE_CONFIG", @default_path)

  @spec load() :: t()
  def load do
    case File.read(path()) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{} = config} ->
            validate!(config)

          {:ok, _} ->
            raise ArgumentError, "instance config must be a JSON object: #{path()}"

          {:error, reason} ->
            raise ArgumentError, "invalid instance config #{path()}: #{inspect(reason)}"
        end

      {:error, :enoent} ->
        raise ArgumentError, "instance config is required: #{path()} does not exist"

      {:error, reason} ->
        raise ArgumentError, "cannot read instance config #{path()}: #{inspect(reason)}"
    end
  end

  @doc """
  Load the mounted config when it is available, otherwise return the empty
  topology used while assembling a release.

  Production entrypoints must call `load/0` before starting the release. This
  build-time fallback prevents `mix release` from requiring a deployment
  mount, without weakening the runtime startup gate.
  """
  @spec load_or_default() :: t()
  def load_or_default do
    if File.exists?(path()) do
      load()
    else
      %{"frontends" => %{}, "routes" => [], "addons" => %{}}
    end
  end

  @spec frontends(t()) :: %{String.t() => String.t()}
  def frontends(%{"frontends" => frontends}) when is_map(frontends) do
    for {name, %{"url" => url}} <- frontends, into: %{}, do: {name, url}
  end

  def frontends(_), do: %{}

  @spec active_frontends(t()) :: %{String.t() => String.t()}
  def active_frontends(config) do
    names =
      config
      |> routes()
      |> Enum.map(fn row ->
        [_pattern, frontend] = String.split(row, "=", parts: 2)
        frontend
      end)
      |> MapSet.new()

    config
    |> frontends()
    |> Enum.filter(fn {name, _url} -> MapSet.member?(names, name) end)
    |> Map.new()
  end

  @spec frontend_configured?(t()) :: boolean()
  def frontend_configured?(config), do: routes(config) not in [nil, []]

  @spec addon_enabled?(t(), String.t()) :: boolean()
  def addon_enabled?(%{"addons" => addons}, name) when is_map(addons),
    do: Map.get(addons, name) == true

  def addon_enabled?(_config, _name), do: false

  @spec unauthenticated_redirect(t()) :: String.t() | nil
  def unauthenticated_redirect(%{"unauthenticated_redirect" => url}) when is_binary(url), do: url
  def unauthenticated_redirect(_config), do: nil

  @doc """
  The operator-specific values printed on `/terms` and `/privacy`
  (`"legal"` in the instance config), keyed by atom. Only keys that are
  present come back; the flavor's own defaults fill the rest (see
  `SukhiFedi.Legal.Values`).
  """
  @spec legal(t()) :: %{optional(atom()) => String.t()}
  def legal(%{"legal" => legal}) when is_map(legal) do
    %{}
    |> put_legal(:contact_email, legal["contact_email"])
    |> put_legal(:contact_activitypub, legal["contact_activitypub"])
  end

  def legal(_config), do: %{}

  defp put_legal(acc, _key, nil), do: acc

  defp put_legal(acc, :contact_activitypub, "@" <> _ = handle),
    do: Map.put(acc, :contact_activitypub, handle)

  defp put_legal(acc, :contact_activitypub, handle),
    do: Map.put(acc, :contact_activitypub, "@" <> handle)

  defp put_legal(acc, key, value), do: Map.put(acc, key, value)

  @spec routes(t()) :: [String.t()] | nil
  def routes(%{"routes" => routes}) when is_list(routes) do
    Enum.map(routes, fn %{"pattern" => pattern, "frontend" => frontend} ->
      "#{pattern}=#{frontend}"
    end)
  end

  def routes(_), do: nil

  defp validate!(config) do
    for key <- @string_keys,
        Map.has_key?(config, key),
        not is_binary(config[key]) do
      raise ArgumentError, "instance config #{path()}: #{key} must be a string"
    end

    frontends = Map.get(config, "frontends")
    routes = Map.get(config, "routes")
    addons = Map.get(config, "addons", %{})
    redirect = Map.get(config, "unauthenticated_redirect")

    validate_frontends(frontends)
    validate_routes!(routes, frontends || %{})
    validate_addons!(addons)
    validate_redirect!(redirect)
    validate_legal!(Map.get(config, "legal", %{}))

    unless is_list(routes) do
      raise ArgumentError, "instance config #{path()}: routes must be an array"
    end

    config
  end

  defp validate_addons!(addons) when is_map(addons) do
    Enum.each(addons, fn
      {name, value} when is_binary(name) and is_boolean(value) ->
        :ok

      _ ->
        raise ArgumentError,
              "instance config #{path()}: addons must map names to booleans"
    end)
  end

  defp validate_addons!(_),
    do: raise(ArgumentError, "instance config #{path()}: addons must be an object")

  defp validate_legal!(legal) when is_map(legal) do
    for {key, value} <- legal do
      case Map.fetch(@legal_patterns, key) do
        :error ->
          raise ArgumentError, "instance config #{path()}: unsupported legal key #{key}"

        {:ok, pattern} ->
          unless is_binary(value) and Regex.match?(pattern, value) do
            raise ArgumentError,
                  "instance config #{path()}: legal.#{key} must look like name@host"
          end
      end
    end

    :ok
  end

  defp validate_legal!(_),
    do: raise(ArgumentError, "instance config #{path()}: legal must be an object")

  defp validate_redirect!(nil), do: :ok

  defp validate_redirect!(url) when is_binary(url) do
    unless String.starts_with?(url, ["http://", "https://"]) do
      raise ArgumentError,
            "instance config #{path()}: unauthenticated_redirect must be an http(s) URL"
    end
  end

  defp validate_redirect!(_),
    do: raise(ArgumentError, "instance config #{path()}: unauthenticated_redirect must be a URL")

  defp validate_frontends(frontends) when is_map(frontends) do
    for {name, definition} <- frontends do
      unless name in @frontend_names do
        raise ArgumentError, "instance config #{path()}: unsupported frontend #{name}"
      end

      case definition do
        %{"type" => "builtin"} when name == "relay" ->
          :ok

        %{"url" => url} when is_binary(url) ->
          unless String.starts_with?(url, ["http://", "https://"]) do
            raise ArgumentError, "instance config #{path()}: frontend #{name} URL must be http(s)"
          end

        _ ->
          raise ArgumentError,
                "instance config #{path()}: frontend #{name} needs type=builtin or url=http(s)"
      end
    end
  end

  defp validate_frontends(_),
    do: raise(ArgumentError, "instance config #{path()}: frontends must be an object")

  defp validate_routes!(routes, frontends) when is_list(routes) and is_map(frontends) do
    frontend_names = Map.keys(frontends) |> MapSet.new()

    Enum.each(routes, fn route ->
      with %{"pattern" => pattern, "frontend" => frontend} <- route,
           true <- is_binary(pattern) and String.starts_with?(pattern, "/"),
           true <- MapSet.member?(frontend_names, frontend) do
        :ok
      else
        _ ->
          raise ArgumentError,
                "instance config #{path()}: routes need pattern=/... and a declared frontend"
      end
    end)
  end

  defp validate_routes!(_, _),
    do: raise(ArgumentError, "instance config #{path()}: routes must be an array")
end
