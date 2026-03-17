defmodule Dstar.Elements do
  @moduledoc """
  Functions for patching and removing DOM elements via SSE.

      conn |> patch("<div>New content</div>", selector: "#target")
      conn |> patch("<p>Inner</p>", selector: "#target", mode: :inner)
      conn |> remove("#target")
  """

  alias Dstar.SSE

  # Event type for element patches
  @event_type "datastar-patch-elements"

  # Default values
  @default_patch_mode :outer
  @default_use_view_transitions false

  # Valid patch modes
  @valid_modes ~w(outer inner remove replace prepend append before after)a
  @valid_namespaces ~w(html svg mathml)a

  @doc """
  Patches DOM elements with new HTML content.

  ## Options

  - `:selector` - CSS selector for target elements (required)
  - `:mode` - Patch mode (default: :outer)
  - `:namespace` - Element namespace: `:html`, `:svg`, `:mathml` (default: :html)
  - `:use_view_transitions` - Enable View Transitions API (default: false)
  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  ## Examples

      # Replace entire element
      conn |> patch("<div>Content</div>", selector: "#target")

      # Update inner HTML only
      conn |> patch("<p>New text</p>", selector: ".content", mode: :inner)

      # Append to element
      conn |> patch("<li>Item</li>", selector: "ul", mode: :append)

      # SVG namespace
      conn |> patch("<circle cx='50' cy='50' r='40'/>", selector: "#svg", namespace: :svg)

      # With view transitions
      conn |> patch("<div>Smooth</div>", selector: "#box", use_view_transitions: true)

  """
  @spec patch(Plug.Conn.t(), String.t() | Phoenix.HTML.safe(), keyword()) :: Plug.Conn.t()
  def patch(conn, html, opts \\ []) do
    html = to_html_string(html)
    selector = Keyword.fetch!(opts, :selector)
    mode = Keyword.get(opts, :mode, @default_patch_mode)
    namespace = Keyword.get(opts, :namespace, :html)
    use_view_transitions = Keyword.get(opts, :use_view_transitions, @default_use_view_transitions)

    unless mode in @valid_modes do
      raise ArgumentError, "Invalid patch mode: #{inspect(mode)}"
    end

    unless namespace in @valid_namespaces do
      raise ArgumentError,
            "Invalid namespace: #{inspect(namespace)}. Must be one of #{inspect(@valid_namespaces)}"
    end

    data_lines =
      []
      |> add_selector(selector)
      |> add_mode(mode)
      |> maybe_add_namespace(namespace)
      |> maybe_add_view_transitions(use_view_transitions)
      |> add_elements(html)

    event_opts =
      [
        event_id: opts[:event_id],
        retry: opts[:retry]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    SSE.send_event!(conn, @event_type, data_lines, event_opts)
  end

  @doc """
  Removes elements from the DOM by selector.

  ## Options

  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  ## Example

      conn
      |> Dstar.Elements.remove(".temporary")
      |> Dstar.Elements.remove("#old-content")

  """
  @spec remove(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def remove(conn, selector, opts \\ []) when is_binary(selector) do
    data_lines = ["selector " <> selector]

    event_opts =
      [
        event_id: opts[:event_id],
        retry: opts[:retry]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    SSE.send_event!(conn, @event_type, data_lines, event_opts)
  end

  @doc """
  Formats an element patch as an SSE event string (for stateless responses).

  ## Example

      format_patch("<div>content</div>", selector: "#target", mode: :outer)
      format_patch("<circle r='10'/>", selector: "#svg", namespace: :svg)

  """
  @spec format_patch(String.t() | Phoenix.HTML.safe(), keyword()) :: String.t()
  def format_patch(html, opts \\ []) do
    html = to_html_string(html)
    selector = Keyword.fetch!(opts, :selector)
    mode = Keyword.get(opts, :mode, @default_patch_mode)
    namespace = Keyword.get(opts, :namespace, :html)
    use_view_transitions = Keyword.get(opts, :use_view_transitions, @default_use_view_transitions)

    unless namespace in @valid_namespaces do
      raise ArgumentError,
            "Invalid namespace: #{inspect(namespace)}. Must be one of #{inspect(@valid_namespaces)}"
    end

    data_lines =
      []
      |> add_selector(selector)
      |> add_mode(mode)
      |> maybe_add_namespace(namespace)
      |> maybe_add_view_transitions(use_view_transitions)
      |> add_elements(html)

    SSE.format_event(@event_type, data_lines)
  end

  # Private helpers

  defp add_selector(lines, selector) do
    lines ++ ["selector " <> selector]
  end

  defp add_mode(lines, mode) do
    lines ++ ["mode " <> to_string(mode)]
  end

  defp maybe_add_namespace(lines, :html), do: lines

  defp maybe_add_namespace(lines, namespace) do
    lines ++ ["namespace " <> to_string(namespace)]
  end

  defp maybe_add_view_transitions(lines, false), do: lines

  defp maybe_add_view_transitions(lines, true) do
    lines ++ ["useViewTransition true"]
  end

  defp to_html_string(html) when is_binary(html), do: html

  defp to_html_string({:safe, iodata}), do: IO.iodata_to_binary(iodata)

  defp to_html_string(other) do
    if Code.ensure_loaded?(Phoenix.HTML.Safe) do
      other
      |> then(&apply(Phoenix.HTML.Safe, :to_iodata, [&1]))
      |> IO.iodata_to_binary()
    else
      raise ArgumentError,
            "expected a binary string or {:safe, iodata} tuple, got: #{inspect(other)}"
    end
  end

  defp add_elements(lines, html) do
    html_lines =
      html
      |> String.split("\n")
      |> Enum.map(&("elements " <> &1))

    lines ++ html_lines
  end
end
