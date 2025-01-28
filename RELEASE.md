# Releasing Pythonx

1. Update version in `mix.exs` and update CHANGELOG.
2. Run `git tag x.y.z` and `git push --tags`.
   1. Wait for CI to precompile all artifacts.
3. Run `mix elixir_make.checksum --all`.
4. Run `mix hex.publish`.
5. Bump version in `mix.exs` and add `-dev`.
