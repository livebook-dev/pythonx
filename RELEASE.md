# Releasing Pythonx

1. Update version in `mix.exs` and update CHANGELOG.
2. Run `git tag x.y.z` and `git push --tags`.
   1. Wait for CI to precompile all artifacts.
3. Publish GH release with copied changelog notes (CI creates a draft, we need to publish it to compute the checksum).
4. Run `mix elixir_make.checksum --all`.
5. Run `mix hex.publish`.
6. Bump version in `mix.exs` and add `-dev`.
