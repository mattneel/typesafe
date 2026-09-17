# Live tests hit the real API and need TYPESAFE_API_KEY; run them with `mix test --only live`.
ExUnit.start(exclude: [:live])
