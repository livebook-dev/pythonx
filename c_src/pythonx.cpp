#include <cstddef>
#include <erl_nif.h>
#include <fine.hpp>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <tuple>
#include <unordered_map>

#include "python.hpp"

extern "C" void pythonx_handle_io_write(const char *message,
                                        const char *eval_info_bytes, bool type);

extern "C" void
pythonx_handle_send_tagged_object(const char *pid_bytes, const char *tag,
                                  pythonx::python::PyObjectPtr *py_object,
                                  const char *eval_info_bytes);

namespace pythonx {

using namespace python;

// State
std::mutex init_mutex;
bool is_initialized = false;
std::wstring python_home_path_w;
std::wstring python_executable_path_w;
std::map<std::string, std::tuple<PyObjectPtr, PyObjectPtr>> compilation_cache;
std::mutex compilation_cache_mutex;
PyInterpreterStatePtr interpreter_state;
std::map<std::thread::id, PyThreadStatePtr> thread_states;
std::mutex thread_states_mutex;

// Wrapper around the Python Global Interpreter Lock (GIL).
//
// To acquire the GIL, the caller simply needs to initialize a new
// guard object. Once the guard object's lifetime ends, the GIL is
// automatically released. This is the use of RAII [1] pattern,
// similarly to `std::lock_guard`.
//
// [1]: https://en.wikipedia.org/wiki/Resource_acquisition_is_initialization
class PyGILGuard {
  // The simplest way to implement this guard is to use `PyGILState_Ensure`
  // and `PyGILState_Release`, however this can lead to segfaults when
  // using libraries depending on pybind11.
  //
  // pybind11 is a popular library for writing C extensions in Python
  // packages. It provides convenient C++ API on top of the Python C
  // API. In particular, it provides conveniences for dealing with
  // GIL, one of them being `gil_scoped_acquire`. The implementation
  // has a bug that results in a dangling pointer being used. This
  // bug only appears when the code runs in a non-main thread that
  // manages the `gil_scoped_acquire` checks if the calling thread
  // already holds GIL with `PyGILState_Ensure` and `PyGILState_Release`.
  // Specifically, the GIL, in which case it stores the pointer to
  // the corresponding `PyThreadState`. After `PyGILState_Release`,
  // the thread state is freed, but subsequent usage of `gil_scoped_acquire`
  // still re-uses the pointer. This issues has been reported in [1].
  //
  // In our case, we evaluate Python code dirty scheduler threads.
  // This means that the threads are reused and we acquire the GIL
  // every time. In order to avoid the pybind11 bug, we want to avoid
  // using `PyGILState_Release`, and instead have a permanent `PyThreadState`
  // for each of the dirty scheduler threads. We do this by creating
  // new state when the given scheduler thread obtains the GIL for
  // the first time. Then, we use `PyEval_RestoreThread` and `PyEval_SaveThread`
  // to acquire and release the GIL respectively.
  //
  // NOTE: the dirty scheduler thread pool is fixed, so the map does
  // not grow beyond that. If we ever need to acquire the GIL from
  // other threads, we should extend this implementation to either
  // allow removing the state on destruction, or have a variant with
  // `PyGILState_Ensure` and `PyGILState_Release`, as long as it does
  // not fall into the bug described above.
  //
  // [1]: https://github.com/pybind/pybind11/issues/2888

public:
  PyGILGuard() {
    auto thread_id = std::this_thread::get_id();

    PyThreadStatePtr state;

    {
      auto guard = std::lock_guard<std::mutex>(thread_states_mutex);

      if (thread_states.find(thread_id) == thread_states.end()) {
        // Note that PyThreadState_New does not require GIL to be held.
        state = PyThreadState_New(interpreter_state);
        thread_states[thread_id] = state;
      } else {
        state = thread_states[thread_id];
      }
    }

    PyEval_RestoreThread(state);
  }

  ~PyGILGuard() { PyEval_SaveThread(); }
};

// Ensures the given object refcount is decremented when the guard
// goes out of scope.
class PyDecRefGuard {
  PyObjectPtr py_object;

public:
  PyDecRefGuard() : py_object(nullptr) {}
  PyDecRefGuard(PyObjectPtr py_object) : py_object(py_object) {}

  ~PyDecRefGuard() {
    if (this->py_object != nullptr) {
      Py_DecRef(this->py_object);
    }
  }

  PyDecRefGuard &operator=(PyObjectPtr py_object) {
    this->py_object = py_object;
    return *this;
  }
};

void ensure_initialized() {
  auto init_guard = std::lock_guard<std::mutex>(init_mutex);

  if (!is_initialized) {
    throw std::runtime_error("Python interpreter has not been initialized");
  }
}

namespace atoms {
auto ElixirPythonxError = fine::Atom("Elixir.Pythonx.Error");
auto ElixirPythonxJanitor = fine::Atom("Elixir.Pythonx.Janitor");
auto ElixirPythonxObject = fine::Atom("Elixir.Pythonx.Object");
auto decref = fine::Atom("decref");
auto integer = fine::Atom("integer");
auto list = fine::Atom("list");
auto map = fine::Atom("map");
auto map_set = fine::Atom("map_set");
auto output = fine::Atom("output");
auto resource = fine::Atom("resource");
auto traceback = fine::Atom("traceback");
auto tuple = fine::Atom("tuple");
auto type = fine::Atom("type");
auto value = fine::Atom("value");
} // namespace atoms

struct ExObjectResource {
  PyObjectPtr py_object;

  ExObjectResource(PyObjectPtr py_object) : py_object(py_object) {}

  void destructor(ErlNifEnv *env) {
    // Decrementing refcount requires GIL and we should not block in
    // the destructor, so we send a message to a known process and let
    // it decrement the refcount for us. Also see [1].
    //
    // [1]:https://erlangforums.com/t/how-to-deal-with-destructors-that-can-take-a-while-to-run-and-possibly-block-the-scheduler/4290

    if (!is_initialized) {
      // If we allow multiple initializations, we need to add a counter
      // and check that py_object comes from the current initialization
      return;
    }

    auto ptr = reinterpret_cast<uint64_t>(this->py_object);

    auto janitor_name = fine::encode(env, atoms::ElixirPythonxJanitor);
    ErlNifPid janitor_pid;
    if (enif_whereis_pid(env, janitor_name, &janitor_pid)) {
      auto msg_env = enif_alloc_env();
      auto msg = fine::encode(msg_env, std::make_tuple(atoms::decref, ptr));
      enif_send(env, &janitor_pid, msg_env, msg);
      enif_free_env(msg_env);
    } else {
      std::cerr << "[pythonx] whereis(Pythonx.Janitor) failed. This is "
                   "unexpected and a Python object will not be deallocated"
                << std::endl;
    }
  }
};

FINE_RESOURCE(ExObjectResource);

struct ExObject {
  fine::ResourcePtr<ExObjectResource> resource;

  ExObject() {}
  ExObject(fine::ResourcePtr<ExObjectResource> resource) : resource(resource) {}

  static constexpr auto module = &atoms::ElixirPythonxObject;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExObject::resource, &atoms::resource));
  }
};

