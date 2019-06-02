defmodule Tesla.Adapter.Mint do
  @moduledoc """
    Adapter for [mint](https://github.com/ericmj/mint)

    Caution: The minimum supported Elixir version for mint is 1.5.0

    Remember to add `{:mint, "~> 0.2.0"}` and `{:castore, "~> 0.1.0"}` to dependencies
    Also, you need to recompile tesla after adding `:mint` dependency:

    ```
    mix deps.clean tesla
    mix deps.compile tesla
    ```

    ### Example usage
    ```
    # set globally in config/config.exs
    config :tesla, :adapter, Tesla.Adapter.Mint

    # set per module
    defmodule MyClient do
      use Tesla

      adapter Tesla.Adapter.Mint
    end

    # set custom cacert
    config :tesla, Mint, cacert: ["path_to_cacert"]
  """
  @behaviour Tesla.Adapter
  import Tesla.Adapter.Shared, only: [stream_to_fun: 1, next_chunk: 1]
  alias Tesla.Multipart
  alias Mint.HTTP

  @doc false
  def call(env, opts) do
    with {:ok, status, headers, body} <- request(env, opts) do
      {:ok, %{env | status: status, headers: format_headers(headers), body: body}}
    end
  end

  defp format_headers(headers) do
    for {key, value} <- headers do
      {String.downcase(to_string(key)), to_string(value)}
    end
  end

  defp request(env, opts) do
    # Break the URI
    %URI{host: host, scheme: scheme, port: port, path: path, query: query} = URI.parse(env.url)
    query = (query || "") |> URI.decode_query() |> Map.to_list()
    path = Tesla.build_url(path, env.query ++ query)

    method =
      case env.method do
        :head -> "GET"
        m -> m |> Atom.to_string() |> String.upcase()
      end

    opts =
      if opts |> get_in([:transport_opts, :cacertfile]) |> is_nil() && scheme == "https" &&
           !is_nil(get_default_ca()) do
        transport =
          opts
          |> Access.get(:transport_opts, [])
          |> update_in([:cacertfile], fn _ ->
            get_default_ca()
          end)

        update_in(opts, [:transport_opts], fn _ ->
          transport
        end)
      else
        opts
      end

    request(
      method,
      scheme,
      host,
      port,
      path,
      env.headers,
      env.body,
      opts
    )
  end

  defp request(method, scheme, host, port, path, headers, %Stream{} = body, opts) do
    fun = stream_to_fun(body)
    request(method, scheme, host, port, path, headers, fun, opts)
  end

  defp request(method, scheme, host, port, path, headers, %Multipart{} = body, opts) do
    headers = headers ++ Multipart.headers(body)
    fun = stream_to_fun(Multipart.body(body))
    request(method, scheme, host, port, path, headers, fun, opts)
  end

  defp request(method, scheme, host, port, path, headers, body, opts) when is_function(body) do
    with {:ok, conn} <- HTTP.connect(String.to_atom(scheme), host, port, opts),
         # FIXME Stream function in Mint will not append the content length after eof
         # This will trigger the failure in unit test
         {:ok, body, length} <- stream_request(body),
         {:ok, conn, _req_ref} <-
           HTTP.request(
             conn,
             method,
             path || "/",
             headers ++ [{"content-length", "#{length}"}],
             body
           ),
         {:ok, _conn, res = %{status: status, headers: headers}} <- stream_response(conn) do
      {:ok, status, headers, Map.get(res, :data)}
    end
  end

  defp request(method, scheme, host, port, path, headers, body, opts) do
    with {:ok, conn} <- HTTP.connect(String.to_atom(scheme), host, port, opts),
         {:ok, conn, _req_ref} <- HTTP.request(conn, method, path || "/", headers, body || ""),
         {:ok, _conn, res = %{status: status, headers: headers}} <- stream_response(conn) do
      {:ok, status, headers, Map.get(res, :data)}
    end
  end

  defp get_default_ca() do
    env = Application.get_env(:tesla, Mint)
    Keyword.get(env, :cacert)
  end

  defp stream_request(fun, body \\ "") do
    case next_chunk(fun) do
      {:ok, item, fun} when is_list(item) ->
        stream_request(fun, body <> List.to_string(item))

      {:ok, item, fun} ->
        stream_request(fun, body <> item)

      :eof ->
        {:ok, body, byte_size(body)}
    end
  end

  defp stream_response(conn, response \\ %{}) do
    receive do
      msg ->
        case HTTP.stream(conn, msg) do
          {:ok, conn, stream} ->
            response =
              Enum.reduce(stream, response, fn x, acc ->
                case x do
                  {:status, _req_ref, code} ->
                    Map.put(acc, :status, code)

                  {:headers, _req_ref, headers} ->
                    Map.put(acc, :headers, headers)

                  {:data, _req_ref, data} ->
                    Map.put(acc, :data, Map.get(acc, :data, "") <> data)

                  {:done, _req_ref} ->
                    Map.put(acc, :done, true)

                  _ ->
                    acc
                end
              end)

            if Map.get(response, :done) do
              {:ok, conn, Map.drop(response, [:done])}
            else
              stream_response(conn, response)
            end

          {:error, _conn, error, _res} ->
            {:error, "Encounter Mint error #{inspect(error)}"}

          :unknown ->
            {:error, "Encounter unknown error"}
        end
    end
  end
end
