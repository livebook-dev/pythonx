#pragma once

#include <string>

#if defined(_WIN32)
// Windows

#include <windows.h>

namespace pythonx::dl {

using LibraryHandle = HMODULE;

inline LibraryHandle open_library(const char *name) {
  return LoadLibrary(name);
}

inline void *get_symbol(LibraryHandle lib, const char *name) {
  return reinterpret_cast<void *>(GetProcAddress(lib, name));
}

inline bool close_library(LibraryHandle lib) { return FreeLibrary(lib); }

inline std::string error() {
  auto code = GetLastError();
  if (code == 0) {
    return nullptr;
  }

  return "code " + std::to_string(code);
}

} // namespace pythonx::dl

#else
// Unix

#include <dlfcn.h>

namespace pythonx::dl {

using LibraryHandle = void *;

inline LibraryHandle open_library(const char *name) {
  // Note that we want RTLD_GLOBAL, so that Python library symbols
  // are visible to Python C extensions.
  return dlopen(name, RTLD_GLOBAL | RTLD_LAZY);
}

inline void *get_symbol(LibraryHandle lib, const char *name) {
  return dlsym(lib, name);
}

inline bool close_library(LibraryHandle lib) { return dlclose(lib) == 0; }

inline std::string error() { return dlerror(); }

} // namespace pythonx::dl

#endif
