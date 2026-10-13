PRIV_DIR := $(MIX_APP_PATH)/priv
NIF_PATH := $(PRIV_DIR)/libpythonx.so
C_SRC := $(shell pwd)/c_src

CPPFLAGS := -shared -fPIC -fvisibility=hidden -std=c++17 -Wall -Wextra -Wno-unused-parameter -Wno-comment
CPPFLAGS += -I$(ERTS_INCLUDE_DIR) -I$(FINE_INCLUDE_DIR)

# PYTHONX_BINARIES is always set by make_env in mix.exs.
# "safe" copies bytes (no dangling pointer risk after finalization).
# "fast" uses zero-copy resource binaries (existing behavior).
ifeq ($(PYTHONX_BINARIES),safe)
	CPPFLAGS += -DPYTHONX_SAFE_BINARIES
else ifeq ($(PYTHONX_BINARIES),fast)
	CPPFLAGS += -DPYTHONX_FAST_BINARIES
else
$(error PYTHONX_BINARIES must be "safe" or "fast")
endif

ifdef DEBUG
	CPPFLAGS += -g
else
	CPPFLAGS += -O3
endif

ifndef TARGET_ABI
  TARGET_ABI := $(shell uname -s | tr '[:upper:]' '[:lower:]')
endif

ifeq ($(TARGET_ABI),darwin)
	CPPFLAGS += -undefined dynamic_lookup -flat_namespace
endif

SOURCES := $(wildcard $(C_SRC)/*.cpp)
HEADERS := $(wildcard $(C_SRC)/*.hpp)

# Stamp file written by make_env (mix.exs) recording the current
# PYTHONX_BINARIES value. A change in the config triggers a recompile
# because the NIF target depends on this file's timestamp.
BINARIES_STAMP := $(MIX_MANIFEST_PATH)/pythonx_binaries.stamp

all: $(NIF_PATH)
	@ echo > /dev/null # Dummy command to avoid the default output "Nothing to be done"

$(NIF_PATH): $(SOURCES) $(HEADERS) $(BINARIES_STAMP)
	@ mkdir -p $(PRIV_DIR)
	$(CXX) $(CPPFLAGS) $(SOURCES) -o $(NIF_PATH)
