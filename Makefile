PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_PATH = $(PRIV_DIR)/libpythonx.so

C_SRC = $(shell pwd)/c_src/pythonx
CPPFLAGS = -shared -fPIC -std=c++17 -Wall -Wextra -Wno-unused-parameter -Wno-comment
CPPFLAGS += -I$(ERTS_INCLUDE_DIR)

ifdef DEBUG
	CPPFLAGS += -g
else
	CPPFLAGS += -O3
endif

UNAME_S := $(shell uname -s)
ifndef TARGET_ABI
ifeq ($(UNAME_S),Darwin)
	TARGET_ABI = darwin
endif
endif

ifeq ($(TARGET_ABI),darwin)
	CPPFLAGS += -undefined dynamic_lookup -flat_namespace
endif

SOURCES = $(wildcard $(C_SRC)/*.cpp)
HEADERS = $(wildcard $(C_SRC)/*.hpp)

build: $(NIF_PATH)
	@ echo > /dev/null # Dummy command to avoid the default output "Nothing to be done"

$(NIF_PATH): $(SOURCES) $(HEADERS)
	@ mkdir -p $(PRIV_DIR)
	$(CC) $(CPPFLAGS) $(SOURCES) -o $(NIF_PATH)
