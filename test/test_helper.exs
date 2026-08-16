{:ok, _} = Dstar.Utility.StreamRegistry.start(grace_ms: 100)
ExUnit.start(exclude: [:browser])
