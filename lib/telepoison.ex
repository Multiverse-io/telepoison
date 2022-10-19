defmodule Telepoison do
  @moduledoc """
  OpenTelemetry-instrumented wrapper around HTTPoison.Base

  A client request span is created on request creation, and ended once we get the response.
  http.status and other standard http span attributes are set automatically.
  """

  use HTTPoison.Base

  require OpenTelemetry
  require OpenTelemetry.Tracer
  require OpenTelemetry.Span
  require Record

  alias HTTPoison.Request
  alias OpenTelemetry.Tracer

  @doc """
  Setups the opentelemetry instrumentation for Telepoison

  You should call this method on your application startup, before Telepoison is used.
  """
  def setup do
    :ok
  end

  @impl HTTPoison.Base
  def process_request_headers(headers) when is_map(headers) do
    headers
    |> Enum.into([])
    |> process_request_headers()
  end

  @impl HTTPoison.Base
  def process_request_headers(headers) when is_list(headers) do
    :otel_propagator_text_map.inject(headers)
  end

  @impl HTTPoison.Base
  def request(%Request{options: opts} = request) do
    save_parent_ctx()
    span_name = Keyword.get_lazy(opts, :ot_span_name, fn -> compute_default_span_name(request) end)
    %URI{host: host} = request.url |> process_request_url() |> URI.parse()

    attributes =
      [
        {"http.method", request.method |> Atom.to_string() |> String.upcase()},
        {"http.url", request.url},
        {"net.peer.name", host}
      ] ++ Keyword.get(opts, :ot_attributes, [])

    request_ctx = Tracer.start_span(span_name, %{kind: :client, attributes: attributes})
    Tracer.set_current_span(request_ctx)

    result = super(request)

    if Tracer.current_span_ctx() == request_ctx do
      case result do
        {:error, %{reason: reason}} ->
          Tracer.set_status(:error, inspect(reason))
          end_span()

        _ ->
          :ok
      end
    end

    result
  end

  @impl HTTPoison.Base
  def process_response_status_code(status_code) do
    # https://github.com/open-telemetry/opentelemetry-specification/blob/master/specification/trace/semantic_conventions/http.md#status
    if status_code >= 400 do
      Tracer.set_status(:error, "")
    end

    Tracer.set_attribute("http.status_code", status_code)
    end_span()
    status_code
  end

  @impl HTTPoison.Base
  def process_headers(headers) do
    content_length =
      Enum.find_value(headers, fn {header, value} ->
        if String.downcase(header) == "content-length" do
          value
        else
          nil
        end
      end)

    with cl when not is_nil(cl) <- content_length,
         {parsed, ""} <- Integer.parse(cl)
      do
      Tracer.set_attribute("http.response_content_length", parsed)
    end

    headers
  end

  defp end_span do
    Tracer.end_span()
    restore_parent_ctx()
  end

  def compute_default_span_name(request) do
    method_str = request.method |> Atom.to_string() |> String.upcase()
    %URI{authority: authority} = request.url |> process_request_url() |> URI.parse()
    "#{method_str} #{authority}"
  end

  @ctx_key {__MODULE__, :parent_ctx}
  defp save_parent_ctx do
    ctx = Tracer.current_span_ctx()
    Process.put(@ctx_key, ctx)
  end

  defp restore_parent_ctx do
    ctx = Process.get(@ctx_key, :undefined)
    Process.delete(@ctx_key)
    Tracer.set_current_span(ctx)
  end
end
