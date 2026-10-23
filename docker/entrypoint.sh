#!/bin/bash
# =================================================================
#
# Authors: Just van den Broecke <justb4@gmail.com>
#          Benjamin Webb <benjamin.miller.webb@gmail.com>
#          Tom Kralidis <tomkralidis@gmail.com>
#
# Copyright (c) 2019 Just van den Broecke
# Copyright (c) 2024 Benjamin Webb
# Copyright (c) 2025 Tom Kralidis
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# =================================================================

# pygeoapi entry script

echo "START /entrypoint.sh"

set +e

export PYGEOAPI_HOME=/pygeoapi

if [[ -z "$PYGEOAPI_CONFIG" ]]; then
    export PYGEOAPI_CONFIG="${PYGEOAPI_HOME}/local.config.yml"
fi
if [[ -z "$PYGEOAPI_OPENAPI" ]]; then
    export PYGEOAPI_OPENAPI="${PYGEOAPI_HOME}/local.openapi.yml"
fi
if [[ -z "$PYGEOAPI_ASYNCAPI" ]]; then
    export PYGEOAPI_ASYNCAPI="${PYGEOAPI_HOME}/local.asyncapi.yml"
fi

# gunicorn env settings with defaults
SCRIPT_NAME=${SCRIPT_NAME:=/}
CONTAINER_NAME=${CONTAINER_NAME:=pygeoapi}
CONTAINER_HOST=${CONTAINER_HOST:=0.0.0.0}
CONTAINER_PORT=${CONTAINER_PORT:=80}
WSGI_APP=${WSGI_APP:=pygeoapi.flask_app:APP}
WSGI_WORKERS=${WSGI_WORKERS:=4}
WSGI_WORKER_TIMEOUT=${WSGI_WORKER_TIMEOUT:=6000}
WSGI_WORKER_CLASS=${WSGI_WORKER_CLASS:=gevent}
# keep-alive should exceed the idle timeout of any load balancer / ingress
# in front of pygeoapi, otherwise reused upstream connections get closed
# under the proxy and surface as intermittent 502s
WSGI_KEEP_ALIVE=${WSGI_KEEP_ALIVE:=75}
# time workers get to finish in-flight requests after SIGTERM; keep it
# below the Kubernetes terminationGracePeriodSeconds
WSGI_GRACEFUL_TIMEOUT=${WSGI_GRACEFUL_TIMEOUT:=30}
# recycle workers after N requests (0 disables) to bound memory growth
WSGI_MAX_REQUESTS=${WSGI_MAX_REQUESTS:=0}
WSGI_MAX_REQUESTS_JITTER=${WSGI_MAX_REQUESTS_JITTER:=0}
# worker heartbeat files; tmpfs avoids heartbeat stalls on overlay filesystems
WSGI_WORKER_TMP_DIR=${WSGI_WORKER_TMP_DIR:=/dev/shm}
# access log destination, e.g. '-' for stdout (default: disabled)
WSGI_ACCESS_LOG=${WSGI_ACCESS_LOG:=}

# pygeoapi env settings with defaults
PYGEOAPI_OPENAPI_GENERATE=${PYGEOAPI_OPENAPI_GENERATE:=true}
PYGEOAPI_OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION=${PYGEOAPI_OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION:=true}

if [ ${PYGEOAPI_OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION} = false ] ; then
    OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION='--no-fail-on-invalid-collection'
else
    OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION='--fail-on-invalid-collection'
fi

# What to invoke: default is to run gunicorn server
entry_cmd=${1:-run}

# Shorthand
function error() {
    echo "ERROR: $@"
    exit -1
}

# Workdir
cd ${PYGEOAPI_HOME}

echo "Default config in ${PYGEOAPI_CONFIG}"

if [ ${PYGEOAPI_OPENAPI_GENERATE} = false ] ; then
    # e.g. a pre-generated document mounted from a ConfigMap
    [[ -f "${PYGEOAPI_OPENAPI}" ]] || error "PYGEOAPI_OPENAPI_GENERATE=false but ${PYGEOAPI_OPENAPI} does not exist"
    echo "Skipping openapi.yml generation, using ${PYGEOAPI_OPENAPI}"
