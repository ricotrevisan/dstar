defmodule Dstar.Utility.StreamRegistryTest do
  use ExUnit.Case, async: false

  test "replace_and_register replaces previous process for same key" do
    key = {make_ref(), make_ref()}

    pid1 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key)
        Process.sleep(:infinity)
      end)

    ref = Process.monitor(pid1)
    Process.sleep(50)

    # Verify pid1 is registered
    assert [{^pid1, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)

    # Second registration should kill pid1
    Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert_receive {:DOWN, ^ref, :process, ^pid1, :replaced}

    # Current process is now registered
    assert [{pid, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)
    assert pid == self()
  end

  test "different keys coexist" do
    key1 = {make_ref(), make_ref()}
    key2 = {make_ref(), make_ref()}

    pid1 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key1)
        Process.sleep(:infinity)
      end)

    pid2 =
      spawn(fn ->
        Dstar.Utility.StreamRegistry.replace_and_register(key2)
        Process.sleep(:infinity)
      end)

    Process.sleep(50)
    assert Process.alive?(pid1)
    assert Process.alive?(pid2)

    Process.exit(pid1, :kill)
    Process.exit(pid2, :kill)
  end

  test "no-op when no previous process exists" do
    key = {make_ref(), make_ref()}

    assert :ok = Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert [{pid, _}] = Registry.lookup(Dstar.Utility.StreamRegistry, key)
    assert pid == self()
  end

  test "same process re-registering does not kill self" do
    key = {make_ref(), make_ref()}

    Dstar.Utility.StreamRegistry.replace_and_register(key)
    Dstar.Utility.StreamRegistry.replace_and_register(key)

    assert Process.alive?(self())
  end
end
