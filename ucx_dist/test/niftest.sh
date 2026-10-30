#!/bin/bash
export PATH=$HOME/.asdf/installs/erlang/27.1.2/bin:$PATH
export UCX_WARN_UNUSED_ENV_VARS=n
cd ~/ucx_dist
erlc -o ebin test/ucx_niftest.erl
timeout 120 erl -noshell -pa ebin -s ucx_niftest main "$@" 2>&1 | grep -v '^ [0-9]\|====' | head -30
