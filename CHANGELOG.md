# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.4.2](https://github.com/livebook-dev/pythonx/tree/v0.4.2) (2025-02-27)

### Changed

* `~PY` sigil to not reference undefined Elixir variables ([#12](https://github.com/livebook-dev/pythonx/pull/12))

## [v0.4.1](https://github.com/livebook-dev/pythonx/tree/v0.4.1) (2025-02-25)

### Fixed

* `~PY` sigil triggering unused variable warnings ([#6](https://github.com/livebook-dev/pythonx/pull/6))
* Segmentation fault caused by using libraries depending on pybind11 ([#9](https://github.com/livebook-dev/pythonx/pull/9))

## [v0.4.0](https://github.com/livebook-dev/pythonx/tree/v0.4.0) (2025-02-21)

### Added

* Options to `Pythonx.eval/3` for customizing stdout and stderr destination ([#5](https://github.com/livebook-dev/pythonx/pull/5))

### Removed

* Removed `Pythonx.init/3` in favour of always using `Pythonx.uv_init/2` ([#4](https://github.com/livebook-dev/pythonx/pull/4))

### Fixed

* `sys.executable` to point to a Python executable, instead of the BEAM one ([#4](https://github.com/livebook-dev/pythonx/pull/4))

## [v0.3.0](https://github.com/livebook-dev/pythonx/tree/v0.3.0) (2025-02-19)

Initial release.

## Previous versions

Prior to v0.3, this package was being published and developed in [this repository](https://github.com/elixir-pythonx/pythonx).