struct ExError {
  ExObject type;
  ExObject value;
  ExObject traceback;

  ExError() {}
  ExError(ExObject type, ExObject value, ExObject traceback)
      : type(type), value(value), traceback(traceback) {}

  static constexpr auto module = &atoms::ElixirPythonxError;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExError::type, &atoms::type),
        std::make_tuple(&ExError::value, &atoms::value),
        std::make_tuple(&ExError::traceback, &atoms::traceback));
  }

  static constexpr auto is_exception = true;
};

struct EvalInfo {
  fine::Term stdout_device;
  fine::Term stderr_device;
  ErlNifEnv *env;
  std::thread::id thread_id;
};

void raise_py_error(ErlNifEnv *env) {
  PyObjectPtr py_type, py_value, py_traceback;
  PyErr_Fetch(&py_type, &py_value, &py_traceback);

  // If the error indicator was set, type should not be NULL, but value
  // and traceback might

  if (py_type == NULL) {
    throw std::runtime_error(
        "raise_py_error should only be called when the error indicator is set");
  }

  auto type = ExObject(fine::make_resource<ExObjectResource>(py_type));

  // Default value and traceback to None object

  auto value = fine::make_resource<ExObjectResource>(
      py_value == NULL ? Py_BuildValue("") : py_value);

  auto traceback = fine::make_resource<ExObjectResource>(
      py_traceback == NULL ? Py_BuildValue("") : py_traceback);

  auto error = ExError(type, value, traceback);
  fine::raise(env, error);
}

void raise_if_failed(ErlNifEnv *env, PyObjectPtr py_object) {
  if (py_object == NULL) {
    raise_py_error(env);
  }
}

void raise_if_failed(ErlNifEnv *env, const char *buffer) {
  if (buffer == NULL) {
    raise_py_error(env);
  }
}

void raise_if_failed(ErlNifEnv *env, Py_ssize_t size) {
  if (size == -1) {
    raise_py_error(env);
  }
}

ERL_NIF_TERM py_str_to_binary_term(ErlNifEnv *env, PyObjectPtr py_object) {
  Py_ssize_t size;
  auto buffer = PyUnicode_AsUTF8AndSize(py_object, &size);
  raise_if_failed(env, buffer);

  // The buffer is immutable and lives as long as the Python object,
  // so we create the term as a resource binary to make it zero-copy.
  Py_IncRef(py_object);
  auto ex_object_resource = fine::make_resource<ExObjectResource>(py_object);
  return fine::make_resource_binary(env, ex_object_resource, buffer, size);
}

