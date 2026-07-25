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

  When no `:selector` is provided, each top-level element in the HTML
  must have an `id` attribute so Datastar can target it by ID.

  The `html` argument may be `nil` when using `mode: :remove` (elements
  are not needed for removal).

  ## Options

  - `:selector` - CSS selector for target elements (optional — defaults to element ID)
  - `:mode` - Patch mode (default: :outer). Only non-default values are sent.
  - `:namespace` - Element namespace: `:html`, `:svg`, `:mathml` (default: :html)
  - `:use_view_transitions` - Enable View Transitions API (default: false)
  - `:event_id` - Event ID for client tracking
  - `:retry` - Retry duration in milliseconds

  ## Examples

      # Patch by element ID (no selector needed)
      conn |> patch("<div id=\\"feed\\">New content</div>")

      # Patch with explicit selector
      conn |> patch("<div>Content</div>", selector: "#target")

      # Update inner HTML only
      conn |> patch("<p>New text</p>", selector: ".content", mode: :inner)

      # Append to element
      conn |> patch("<li>Item</li>", selector: "ul", mode: :append)

      # Remove by selector (no HTML needed)
      conn |> patch(nil, selector: "#old", mode: :remove)

      # SVG namespace
      conn |> patch("<circle cx='50' cy='50' r='40'/>", selector: "#svg", namespace: :svg)

      # With view transitions
      conn |> patch("<div>Smooth</div>", selector: "#box", use_view_transitions: true)

  """
  @spec patch(Plug.Conn.t(), String.t() | Phoenix.HTML.safe() | nil, keyword()) :: Plug.Conn.t()
  def patch(conn, html, opts \\ []) do
    html = if is_nil(html), do: nil, else: to_html_string(html)
    selector = Keyword.get(opts, :selector)
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

    if is_nil(html) and mode != :remove do
      raise ArgumentError, "elements content is required unless mode is :remove"
    end

    data_lines =
      []
      |> maybe_add_selector(selector)
      |> maybe_add_mode(mode)
      |> maybe_add_namespace(namespace)
      |> maybe_add_view_transitions(use_view_transitions)
      |> maybe_add_elements(html)

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

  Sends a `datastar-patch-elements` event with `mode remove`.

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
    patch(conn, nil, Keyword.merge([selector: selector, mode: :remove], opts))
  end

  @doc """
  Appends `html` as the last child of `container`.

  The fast path for create-events on a **plain, unfiltered feed**. If the
  list is filtered, sorted or paginated, the stream cannot know this tab's
  view state — use `Dstar.Signals.nudge/3` instead. See the
  [Live collections](live-collections.html) guide.

  ## Example

      conn |> Dstar.Elements.append(post_row(%{post: post}), "#posts")

  """
  @spec append(Plug.Conn.t(), String.t() | Phoenix.HTML.safe(), String.t(), keyword()) ::
          Plug.Conn.t()
  def append(conn, html, container, opts \\ []) when is_binary(container) do
    patch(conn, html, Keyword.merge([selector: container, mode: :append], opts))
  end

  @doc """
  Morphs the element whose DOM `id` matches the root element of `html`.

  Sends no selector, so Datastar targets by id.

  > #### Dropped when absent {: .warning}
  >
  > If the tab has no element with that id, Datastar logs
  > `PatchElementsNoTargetsFound` and drops the patch — a row this tab never
  > rendered stays absent. That is fine for a plain feed; when it is not
  > (filtered, sorted or paginated lists), use `Dstar.Signals.nudge/3`.

  ## Example

      conn |> Dstar.Elements.upsert(post_row(%{post: post}))

  """
  @spec upsert(Plug.Conn.t(), String.t() | Phoenix.HTML.safe(), keyword()) :: Plug.Conn.t()
  def upsert(conn, html, opts \\ []) do
    patch(conn, html, opts)
  end

  @doc """
  Formats an element patch as an SSE event string (for stateless responses).

  ## Example

      format_patch("<div id=\\"feed\\">content</div>")
      format_patch("<div>content</div>", selector: "#target")
      format_patch("<circle r='10'/>", selector: "#svg", namespace: :svg)

  """
  @spec format_patch(String.t() | Phoenix.HTML.safe() | nil, keyword()) :: String.t()
  def format_patch(html, opts \\ []) do
    html = if is_nil(html), do: nil, else: to_html_string(html)
    selector = Keyword.get(opts, :selector)
    mode = Keyword.get(opts, :mode, @default_patch_mode)
    namespace = Keyword.get(opts, :namespace, :html)
    use_view_transitions = Keyword.get(opts, :use_view_transitions, @default_use_view_transitions)

    unless namespace in @valid_namespaces do
      raise ArgumentError,
            "Invalid namespace: #{inspect(namespace)}. Must be one of #{inspect(@valid_namespaces)}"
    end

    if is_nil(html) and mode != :remove do
      raise ArgumentError, "elements content is required unless mode is :remove"
    end

    data_lines =
      []
      |> maybe_add_selector(selector)
      |> maybe_add_mode(mode)
      |> maybe_add_namespace(namespace)
      |> maybe_add_view_transitions(use_view_transitions)
      |> maybe_add_elements(html)

    SSE.format_event(@event_type, data_lines)
  end

  @doc """
  Formats an element removal as an SSE event string (for stateless responses).

  ## Example

      format_remove("#target")
      # => "event: datastar-patch-elements\\ndata: mode remove\\ndata: selector #target\\n\\n"

  """
  @spec format_remove(String.t(), keyword()) :: String.t()
  def format_remove(selector, opts \\ []) when is_binary(selector) do
    format_patch(nil, Keyword.merge([selector: selector, mode: :remove], opts))
  end

  # Private helpers

  defp maybe_add_selector(lines, nil), do: lines

  defp maybe_add_selector(lines, selector) do
    lines ++ ["selector " <> single_line(selector)]
  end

  # `selector` is a single-valued SSE field, but `Dstar.SSE` splits every
  # `data:` value on line terminators so multi-line `elements` HTML frames
  # correctly. A line break here would therefore open a *second* field in the
  # same event — and the client accumulates repeated fields rather than
  # overwriting them, so an injected `elements` line is prepended to the real
  # HTML and morphed into the DOM. Any selector built from untrusted data
  # (a record id, a slug) would be a stored-XSS vector. Line terminators are
  # meaningless in a CSS selector, so dropping them loses nothing.
  defp single_line(value) when is_binary(value) do
    String.replace(value, ["\r\n", "\r", "\n"], "")
  end

  defp maybe_add_mode(lines, :outer), do: lines

  defp maybe_add_mode(lines, mode) do
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

  defp maybe_add_elements(lines, nil), do: lines

  defp maybe_add_elements(lines, html) do
    # Split on every SSE line terminator (CR, LF, CRLF) so each physical line
    # of HTML becomes its own `data: elements <line>`. Splitting only on LF
    # would let a lone CR survive inside a single data line, where the client
    # re-splits on it — forging additional SSE events (see Dstar.SSE).
    html_lines =
      html
      |> String.split(["\r\n", "\r", "\n"])
      |> Enum.map(&("elements " <> &1))

    lines ++ html_lines
  end
end