else
    echo "Trying to generate openapi.yml"
    /venv/bin/pygeoapi openapi generate ${PYGEOAPI_CONFIG} --output-file ${PYGEOAPI_OPENAPI} ${OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION}

    [[ $? -ne 0 ]] && error "openapi.yml could not be generated ERROR"

    echo "openapi.yml generated continue to pygeoapi"
fi

echo "Trying to generate asyncapi.yml"
/venv/bin/pygeoapi asyncapi generate ${PYGEOAPI_CONFIG} --output-file ${PYGEOAPI_ASYNCAPI}

[[ $? -ne 0 ]] && echo "asyncapi.yml could not be generated; skipping"

start_gunicorn() {
    # SCRIPT_NAME should not have value '/'
    [[ "${SCRIPT_NAME}" = '/' ]] && export SCRIPT_NAME="" && echo "make SCRIPT_NAME empty from /"

    # fall back to gunicorn's default if the heartbeat dir is unusable
    WORKER_TMP_DIR_OPTS=""
    if [[ -n "${WSGI_WORKER_TMP_DIR}" && -d "${WSGI_WORKER_TMP_DIR}" && -w "${WSGI_WORKER_TMP_DIR}" ]]; then
        WORKER_TMP_DIR_OPTS="--worker-tmp-dir ${WSGI_WORKER_TMP_DIR}"
    fi

    ACCESS_LOG_OPTS=""
    if [[ -n "${WSGI_ACCESS_LOG}" ]]; then
        ACCESS_LOG_OPTS="--access-logfile ${WSGI_ACCESS_LOG}"
    fi

    echo "Starting gunicorn name=${CONTAINER_NAME} on ${CONTAINER_HOST}:${CONTAINER_PORT} with ${WSGI_WORKERS} workers and SCRIPT_NAME=${SCRIPT_NAME}"
    exec /venv/bin/gunicorn --workers ${WSGI_WORKERS} \
        --worker-class=${WSGI_WORKER_CLASS} \
        --timeout ${WSGI_WORKER_TIMEOUT} \
        --graceful-timeout ${WSGI_GRACEFUL_TIMEOUT} \
        --keep-alive ${WSGI_KEEP_ALIVE} \
        --max-requests ${WSGI_MAX_REQUESTS} \
        --max-requests-jitter ${WSGI_MAX_REQUESTS_JITTER} \
        ${WORKER_TMP_DIR_OPTS} \
        ${ACCESS_LOG_OPTS} \
        --name=${CONTAINER_NAME} \
        --bind ${CONTAINER_HOST}:${CONTAINER_PORT} \
        ${@} \
        ${WSGI_APP}
}

case ${entry_cmd} in
    # Run Unit tests
    test)
        for test_py in $(ls tests/test_*.py)
        do
            # Skip tests requiring backend server or libs installed
            case ${test_py} in
                tests/test_elasticsearch__provider.py)
                    ;&
                tests/test_sensorthings_provider.py)
                    ;&
                tests/test_postgresql_provider.py)
                    ;&
                tests/test_mongo_provider.py)
                    echo "Skipping: ${test_py}"
                    ;;
                *)
                    /venv/bin/python3 -m pytest ${test_py}
                    ;;
            esac
        done
    ;;

    # Run pygeoapi server
    run)
        # Start
        start_gunicorn
        ;;

    # Run pygeoapi server with hot reload
    run-with-hot-reload)
        # Lock all Python files (for gunicorn hot reload), if running with user root
        if [[ $(id -u) -eq 0 ]]
        then
            echo "Running pygeoapi as root"
            find . -type f -name "*.py" | xargs chmod 0444
        fi

        # Start with hot reload options
        start_gunicorn --reload --reload-extra-file ${PYGEOAPI_CONFIG}
        ;;

    *)
        error "unknown command arg: must be run (default), run-with-hot-reload, or test"
        ;;
esac

echo "END /entrypoint.sh"