fine::Ok<> init(ErlNifEnv *env, std::string python_dl_path,
                ErlNifBinary python_home_path,
                ErlNifBinary python_executable_path,
                std::vector<ErlNifBinary> sys_paths,
                std::vector<std::tuple<ErlNifBinary, ErlNifBinary>> envs) {
  auto init_guard = std::lock_guard<std::mutex>(init_mutex);

  if (is_initialized) {
    throw std::runtime_error("Python interpreter has already been initialized");
  }

  // Raises runtime error on failure, which is propagated automatically
  load_python_library(python_dl_path);

  // The path needs to be available for the whole interpreter lifetime,
  // so we store it in a global variable.
  python_home_path_w = std::wstring(
      python_home_path.data, python_home_path.data + python_home_path.size);

  python_executable_path_w =
      std::wstring(python_executable_path.data,
                   python_executable_path.data + python_executable_path.size);

  // As part of the initialization, sys.path gets set. It is important
  // that it gets set correctly, so that the built-in modules can be
  // found, otherwise the initialization fails. This logic is internal
  // to Python, but we can configure base paths used to infer sys.path.
  // The Limited API exposes Py_SetPythonHome and Py_SetProgramName and
  // it appears that setting either of them alone should be sufficient.
  //
  // Py_SetProgramName has the advantage that, when set to the executable
  // inside venv, it results in the packages directory being added to
  // sys.path automatically, however, when tested, this did not work
  // as expected in Python 3.10 on Windows. For this reason we prefer
  // to use Py_SetPythonHome and add other paths to sys.path manually.
  //
  // Even then, we still want to set Py_SetProgramName to a Python
  // executable, otherwise `sys.executable` is going to point to the
  // BEAM executable (`argv[0]`), which can be problematic.
  //
  // In the end, the most reliable combination seems to be to set both,
  // and also add the extra sys.path manually.
  //
  // Note that Python home is the directory with lib/ child directory
  // containing the built-in Python modules [1].
  //
  // [1]: https://docs.python.org/3/using/cmdline.html#envvar-PYTHONHOME
  Py_SetPythonHome(python_home_path_w.c_str());
  Py_SetProgramName(python_executable_path_w.c_str());

  Py_InitializeEx(0);

  interpreter_state = PyInterpreterState_Get();

  // In order to use any of the Python C API functions, the calling
  // thread must hold the GIL. Since every NIF call may run on a
  // different dirty scheduler thread, we need to acquire the GIL at
  // the beginning of each NIF and release it afterwards.
  //
  // After initializing the Python interpreter above, the current
  // thread automatically holds the GIL, so we explicitly release it.
  // See pyo3 [1] for an extra reference.
  //
  // [1]: https://github.com/PyO3/pyo3/blob/v0.23.3/src/gil.rs#L63-L74
  thread_states[std::this_thread::get_id()] = PyEval_SaveThread();

  is_initialized = true;

  // We still hold the init_mutex, so we can obtain the GIL guard
  // before any other concurrent NIF. At this point we marked the
  // interpreter as initialized and now we continue with further
  // preparation using Python APIs. If any exception is subsequently
  // raised, it will propagate as expected, and since the interpreter
  // is initialized, the exception formatting will also work.
  auto gil_guard = PyGILGuard();

  // Add extra paths to sys.path

  auto py_sys = PyImport_AddModule("sys");
  raise_if_failed(env, py_sys);

  auto py_sys_path = PyObject_GetAttrString(py_sys, "path");
  raise_if_failed(env, py_sys_path);
  auto py_sys_path_guard = PyDecRefGuard(py_sys_path);

  for (const auto &path : sys_paths) {
    auto py_path = PyUnicode_FromStringAndSize(
        reinterpret_cast<const char *>(path.data), path.size);
    raise_if_failed(env, py_path);
    auto py_path_guard = PyDecRefGuard(py_path);

    raise_if_failed(env, PyList_Append(py_sys_path, py_path));
  }

  // We set env vars to match Elixir at the time of initialization.
  // Note that the interpreter initializes its env vars from the OS
  // process, however we want to account for changes to env vars
  // such as `System.put_env/2`.

  auto py_os = PyImport_AddModule("os");
  raise_if_failed(env, py_os);

  auto py_os_environ = PyObject_GetAttrString(py_os, "environ");
  raise_if_failed(env, py_os_environ);
  auto py_os_environ_guard = PyDecRefGuard(py_os_environ);

  auto py_os_environ_clear = PyObject_GetAttrString(py_os_environ, "clear");
  raise_if_failed(env, py_os_environ_clear);
  auto py_os_environ_clear_guard = PyDecRefGuard(py_os_environ_clear);
  auto result = PyObject_CallNoArgs(py_os_environ_clear);
  raise_if_failed(env, result);

  for (const auto &[key, value] : envs) {
    auto py_key = PyUnicode_FromStringAndSize(
        reinterpret_cast<const char *>(key.data), key.size);
    raise_if_failed(env, py_key);
    auto py_key_guard = PyDecRefGuard(py_key);
    auto py_value = PyUnicode_FromStringAndSize(
        reinterpret_cast<const char *>(value.data), value.size);
    raise_if_failed(env, py_value);
    auto py_value_guard = PyDecRefGuard(py_value);

    auto result = PyObject_SetItem(py_os_environ, py_key, py_value);
    raise_if_failed(env, result);
  }

  // Define global stdout and stdin overrides

  auto py_builtins = PyEval_GetBuiltins();
  raise_if_failed(env, py_builtins);

  auto py_exec = PyDict_GetItemString(py_builtins, "exec");
  raise_if_failed(env, py_exec);

  const char code[] = R"(
import ctypes
import io
import sys
import inspect
import types
import sys

pythonx_handle_io_write = ctypes.CFUNCTYPE(
  None, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_bool
)(pythonx_handle_io_write_ptr)

pythonx_handle_send_tagged_object = ctypes.CFUNCTYPE(
  None, ctypes.c_char_p, ctypes.c_char_p, ctypes.py_object, ctypes.c_char_p
)(pythonx_handle_send_tagged_object_ptr)


def get_eval_info_bytes():
  # The evaluation caller has __pythonx_eval_info_bytes__ set in
  # their globals. It is not available in globals() here, because
  # the globals dict in function definitions is fixed at definition
  # time. To find the current evaluation globals, we look at the
  # call stack using the inspect module and find the caller with
  # __pythonx_eval_info_bytes__ in globals. We look specifically
  # for the outermost caller, because intermediate functions could
  # be defined by previous evaluations, in which case they would
  # have __pythonx_eval_info_bytes__ in their globals, corresponding
  # to that previous evaluation. When called within a thread, the
  # evaluation caller is not in the stack, so __pythonx_eval_info_bytes__
  # will be found in the thread entrypoint function globals.
  call_stack = inspect.stack()
  eval_info_bytes = next(
    frame_info.frame.f_globals["__pythonx_eval_info_bytes__"]
    for frame_info in reversed(call_stack)
    if "__pythonx_eval_info_bytes__" in frame_info.frame.f_globals
  )
  return eval_info_bytes


class Stdout(io.TextIOBase):
  def __init__(self, type):
    self.type = type

  def write(self, string):
    pythonx_handle_io_write(string.encode("utf-8"), get_eval_info_bytes(), self.type)
    return len(string)


class Stdin(io.IOBase):
  def read(self, size=None):
    raise RuntimeError("stdin not supported")


sys.stdout = Stdout(0)
sys.stderr = Stdout(1)
sys.stdin = Stdin()

pythonx = types.ModuleType("pythonx")

class PID:
  def __init__(self, bytes):
    self.bytes = bytes

  def __repr__(self):
    return "<pythonx.PID>"

pythonx.PID = PID

def send_tagged_object(pid, tag, object):
  pythonx_handle_send_tagged_object(pid.bytes, tag.encode("utf-8"), object, get_eval_info_bytes())

pythonx.send_tagged_object = send_tagged_object

sys.modules["pythonx"] = pythonx
)";

  auto py_code = PyUnicode_FromStringAndSize(code, sizeof(code) - 1);
  raise_if_failed(env, py_code);
  auto py_code_guard = PyDecRefGuard(py_code);

  auto py_globals = PyDict_New();
  raise_if_failed(env, py_globals);
  auto py_globals_guard = PyDecRefGuard(py_globals);

  raise_if_failed(
      env, PyDict_SetItemString(py_globals, "__builtins__", py_builtins));

  auto py_pythonx_handle_io_write_ptr = PyLong_FromUnsignedLongLong(
      reinterpret_cast<uintptr_t>(pythonx_handle_io_write));
  raise_if_failed(env, py_pythonx_handle_io_write_ptr);
  auto py_pythonx_handle_io_write_ptr_guard =
      PyDecRefGuard(py_pythonx_handle_io_write_ptr);

  raise_if_failed(env, PyDict_SetItemString(py_globals,
                                            "pythonx_handle_io_write_ptr",
                                            py_pythonx_handle_io_write_ptr));

  auto py_pythonx_handle_send_tagged_object_ptr = PyLong_FromUnsignedLongLong(
      reinterpret_cast<uintptr_t>(pythonx_handle_send_tagged_object));
  raise_if_failed(env, py_pythonx_handle_send_tagged_object_ptr);
  auto py_pythonx_handle_send_tagged_object_ptr_guard =
      PyDecRefGuard(py_pythonx_handle_send_tagged_object_ptr);

  raise_if_failed(env, PyDict_SetItemString(
                           py_globals, "pythonx_handle_send_tagged_object_ptr",
                           py_pythonx_handle_send_tagged_object_ptr));

  auto py_exec_args = PyTuple_Pack(2, py_code, py_globals);
  raise_if_failed(env, py_exec_args);
  auto py_exec_args_guard = PyDecRefGuard(py_exec_args);

  auto py_result = PyObject_Call(py_exec, py_exec_args, NULL);
  raise_if_failed(env, py_result);
  Py_DecRef(py_result);

  return fine::Ok<>();
}

