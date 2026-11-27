ERL_ROOT ?= $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERTS_INCLUDE ?= $(wildcard $(ERL_ROOT)/erts-*/include)
UCX_PREFIX ?= /usr

CFLAGS += -O2 -g -fPIC -Wall -Wextra -I$(ERTS_INCLUDE) -I$(UCX_PREFIX)/include
LDFLAGS += -shared -L$(UCX_PREFIX)/lib -L$(UCX_PREFIX)/lib/x86_64-linux-gnu -lucp -lucs

all: priv/ucx_dist_nif.so ebin/ucx_dist.app beams

priv/ucx_dist_nif.so: c_src/ucx_dist_nif.c
	mkdir -p priv
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

beams: $(wildcard src/*.erl) bench/ucx_bench.erl
	mkdir -p ebin
	erlc -o ebin src/*.erl bench/ucx_bench.erl

ebin/ucx_dist.app: src/ucx_dist.app.src
	mkdir -p ebin
	cp $< $@

clean:
	rm -rf ebin priv

.PHONY: all beams clean
