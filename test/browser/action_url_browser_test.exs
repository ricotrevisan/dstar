defmodule Dstar.ActionUrlBrowserTest do
  use ExUnit.Case, async: false

  @moduletag :browser

  defmodule BrowserComponent do
    use Dstar.Component
  end

  test "evaluated expressions keep caller values in one same-origin URL segment" do
    values = ["/", "\\", "a.b", "a..b", "?", "#", "%2f", "\r\n", "'\"", "café/東京"]

    cases =
      Enum.flat_map(values, fn value ->
        [
          %{kind: "static", value: value, expression: Dstar.post(String, value)},
          %{
            kind: "page",
            value: value,
            expression: Dstar.Page.Helpers.event(value),
            pathname: "//evil.test/workspace/page/"
          },
          %{
            kind: "component",
            value: value,
            expression: BrowserComponent.event(value),
            dsBase: "/workspace/ds/"
          },
          %{
            kind: "dynamic",
            value: value,
            expression: Dstar.post("save"),
            dynamicModule: value
          },
          %{
            kind: "literal_module",
            value: value,
            expression: Dstar.post("save", module: value)
          }
        ]
      end)

    results = evaluate_in_browser(cases)

    Enum.zip(cases, results)
    |> Enum.each(fn {test_case, result} ->
      assert result["alerted"] == false
      assert result["callCount"] == 1
      assert result["origin"] == "https://app.test"

      {expected_count, value_index} =
        case test_case.kind do
          "static" -> {3, 2}
          "page" -> {5, 4}
          "component" -> {4, 3}
          "dynamic" -> {3, 1}
          "literal_module" -> {3, 1}
        end

      assert length(result["rawSegments"]) == expected_count
      assert Enum.at(result["decodedSegments"], value_index) == test_case.value
    end)
  end

  test "stream connect path cannot become a protocol-relative target" do
    cases = [
      %{
        expression: Dstar.Page.Helpers.connect(),
        pathname: "//evil.test/workspace/page"
      },
      %{
        expression: Dstar.Page.Helpers.connect(include_search: true),
        pathname: "//evil.test/workspace/page"
      }
    ]

    for result <- evaluate_in_browser(cases) do
      assert result["callCount"] == 1
      assert result["origin"] == "https://app.test"
      assert result["pathname"] == "/evil.test/workspace/page"
    end
  end

  test "quote payloads cannot add a statement to the evaluated action" do
    event_payload = "x');alert(document.domain);//"
    prefix_payload = "');alert(1);//"
    module_payload = "x');alert(1);//"

    assert_raise ArgumentError, fn ->
      Dstar.post(String, "save", prefix: prefix_payload)
    end

    cases = [
      %{expression: Dstar.post(String, event_payload)},
      %{expression: Dstar.post(String, "save", prefix: "/x');alert(1);//")},
      %{expression: Dstar.post("save", module: module_payload)},
      %{expression: Dstar.Page.Helpers.event(event_payload), pathname: "/page"},
      %{
        expression: BrowserComponent.event(event_payload),
        dsBase: "/ds"
      }
    ]

    for result <- evaluate_in_browser(cases) do
      assert result["alerted"] == false
      assert result["callCount"] == 1
      assert result["origin"] == "https://app.test"
    end
  end

  test "runtime module and component base reject retargeting values" do
    cases = [
      %{expression: Dstar.post("save"), dynamicModule: ""},
      %{expression: Dstar.post("save"), dynamicModule: "."},
      %{expression: Dstar.post("save"), dynamicModule: ".."},
      %{expression: BrowserComponent.event("save"), dsBase: "//evil.test/ds"},
      %{expression: BrowserComponent.event("save"), dsBase: "/\\evil.test/ds"},
      %{expression: BrowserComponent.event("save"), dsBase: "/ds?target=evil"},
      %{expression: BrowserComponent.event("save"), dsBase: "/%2F%2Fevil.test/ds"},
      %{expression: BrowserComponent.event("save"), dsBase: "/%5Cevil.test/ds"},
      %{expression: BrowserComponent.event("save"), dsBase: "/a/../ds"},
      %{expression: BrowserComponent.event("save"), dsBase: "/a/%2E%2E/ds"}
    ]

    for result <- evaluate_in_browser(cases) do
      assert result["callCount"] == 0
      assert result["error"] =~ ~r/invalid Dstar (module segment|component base)/
    end
  end

  defp evaluate_in_browser(cases) do
    node = System.find_executable("node") || flunk("Node.js is required for browser tests")
    fixture = Path.expand("evaluate_actions.mjs", __DIR__)

    input =
      Path.join(System.tmp_dir!(), "dstar_browser_#{System.unique_integer([:positive])}.json")

    File.write!(input, Jason.encode!(cases))
    on_exit(fn -> File.rm(input) end)

    case System.cmd(node, [fixture, input], cd: File.cwd!(), env: [{"FORCE_COLOR", nil}]) do
      {json, 0} -> Jason.decode!(json)
      {output, status} -> flunk("browser fixture exited with #{status}:\n#{output}")
    end
  end
end