FINE_NIF(init, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Ok<> janitor_decref(ErlNifEnv *env, uint64_t ptr) {
  auto init_guard = std::lock_guard<std::mutex>(init_mutex);

  // If the interpreter is no longer initialized, ignore the call
  if (is_initialized) {
    auto gil_guard = PyGILGuard();

    auto object = reinterpret_cast<PyObjectPtr>(ptr);

    Py_DecRef(object);
  }

  return fine::Ok<>();
}

FINE_NIF(janitor_decref, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject none_new(ErlNifEnv *env) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  // Note that Limited API has Py_GetConstant, but only since v3.13
  auto py_none = Py_BuildValue("");
  raise_if_failed(env, py_none);

  return ExObject(fine::make_resource<ExObjectResource>(py_none));
}

FINE_NIF(none_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject false_new(ErlNifEnv *env) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_bool = PyBool_FromLong(0);
  raise_if_failed(env, py_bool);

  return ExObject(fine::make_resource<ExObjectResource>(py_bool));
}

FINE_NIF(false_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject true_new(ErlNifEnv *env) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_bool = PyBool_FromLong(1);
  raise_if_failed(env, py_bool);

  return ExObject(fine::make_resource<ExObjectResource>(py_bool));
}

FINE_NIF(true_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject long_from_int64(ErlNifEnv *env, int64_t number) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_long = PyLong_FromLongLong(number);
  raise_if_failed(env, py_long);

  return ExObject(fine::make_resource<ExObjectResource>(py_long));
}

FINE_NIF(long_from_int64, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject long_from_string(ErlNifEnv *env, std::string string, int64_t base) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_long =
      PyLong_FromString(string.c_str(), NULL, static_cast<int>(base));
  raise_if_failed(env, py_long);

  return ExObject(fine::make_resource<ExObjectResource>(py_long));
}

FINE_NIF(long_from_string, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject float_new(ErlNifEnv *env, double number) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_float = PyFloat_FromDouble(number);
  raise_if_failed(env, py_float);

  return ExObject(fine::make_resource<ExObjectResource>(py_float));
}

FINE_NIF(float_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject bytes_from_binary(ErlNifEnv *env, ErlNifBinary binary) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_object = PyBytes_FromStringAndSize(
      reinterpret_cast<const char *>(binary.data), binary.size);
  raise_if_failed(env, py_object);

  return ExObject(fine::make_resource<ExObjectResource>(py_object));
}

FINE_NIF(bytes_from_binary, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject unicode_from_string(ErlNifEnv *env, ErlNifBinary binary) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_object = PyUnicode_FromStringAndSize(
      reinterpret_cast<const char *>(binary.data), binary.size);

  raise_if_failed(env, py_object);

  return ExObject(fine::make_resource<ExObjectResource>(py_object));
}

FINE_NIF(unicode_from_string, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term unicode_to_string(ErlNifEnv *env, ExObject ex_object) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  return py_str_to_binary_term(env, ex_object.resource->py_object);
}

FINE_NIF(unicode_to_string, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject dict_new(ErlNifEnv *env) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_dict = PyDict_New();
  raise_if_failed(env, py_dict);

  return ExObject(fine::make_resource<ExObjectResource>(py_dict));
}

FINE_NIF(dict_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Ok<> dict_set_item(ErlNifEnv *env, ExObject ex_object, ExObject ex_key,
                         ExObject ex_value) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto result =
      PyDict_SetItem(ex_object.resource->py_object, ex_key.resource->py_object,
                     ex_value.resource->py_object);
  raise_if_failed(env, result);

  return fine::Ok<>();
}

FINE_NIF(dict_set_item, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject tuple_new(ErlNifEnv *env, uint64_t size) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_tuple = PyTuple_New(size);
  raise_if_failed(env, py_tuple);

  return ExObject(fine::make_resource<ExObjectResource>(py_tuple));
}

FINE_NIF(tuple_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Ok<> tuple_set_item(ErlNifEnv *env, ExObject ex_object, uint64_t index,
                          ExObject ex_value) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto result = PyTuple_SetItem(ex_object.resource->py_object, index,
                                ex_value.resource->py_object);
  raise_if_failed(env, result);

  // PyTuple_SetItem steals a reference, so we add one back
  Py_IncRef(ex_value.resource->py_object);

  return fine::Ok<>();
}

FINE_NIF(tuple_set_item, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject list_new(ErlNifEnv *env, uint64_t size) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_tuple = PyList_New(size);
  raise_if_failed(env, py_tuple);

  return ExObject(fine::make_resource<ExObjectResource>(py_tuple));
}

FINE_NIF(list_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Ok<> list_set_item(ErlNifEnv *env, ExObject ex_object, uint64_t index,
                         ExObject ex_value) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto result = PyList_SetItem(ex_object.resource->py_object, index,
                               ex_value.resource->py_object);
  raise_if_failed(env, result);

  // PyList_SetItem steals a reference, so we add one back
  Py_IncRef(ex_value.resource->py_object);

  return fine::Ok<>();
}

FINE_NIF(list_set_item, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject set_new(ErlNifEnv *env) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_set = PySet_New(NULL);
  raise_if_failed(env, py_set);

  return ExObject(fine::make_resource<ExObjectResource>(py_set));
}

FINE_NIF(set_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Ok<> set_add(ErlNifEnv *env, ExObject ex_object, ExObject ex_key) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto result =
      PySet_Add(ex_object.resource->py_object, ex_key.resource->py_object);
  raise_if_failed(env, result);

  return fine::Ok<>();
}

FINE_NIF(set_add, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject pid_new(ErlNifEnv *env, ErlNifPid pid) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  // ErlNifPid is self-contained struct, not bound to any env, so it's
  // safe to copy [1].
  //
  // [1]: https://www.erlang.org/doc/apps/erts/erl_nif.html#ErlNifPid
  auto py_pid_bytes = PyBytes_FromStringAndSize(
      reinterpret_cast<const char *>(&pid), sizeof(ErlNifPid));
  raise_if_failed(env, py_pid_bytes);

  auto py_pythonx = PyImport_AddModule("pythonx");
  raise_if_failed(env, py_pythonx);

  auto py_PID = PyObject_GetAttrString(py_pythonx, "PID");
  raise_if_failed(env, py_PID);
  auto py_PID_guard = PyDecRefGuard(py_PID);

  auto py_PID_args = PyTuple_Pack(1, py_pid_bytes);
  raise_if_failed(env, py_PID_args);
  auto py_PID_args_guard = PyDecRefGuard(py_PID_args);

  auto py_pid = PyObject_Call(py_PID, py_PID_args, NULL);
  raise_if_failed(env, py_pid);

  return ExObject(fine::make_resource<ExObjectResource>(py_pid));
}

FINE_NIF(pid_new, ERL_NIF_DIRTY_JOB_CPU_BOUND);

ExObject object_repr(ErlNifEnv *env, ExObject ex_object) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_repr = PyObject_Repr(ex_object.resource->py_object);
  raise_if_failed(env, py_repr);

  return ExObject(fine::make_resource<ExObjectResource>(py_repr));
}

FINE_NIF(object_repr, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term format_exception(ErlNifEnv *env, ExError error) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_traceback_module = PyImport_ImportModule("traceback");
  raise_if_failed(env, py_traceback_module);
  auto py_traceback_module_guard = PyDecRefGuard(py_traceback_module);

  auto format_exception =
      PyObject_GetAttrString(py_traceback_module, "format_exception");
  raise_if_failed(env, format_exception);
  auto format_exception_guard = PyDecRefGuard(format_exception);

  auto py_type = error.type.resource->py_object;
  auto py_value = error.value.resource->py_object;
  auto py_traceback = error.traceback.resource->py_object;

  auto format_exception_args = PyTuple_Pack(3, py_type, py_value, py_traceback);
  raise_if_failed(env, format_exception_args);
  auto format_exception_args_guard = PyDecRefGuard(format_exception_args);

  auto py_lines = PyObject_Call(format_exception, format_exception_args, NULL);
  raise_if_failed(env, py_lines);
  auto py_lines_guard = PyDecRefGuard(py_lines);

  auto size = PyList_Size(py_lines);
  raise_if_failed(env, size);

  auto terms = std::vector<ERL_NIF_TERM>();
  terms.reserve(size);

  for (Py_ssize_t i = 0; i < size; i++) {
    auto py_line = PyList_GetItem(py_lines, i);
    raise_if_failed(env, py_line);

    terms.push_back(py_str_to_binary_term(env, py_line));
  }

  return enif_make_list_from_array(env, terms.data(),
                                   static_cast<unsigned int>(size));
}

