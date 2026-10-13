// A native thread owned by pythonx that acts as CPython's "main thread".
//
// CPython binds the thread that runs Py_InitializeEx to
// runtime->main_tstate, and Py_FinalizeEx must run on that same
// thread: when called from any other thread, CPython 3.13 does not
// swap the main thread state in, frees the calling thread's state as
// a "non-main" one, and then dereferences it while flushing std files.
// NIFs run on whichever dirty scheduler picks them up, and there is no
// way to pin two separate NIF calls to the same scheduler thread, so
// we own one thread for exactly those two calls. Everything else
// (eval, decode, sys.path setup) keeps running on the dirty
// schedulers with their own thread states.
//
// The thread is started in init() and joined in finalize(), so every
// finalize + re-init cycle gets a fresh main thread. It is only ever
// used while init_mutex is held, so a single-slot job handoff suffices.

#pragma once

#include <condition_variable>
#include <exception>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <thread>

#if defined(__APPLE__) || defined(__linux__)
#include <pthread.h>
#endif

namespace pythonx {

class MainThread {
  std::thread thread;
  std::mutex mutex;
  std::condition_variable cv;
  std::function<void()> job;
  bool stop = false;
  bool has_job = false;
  bool done = false;
  std::exception_ptr error;

  void loop() {
#if defined(__APPLE__)
    pthread_setname_np("pythonx-main");
#elif defined(__linux__)
    pthread_setname_np(pthread_self(), "pythonx-main");
#endif

    while (true) {
      std::function<void()> current_job;

      {
        auto lock = std::unique_lock<std::mutex>(mutex);
        cv.wait(lock, [&] { return has_job || stop; });

        if (!has_job) {
          return;
        }

        current_job = std::move(job);
        has_job = false;
      }

      std::exception_ptr current_error;

      try {
        current_job();
      } catch (...) {
        current_error = std::current_exception();
      }

      {
        auto lock = std::lock_guard<std::mutex>(mutex);
        error = current_error;
        done = true;
      }

      cv.notify_all();
    }
  }

public:
  // Spawns the loop thread. Must not be called while a previous
  // thread is still running; finalize() joins before init() starts
  // again.
  void start() {
    if (thread.joinable()) {
      throw std::runtime_error("pythonx main thread is already running");
    }

    {
      auto lock = std::lock_guard<std::mutex>(mutex);
      stop = false;
      has_job = false;
      done = false;
      error = nullptr;
    }

    thread = std::thread([this] { loop(); });
  }

  // Runs fn on the main thread and blocks until it returns. An
  // exception thrown by fn is rethrown on the calling thread.
  void run(std::function<void()> fn) {
    if (!thread.joinable()) {
      throw std::runtime_error("pythonx main thread is not running");
    }

    auto lock = std::unique_lock<std::mutex>(mutex);
    job = std::move(fn);
    has_job = true;
    done = false;
    error = nullptr;
    cv.notify_all();

    cv.wait(lock, [&] { return done; });

    auto current_error = error;
    error = nullptr;
    lock.unlock();

    if (current_error) {
      std::rethrow_exception(current_error);
    }
  }

  // Stops the loop and joins the thread. The object can be started
  // again afterwards.
  void join() {
    {
      auto lock = std::lock_guard<std::mutex>(mutex);
      stop = true;
    }

    cv.notify_all();

    if (thread.joinable()) {
      thread.join();
    }
  }
};

} // namespace pythonx
