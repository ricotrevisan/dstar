{:ok, _} = Registry.start_link(keys: :unique, name: Dstar.Utility.StreamRegistry)
ExUnit.start()