FINE_NIF(format_exception, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term decode_once(ErlNifEnv *env, ExObject ex_object) {
  ensure_initialized();
  auto gil_guard = PyGILGuard();

  auto py_object = ex_object.resource->py_object;

  auto is_none = Py_IsNone(py_object);
  raise_if_failed(env, is_none);
  if (is_none) {
    return fine::encode(env, std::nullopt);
  }

  auto is_true = Py_IsTrue(py_object);
  raise_if_failed(env, is_true);
  if (is_true) {
    return fine::encode(env, true);
  }

  auto is_false = Py_IsFalse(py_object);
  raise_if_failed(env, is_false);
  if (is_false) {
    return fine::encode(env, false);
  }

  auto py_builtins = PyEval_GetBuiltins();
  raise_if_failed(env, py_builtins);

  auto py_int_type = PyDict_GetItemString(py_builtins, "int");
  raise_if_failed(env, py_int_type);
  auto is_long = PyObject_IsInstance(py_object, py_int_type);
  raise_if_failed(env, is_long);
  if (is_long) {
    int overflow;
    auto integer = PyLong_AsLongLongAndOverflow(py_object, &overflow);

    if (PyErr_Occurred() != NULL) {
      raise_py_error(env);
    }

    if (overflow == 0) {
      return enif_make_int64(env, integer);
    }

    // Integer over 64 bits

    auto py_str = PyObject_Str(py_object);
    raise_if_failed(env, py_str);
    auto py_str_guard = PyDecRefGuard(py_str);

    auto binary_term = py_str_to_binary_term(env, py_str);

    return fine::encode(
        env, std::make_tuple(atoms::integer, fine::Term(binary_term)));
  }

  auto py_float_type = PyDict_GetItemString(py_builtins, "float");
  raise_if_failed(env, py_float_type);
  auto is_float = PyObject_IsInstance(py_object, py_float_type);
  raise_if_failed(env, is_float);
  if (is_float) {
    double number = PyFloat_AsDouble(py_object);
    if (PyErr_Occurred() != NULL) {
      raise_py_error(env);
    }

    return enif_make_double(env, number);
  }

  auto py_tuple_type = PyDict_GetItemString(py_builtins, "tuple");
  raise_if_failed(env, py_tuple_type);
  auto is_tuple = PyObject_IsInstance(py_object, py_tuple_type);
  raise_if_failed(env, is_tuple);
  if (is_tuple) {
    auto size = PyTuple_Size(py_object);
    raise_if_failed(env, size);

    auto terms = std::vector<ERL_NIF_TERM>();
    terms.reserve(size);

    for (Py_ssize_t i = 0; i < size; i++) {
      auto py_item = PyTuple_GetItem(py_object, i);
      raise_if_failed(env, py_item);
      Py_IncRef(py_item);
      auto ex_item = ExObject(fine::make_resource<ExObjectResource>(py_item));
      terms.push_back(fine::encode(env, ex_item));
    }

    auto items = enif_make_list_from_array(env, terms.data(),
                                           static_cast<unsigned int>(size));
    return fine::encode(env, std::make_tuple(atoms::tuple, fine::Term(items)));
  }

  auto py_list_type = PyDict_GetItemString(py_builtins, "list");
  raise_if_failed(env, py_list_type);
  auto is_list = PyObject_IsInstance(py_object, py_list_type);
  raise_if_failed(env, is_list);
  if (is_list) {
    auto size = PyList_Size(py_object);
    raise_if_failed(env, size);

    auto terms = std::vector<ERL_NIF_TERM>();
    terms.reserve(size);

    for (Py_ssize_t i = 0; i < size; i++) {
      auto py_item = PyList_GetItem(py_object, i);
      raise_if_failed(env, py_item);
      Py_IncRef(py_item);
      auto ex_item = ExObject(fine::make_resource<ExObjectResource>(py_item));
      terms.push_back(fine::encode(env, ex_item));
    }

    auto items = enif_make_list_from_array(env, terms.data(),
                                           static_cast<unsigned int>(size));
    return fine::encode(env, std::make_tuple(atoms::list, fine::Term(items)));
  }

  auto py_dict_type = PyDict_GetItemString(py_builtins, "dict");
  raise_if_failed(env, py_dict_type);
  auto is_dict = PyObject_IsInstance(py_object, py_dict_type);
  raise_if_failed(env, is_dict);
  if (is_dict) {
    auto size = PyDict_Size(py_object);
    raise_if_failed(env, size);

    auto terms = std::vector<ERL_NIF_TERM>();
    terms.reserve(size);

    PyObjectPtr py_key, py_value;
    Py_ssize_t pos = 0;

    while (PyDict_Next(py_object, &pos, &py_key, &py_value)) {
      Py_IncRef(py_key);
      auto ex_key = ExObject(fine::make_resource<ExObjectResource>(py_key));

      Py_IncRef(py_value);
      auto ex_value = ExObject(fine::make_resource<ExObjectResource>(py_value));

      terms.push_back(fine::encode(env, std::make_tuple(ex_key, ex_value)));
    }

    auto items = enif_make_list_from_array(env, terms.data(),
                                           static_cast<unsigned int>(size));
    return fine::encode(env, std::make_tuple(atoms::map, fine::Term(items)));
  }

  auto py_str_type = PyDict_GetItemString(py_builtins, "str");
  raise_if_failed(env, py_str_type);
  auto is_unicode = PyObject_IsInstance(py_object, py_str_type);
  raise_if_failed(env, is_unicode);
  if (is_unicode) {
    return py_str_to_binary_term(env, py_object);
  }

  auto py_bytes_type = PyDict_GetItemString(py_builtins, "bytes");
  raise_if_failed(env, py_bytes_type);
  auto is_bytes = PyObject_IsInstance(py_object, py_bytes_type);
  raise_if_failed(env, is_bytes);
  if (is_bytes) {
    Py_ssize_t size;
    char *buffer;
    auto result = PyBytes_AsStringAndSize(py_object, &buffer, &size);
    raise_if_failed(env, result);

    // The buffer is immutable and lives as long as the Python object,
    // so we create the term as a resource binary to make it zero-copy.
    Py_IncRef(py_object);
    auto ex_object_resource = fine::make_resource<ExObjectResource>(py_object);
    return fine::make_resource_binary(env, ex_object_resource, buffer, size);
  }

  auto py_set_type = PyDict_GetItemString(py_builtins, "set");
  raise_if_failed(env, py_set_type);
  auto is_set = PyObject_IsInstance(py_object, py_set_type);
  raise_if_failed(env, is_set);
  auto py_frozenset_type = PyDict_GetItemString(py_builtins, "frozenset");
  raise_if_failed(env, py_frozenset_type);
  auto is_frozenset = PyObject_IsInstance(py_object, py_frozenset_type);
  raise_if_failed(env, is_frozenset);
  if (is_set || is_frozenset) {
    auto size = PySet_Size(py_object);
    raise_if_failed(env, size);

    auto terms = std::vector<ERL_NIF_TERM>();
    terms.reserve(size);

    auto py_iter = PyObject_GetIter(py_object);
    raise_if_failed(env, py_iter);
    auto py_iter_guard = PyDecRefGuard(py_iter);

    PyObjectPtr py_item = NULL;

    while ((py_item = PyIter_Next(py_iter)) != NULL) {
      // Note that PyIter_Next already returns a new reference
      auto ex_item = ExObject(fine::make_resource<ExObjectResource>(py_item));
      terms.push_back(fine::encode(env, ex_item));
    }

    if (PyErr_Occurred() != NULL) {
      raise_py_error(env);
    }

    auto items = enif_make_list_from_array(env, terms.data(),
                                           static_cast<unsigned int>(size));
    return fine::encode(env,
                        std::make_tuple(atoms::map_set, fine::Term(items)));
  }

  auto py_pythonx = PyImport_AddModule("pythonx");
  raise_if_failed(env, py_pythonx);

  auto py_PID = PyObject_GetAttrString(py_pythonx, "PID");
  raise_if_failed(env, py_PID);
  auto py_PID_guard = PyDecRefGuard(py_PID);

  auto is_pid = PyObject_IsInstance(py_object, py_PID);
  raise_if_failed(env, is_pid);
  if (is_pid) {
    auto py_pid_bytes = PyObject_GetAttrString(py_object, "bytes");
    raise_if_failed(env, py_pid_bytes);
    auto py_pid_bytes_guard = PyDecRefGuard(py_pid_bytes);

    Py_ssize_t size;
    char *pid_bytes;
    auto result = PyBytes_AsStringAndSize(py_pid_bytes, &pid_bytes, &size);
    raise_if_failed(env, result);

    auto pid = ErlNifPid{};
    std::memcpy(&pid, pid_bytes, sizeof(ErlNifPid));

    return fine::encode(env, pid);
  }

  // None of the built-ins, return %Pythonx.Object{} as is
  return fine::encode(env, ex_object);
}

FINE_NIF(decode_once, ERL_NIF_DIRTY_JOB_CPU_BOUND);

std::tuple<PyObjectPtr, PyObjectPtr> compile(ErlNifEnv *env,
                                             ErlNifBinary code) {
  // Python code can be compiled in either "exec" mode (multiple
  // statements with no result value) or "eval" mode (single expression
  // with a result value). We want our eval API to accept arbitrary
  // Python code with multiple statements, while also returning the
  // final result. To achieve this we parse the code using Python
  // standard library and check if the last statement is an expression.
  // If that is the case, we split the code, "exec" the statements
  // and "eval" the final expression separately.
  //
  // For the reference, below is a Python code corresponding to the
  // described logic. Technically we could "exec" that Python code,
  // but in order to avoid extra overhead we call the Python functions
  // directly via the C API.
  //
  //     import ast
  //
  //     module = ast.parse(code, "<string>", mode="exec")
  //
  //     body_code = None
  //     last_expr_code = None
  //
  //     if module.body:
  //       last_statement = module.body[-1]
  //
  //       if isinstance(last_statement, ast.Expr):
  //         expr = ast.Expression(module.body.pop().value)
  //         # Copy positional information to the expression root node
  //         expr.lineno = last_statement.lineno
  //         expr.col_offset = last_statement.col_offset
  //         expr.end_col_offset = last_statement.end_col_offset
  //         last_expr_code = compile(expr, filename, mode="eval")
  //
  //     if module.body:
  //       body_code = compile(module, filename, mode="exec")
  //
  // The body and last expression is then evaluated separately, as in:
  //
  //     if body_code:
  //       eval(body_code)
  //
  //     if last_expr_code:
  //       result = eval(last_expr_code)
  //     else:
  //       result = None

  PyObjectPtr py_body_code = nullptr;
  PyObjectPtr py_last_expr_code = nullptr;
  auto py_last_expr_code_guard = PyDecRefGuard();

  auto py_ast = PyImport_ImportModule("ast");
  raise_if_failed(env, py_ast);
  auto py_ast_guard = PyDecRefGuard(py_ast);

  auto py_parse = PyObject_GetAttrString(py_ast, "parse");
  raise_if_failed(env, py_parse);
  auto py_parse_guard = PyDecRefGuard(py_parse);

  auto py_code = PyUnicode_FromStringAndSize(
      reinterpret_cast<const char *>(code.data), code.size);
  raise_if_failed(env, py_code);
  auto py_code_guard = PyDecRefGuard(py_code);

  auto py_file_string = PyUnicode_FromStringAndSize("<string>", 8);
  raise_if_failed(env, py_file_string);
  auto py_file_string_guard = PyDecRefGuard(py_file_string);

  auto py_exec_string = PyUnicode_FromStringAndSize("exec", 4);
  raise_if_failed(env, py_exec_string);
  auto py_exec_string_guard = PyDecRefGuard(py_exec_string);

  auto py_parse_args = PyTuple_Pack(3, py_code, py_file_string, py_exec_string);
  raise_if_failed(env, py_parse_args);
  auto py_parse_args_guard = PyDecRefGuard(py_parse_args);

  auto py_module_ast = PyObject_Call(py_parse, py_parse_args, NULL);
  raise_if_failed(env, py_module_ast);
  auto py_module_ast_guard = PyDecRefGuard(py_module_ast);

  auto py_builtins = PyEval_GetBuiltins();
  raise_if_failed(env, py_builtins);

  auto py_compile = PyDict_GetItemString(py_builtins, "compile");
  raise_if_failed(env, py_compile);

  auto py_module_body = PyObject_GetAttrString(py_module_ast, "body");
  raise_if_failed(env, py_module_body);
  auto py_module_body_guard = PyDecRefGuard(py_module_body);

  auto py_module_body_size = PyList_Size(py_module_body);
  raise_if_failed(env, py_module_body_size);

  if (py_module_body_size > 0) {
    auto py_last_expr = PyList_GetItem(py_module_body, py_module_body_size - 1);
    raise_if_failed(env, py_last_expr);

    auto py_Expr = PyObject_GetAttrString(py_ast, "Expr");
    raise_if_failed(env, py_Expr);
    auto py_Expr_guard = PyDecRefGuard(py_Expr);

    auto is_Expr_instance = PyObject_IsInstance(py_last_expr, py_Expr);
    raise_if_failed(env, is_Expr_instance);

    if (is_Expr_instance) {
      auto py_module_body_pop = PyObject_GetAttrString(py_module_body, "pop");
      raise_if_failed(env, py_module_body_pop);
      auto py_module_body_pop_guard = PyDecRefGuard(py_module_body_pop);
      py_module_body_size -= 1;

      py_last_expr = PyObject_CallNoArgs(py_module_body_pop);
      raise_if_failed(env, py_last_expr);
      auto py_last_statement_guard = PyDecRefGuard(py_last_expr);

      auto py_last_expr_value = PyObject_GetAttrString(py_last_expr, "value");
      raise_if_failed(env, py_last_expr_value);
      auto py_last_expr_value_guard = PyDecRefGuard(py_last_expr_value);

      auto py_Expression = PyObject_GetAttrString(py_ast, "Expression");
      raise_if_failed(env, py_Expression);
      auto py_Expression_guard = PyDecRefGuard(py_Expression);

      auto py_Expression_args = PyTuple_Pack(1, py_last_expr_value);
      raise_if_failed(env, py_Expression_args);
      auto py_Expression_args_guard = PyDecRefGuard(py_Expression_args);

      auto py_expr = PyObject_Call(py_Expression, py_Expression_args, NULL);
      raise_if_failed(env, py_expr);
      auto py_expr_guard = PyDecRefGuard(py_expr);

      for (const auto &attr_name : {"lineno", "col_offset", "end_col_offset"}) {
        auto attr_value = PyObject_GetAttrString(py_last_expr, attr_name);
        raise_if_failed(env, attr_value);
        auto attr_value_guard = PyDecRefGuard(attr_value);

        raise_if_failed(env,
                        PyObject_SetAttrString(py_expr, attr_name, attr_value));
      }

      auto py_eval_string = PyUnicode_FromStringAndSize("eval", 4);
      raise_if_failed(env, py_eval_string);
      auto py_eval_string_guard = PyDecRefGuard(py_eval_string);

      auto py_compile_args =
          PyTuple_Pack(3, py_expr, py_file_string, py_eval_string);
      raise_if_failed(env, py_compile_args);
      auto py_compile_args_guard = PyDecRefGuard(py_compile_args);

      py_last_expr_code = PyObject_Call(py_compile, py_compile_args, NULL);
      raise_if_failed(env, py_last_expr_code);

      py_last_expr_code_guard = py_last_expr_code;
    }
  }

  if (py_module_body_size > 0) {
    auto py_compile_args =
        PyTuple_Pack(3, py_module_ast, py_file_string, py_exec_string);
    raise_if_failed(env, py_compile_args);
    auto py_compile_args_guard = PyDecRefGuard(py_compile_args);

    py_body_code = PyObject_Call(py_compile, py_compile_args, NULL);
    raise_if_failed(env, py_body_code);
  }

  py_last_expr_code_guard = nullptr;

  return std::make_tuple(py_body_code, py_last_expr_code);
}

std::tuple<std::optional<ExObject>, fine::Term>
eval(ErlNifEnv *env, ErlNifBinary code, std::string code_md5,
     std::vector<std::tuple<ErlNifBinary, ExObject>> globals,
     fine::Term stdout_device, fine::Term stderr_device) {
  ensure_initialized();

  // Step 1: compile (or get cached result)

  PyObjectPtr py_body_code = nullptr;
  PyObjectPtr py_last_expr_code = nullptr;

  {
    // Note that it is important that we don't hold GIL while trying
    // to acquire the mutex, otherwise we could deadlock.
    auto guard = std::lock_guard<std::mutex>(compilation_cache_mutex);

    if (compilation_cache.find(code_md5) == compilation_cache.end()) {
      auto gil_guard = PyGILGuard();
      auto compiled = compile(env, code);
      compilation_cache[code_md5] = compiled;
    }

    auto compiled = compilation_cache[code_md5];
    py_body_code = std::get<0>(compiled);
    py_last_expr_code = std::get<1>(compiled);
  }

  auto gil_guard = PyGILGuard();

  // Step 2: prepare globals

  // For globals, we create a new module named __main__ and use its
  // dict as globals (extended with the given entries). It corresponds
  // to the following Python code:
  //
  //     import types
  //     import sys
  //
  //     main_module = types.ModuleType("__main__")
  //     main_module.__dict__["__builtins__"] = builtins
  //     sys.modules["__main__"] = main_module
  //
  //     main_module.__dict__["x"] = 1
  //     main_module.__dict__["y"] = 2
  //
  //     eval(..., main_module.__dict__)
  //
  // Note that a more straightforward approach would be to get the
  // default __main__ module, copy its dict and use that as globals.
  // However, to better mirror actual Python execution, we want to
  // use an actual module dict as globals.
  //
  // A practical scenario where this matters is pickling an object
  // of a class defined via evaluation. The pickle module consults
  // sys.modules (in this case sys.modules["__main__"]) and looks up
  // the class or function name. If we use a plain dict as globals,
  // the class will be defined only in that dict and such lookups will
  // fail.
  //
  // However, it is worth noting that the current approach is not
  // perfect as it can fail under race conditions. Evaluations may
  // happen concurrently (if one of them releases GIL, for example,
  // by calling time.sleep) and there can be other threads started
  // by evaluation. If a new evaluation sets sys.modules["__main__"]
  // and yields, an older evaluation or thread may resume and at that
  // point the value of sys.modules["__main__"] is no longer accurate.
  // For more details see [1].
  //
  // [1]: https://github.com/marimo-team/marimo/pull/811

  auto py_types = PyImport_ImportModule("types");
  raise_if_failed(env, py_types);
  auto py_types_guard = PyDecRefGuard(py_types);

  auto py_ModuleType = PyObject_GetAttrString(py_types, "ModuleType");
  raise_if_failed(env, py_ModuleType);
  auto py_ModuleType_guard = PyDecRefGuard(py_ModuleType);

  auto py_main_module_string = PyUnicode_FromStringAndSize("__main__", 8);
  raise_if_failed(env, py_main_module_string);
  auto py_main_module_string_guard = PyDecRefGuard(py_main_module_string);

  auto py_ModuleType_args = PyTuple_Pack(1, py_main_module_string);
  raise_if_failed(env, py_ModuleType_args);
  auto py_ModuleType_args_guard = PyDecRefGuard(py_ModuleType_args);

  auto py_main_module = PyObject_Call(py_ModuleType, py_ModuleType_args, NULL);
  raise_if_failed(env, py_main_module);
  auto py_main_module_guard = PyDecRefGuard(py_main_module);

  auto py_globals = PyModule_GetDict(py_main_module);
  raise_if_failed(env, py_globals);

  auto py_builtins = PyEval_GetBuiltins();
  raise_if_failed(env, py_builtins);

  raise_if_failed(
      env, PyDict_SetItemString(py_globals, "__builtins__", py_builtins));

  // The IO capture consists of the following steps:
  //
  //   1. We dump EvalInfo into Python bytes and store it in globals
  //      as __pythonx_eval_info_bytes__.
  //
  //   2. When IO happens, our custom sys.stdout.write (overridden on
  //      init) retrieves the info from globals and calls the
  //      pythonx_handle_io_write C function, passing the info.
  //
  //   3. The pythonx_handle_io_write C function loads EvalInfo and
  //      uses it to send messages to the specified process.
  //
  // Each step has a bit more specifics, but they are explained alongside
  // the corresponding code.

  // Here we dump the EvalInfo struct into Python bytes object and
  // put it in globals. We need to pass all of the data, rather than
  // a pointer, because it may be used during IO from Python threads,
  // even after the NIF finished. The ErlNifPid struct is opaque, so
  // we need to store struct memory contents anyway, hence we do this
  // for the whole EvalInfo struct at once.
  //
  // Note that copying struct memory contents into a byte buffer and
  // vice versa is safe, as long as the struct is always allocated
  // using its own type (to guarantee proper alignment). Contrarily,
  // casting a buffer (such as char*) to struct pointer is not safe.
  auto eval_info = EvalInfo{};
  eval_info.stdout_device = stdout_device;
  eval_info.stderr_device = stderr_device;
  eval_info.env = env;
  eval_info.thread_id = std::this_thread::get_id();

  auto py_eval_info_bytes = PyBytes_FromStringAndSize(
      reinterpret_cast<const char *>(&eval_info), sizeof(EvalInfo));
  raise_if_failed(env, py_eval_info_bytes);

  raise_if_failed(env, PyDict_SetItemString(py_globals,
                                            "__pythonx_eval_info_bytes__",
                                            py_eval_info_bytes));

  auto py_sys = PyImport_AddModule("sys");
  raise_if_failed(env, py_sys);

  auto py_modules = PyObject_GetAttrString(py_sys, "modules");
  raise_if_failed(env, py_modules);
  auto py_modules_guard = PyDecRefGuard(py_modules);

  raise_if_failed(env,
                  PyDict_SetItemString(py_modules, "__main__", py_main_module));

  auto py_globals_initial = PyDict_Copy(py_globals);
  raise_if_failed(env, py_globals_initial);
  auto py_globals_guard = PyDecRefGuard(py_globals_initial);

  for (const auto &[key, value] : globals) {
    auto py_key = PyUnicode_FromStringAndSize(
        reinterpret_cast<const char *>(key.data), key.size);
    raise_if_failed(env, py_key);

    auto result = PyDict_SetItem(py_globals, py_key, value.resource->py_object);
    Py_DecRef(py_key);
    raise_if_failed(env, result);
  }

  // Step 3: eval body and expression

  if (py_body_code != nullptr) {
    auto py_body_result = PyEval_EvalCode(py_body_code, py_globals, py_globals);
    raise_if_failed(env, py_body_result);
    Py_DecRef(py_body_result);
  }

  auto result = std::optional<ExObject>();

  if (py_last_expr_code != nullptr) {
    auto py_result = PyEval_EvalCode(py_last_expr_code, py_globals, py_globals);
    raise_if_failed(env, py_result);
    result = ExObject(fine::make_resource<ExObjectResource>(py_result));
  }

  // Step 4: flat-decode globals

  std::vector<ERL_NIF_TERM> key_terms;
  std::vector<ERL_NIF_TERM> value_terms;

  PyObjectPtr py_key, py_value;
  Py_ssize_t pos = 0;

  auto py_str_type = PyDict_GetItemString(py_builtins, "str");
  raise_if_failed(env, py_str_type);

  while (PyDict_Next(py_globals, &pos, &py_key, &py_value)) {
    // If the key was present in the default globals, ignore it
    if (PyDict_GetItem(py_globals_initial, py_key) != NULL) {
      continue;
    }

    auto is_unicode = PyObject_IsInstance(py_key, py_str_type);
    raise_if_failed(env, is_unicode);
    // If the key is not a string, ignore it. This can happen if the
    // globals dict is modified directly, but that's not expected.
    if (!is_unicode) {
      continue;
    }

    auto key_term = py_str_to_binary_term(env, py_key);
    key_terms.push_back(key_term);

    // Incref before making the resource
    Py_IncRef(py_value);
    auto ex_value = ExObject(fine::make_resource<ExObjectResource>(py_value));
    value_terms.push_back(fine::encode(env, ex_value));
  }

  ERL_NIF_TERM map;
  if (!enif_make_map_from_arrays(env, key_terms.data(), value_terms.data(),
                                 key_terms.size(), &map)) {
    throw std::runtime_error("failed to make a map");
  }

  return std::make_tuple(result, map);
}

FINE_NIF(eval, ERL_NIF_DIRTY_JOB_CPU_BOUND);

} // namespace pythonx

