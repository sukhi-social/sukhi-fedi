# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceConfig do
  @moduledoc """
  The non-secret instance configuration shared by the gateway and API.

  A mounted JSON file keeps branding and web topology together while secrets
  remain environment variables or Podman secrets. The file is mandatory.
  """

  @default_path "/etc/sukhi/instance.json"
  @frontend_names ~w(relay web-next web-simple web-board web-room)
  @string_keys ~w(site_name site_logo site_icon unauthenticated_redirect)

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
  The directory holding this instance's own terms and privacy policy
  (`legal.dir` in the instance config), or `nil` when the instance serves the
  documents bundled with the release. Absolute; whether it exists and holds
  documents is checked when the gateway starts
  (`SukhiFedi.Legal.Documents.install!/1`).
  """
  @spec legal_dir(t()) :: String.t() | nil
  def legal_dir(%{"legal" => %{"dir" => dir}}) when is_binary(dir), do: dir
  def legal_dir(_config), do: nil

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

  defp validate_legal!(%{"dir" => dir} = legal) when map_size(legal) == 1 do
    unless is_binary(dir) and Path.type(dir) == :absolute do
      raise ArgumentError, "instance config #{path()}: legal.dir must be an absolute path"
    end

    :ok
  end

  defp validate_legal!(legal) when legal == %{}, do: :ok

  defp validate_legal!(_),
    do:
      raise(ArgumentError, ~s(instance config #{path()}: legal must be {"dir": "/absolute/path"}))

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
