defmodule Pythonx.Utils do
  @moduledoc false

  require Logger

  @doc """
  Makes a GET request to the given URL and returns the body.
  """
  @spec fetch_body!(String.t()) :: binary()
  def fetch_body!(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    # Starting an HTTP client profile allows us to scope the httpc
    # configuration options, such as proxy options.
    {:ok, _pid} = :inets.start(:httpc, profile: :pythonx)

    %{scheme: scheme} = URI.parse(url)

    proxy_http_options = set_proxy_options(scheme)

    headers = [{~c"user-agent", ~c"pythonx"}]

    http_options =
      [
        ssl: [
          cacerts: :public_key.cacerts_get(),
          verify: :verify_peer,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ] ++ proxy_http_options

    options = [body_format: :binary]

    request = {url, headers}

    case request(request, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} -> body
      other -> raise "failed to fetch #{url}, error: #{inspect(other)}"
    end
  after
    :inets.stop(:httpc, :pythonx)
  end

  defp request(request, http_options, options) do
    case :httpc.request(:get, request, http_options, options, :pythonx) do
      {:error, {:failed_connect, [{:to_address, _}, {inet, _, reason}]}}
      when inet in [:inet, :inet6] and
             reason in [:ehostunreach, :enetunreach, :eprotonosupport, :nxdomain] ->
        # If the error is related to IP family, we retry with the other one.
        :httpc.set_options([ipfamily: fallback_ipfamily(inet)], :pythonx)
        :httpc.request(:get, request, http_options, options, :pythonx)

      other ->
        other
    end
  end

  defp fallback_ipfamily(:inet), do: :inet6
  defp fallback_ipfamily(:inet6), do: :inet

  defp set_proxy_options(scheme) do
    case proxy_for_scheme(scheme) do
      {option_name, proxy} ->
        %{host: host, port: port} = URI.parse(proxy)
        Logger.debug("Using #{scheme} proxy: #{proxy}")
        :httpc.set_options([{option_name, {{String.to_charlist(host), port}, []}}], :pythonx)
        proxy_auth_options(proxy)

      nil ->
        []
    end
  end

  defp proxy_for_scheme("http") do
    if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      {:proxy, proxy}
    end
  end

  defp proxy_for_scheme("https") do
    if proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      {:https_proxy, proxy}
    end
  end

  defp proxy_auth_options(proxy) do
    with %{userinfo: userinfo} when is_binary(userinfo) <- URI.parse(proxy),
         [username, password] <- String.split(userinfo, ":") do
      [proxy_auth: {String.to_charlist(username), String.to_charlist(password)}]
    else
      _ -> []
    end
  end
end
