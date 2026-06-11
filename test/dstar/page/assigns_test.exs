defmodule Dstar.Page.AssignsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  import Dstar.Page.Assigns

  describe "assign/2,3 with %Plug.Conn{}" do
    test "assign/3 sets a conn assign" do
      conn = conn(:get, "/") |> assign(:count, 1)
      assert conn.assigns.count == 1
    end

    test "assign/2 sets multiple assigns from a keyword list" do
      conn = conn(:get, "/") |> assign(count: 1, name: "rico")
      assert conn.assigns.count == 1
      assert conn.assigns.name == "rico"
    end

    test "assign/2 sets multiple assigns from a map" do
      conn = conn(:get, "/") |> assign(%{count: 2})
      assert conn.assigns.count == 2
    end
  end

  describe "assign_new/3 with %Plug.Conn{}" do
    test "assigns when key is absent" do
      conn = conn(:get, "/") |> assign_new(:count, fn -> 5 end)
      assert conn.assigns.count == 5
    end

    test "keeps existing value" do
      conn = conn(:get, "/") |> assign(:count, 1) |> assign_new(:count, fn -> 5 end)
      assert conn.assigns.count == 1
    end

    test "supports arity-1 fun receiving current assigns" do
      conn =
        conn(:get, "/")
        |> assign(:base, 10)
        |> assign_new(:count, fn assigns -> assigns.base + 1 end)

      assert conn.assigns.count == 11
    end
  end

  describe "update/3 with %Plug.Conn{}" do
    test "updates an existing assign" do
      conn = conn(:get, "/") |> assign(:count, 1) |> update(:count, &(&1 + 1))
      assert conn.assigns.count == 2
    end

    test "raises when key is missing" do
      assert_raise KeyError, fn ->
        conn(:get, "/") |> update(:missing, &(&1 + 1))
      end
    end
  end

  describe "delegation to Phoenix.Component for non-conn values" do
    test "assign/3 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign(assigns, :count, 1).count == 1
    end

    test "assign/2 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign(assigns, count: 3).count == 3
    end

    test "assign_new/3 works on an assigns map" do
      assigns = %{__changed__: nil}
      assert assign_new(assigns, :count, fn -> 7 end).count == 7
    end

    test "update/3 works on an assigns map" do
      assigns = %{__changed__: nil, count: 1}
      assert update(assigns, :count, &(&1 + 1)).count == 2
    end
  end
end