FINE_INIT("Elixir.Pythonx.NIF");

// Below are functions we call from Python code

pythonx::EvalInfo eval_info_from_bytes(const char *eval_info_bytes) {
  // Note that we allocate EvalInfo first, so it will have the proper
  // alignment and memcpy simply restores the original struct state.
  auto eval_info = pythonx::EvalInfo{};
  std::memcpy(&eval_info, eval_info_bytes, sizeof(pythonx::EvalInfo));

  return eval_info;
}

ErlNifEnv *get_caller_env(pythonx::EvalInfo eval_info) {
  // The enif_whereis_pid and enif_send functions require passing the
  // caller env. Stdout write may be called by the evaluated code from
  // the NIF call, but it may also be called by a Python thread, after
  // the NIF call already finished. Since the BEAM uses OS threads for
  // its schedulers, we can simply check if this function is invoked
  // in the same thread as the NIF, or in a different one (Python thread).
  bool is_main_thread = std::this_thread::get_id() == eval_info.thread_id;
  auto caller_env = is_main_thread ? eval_info.env : NULL;

  return caller_env;
}

extern "C" void pythonx_handle_io_write(const char *message,
                                        const char *eval_info_bytes,
                                        bool type) {
  auto eval_info = eval_info_from_bytes(eval_info_bytes);

  auto env = enif_alloc_env();
  auto caller_env = get_caller_env(eval_info);

  // Note that we send the output to Pythonx.Janitor and it then sends
  // it to the device. We do this to avoid IO replies being sent to
  // the calling Elixir process (which would be unexpected). Additionally,
  // we cannot send to remote PIDs from a NIF, while the Janitor can.
  auto janitor_name = fine::encode(env, pythonx::atoms::ElixirPythonxJanitor);
  ErlNifPid janitor_pid;
  if (enif_whereis_pid(caller_env, janitor_name, &janitor_pid)) {
    auto device = type == 0 ? eval_info.stdout_device : eval_info.stderr_device;

    auto msg = fine::encode(env, std::make_tuple(pythonx::atoms::output,
                                                 std::string(message), device));
    enif_send(caller_env, &janitor_pid, env, msg);
    enif_free_env(env);
  } else {
    std::cerr << "[pythonx] whereis(Pythonx.Janitor) failed. This is "
                 "unexpected and an output will be dropped"
              << std::endl;
  }
}

extern "C" void
pythonx_handle_send_tagged_object(const char *pid_bytes, const char *tag,
                                  pythonx::python::PyObjectPtr *py_object,
                                  const char *eval_info_bytes) {
  auto eval_info = eval_info_from_bytes(eval_info_bytes);

  auto caller_env = get_caller_env(eval_info);
  auto env = enif_alloc_env();

  auto pid = ErlNifPid{};
  std::memcpy(&pid, pid_bytes, sizeof(ErlNifPid));

  auto msg = fine::encode(
      env, std::make_tuple(
               fine::Atom(tag),
               pythonx::ExObject(
                   fine::make_resource<pythonx::ExObjectResource>(py_object))));
  enif_send(caller_env, &pid, env, msg);
  enif_free_env(env);
}
