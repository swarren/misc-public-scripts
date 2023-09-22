#!/bin/bash

# Copyright 2023 Stephen Warren <swarren@wwwdotorg.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

# Copies a Docker image from the local Docker daemon to a docker daemon that's
# accessible via ssh. Optimize the copy by avoiding the transfer of any layer
# that's already present in the remote Docker daemon.

set -e
set -o pipefail

usage() {
    echo "$0: Copy a docker image from local daemon to daemon on remote host" > /dev/stderr
    echo "Usage: $0 [options*] [user@]destination_host docker_image" > /dev/stderr
    echo "    --sshcmd  ssh_cmd  Set ssh command" > /dev/stderr
    echo "    --ssharg  ssh_arg  Add ssh argument" > /dev/stderr
    echo "    -h        Help" > /dev/stderr
    echo "    -v        Verbose; print layer and size information" > /dev/stderr
}

tmpdir=
cleanup() {
    if [ -n "${tmpdir}" ]; then
        rm -rf "${tmpdir}"
    fi
}
trap cleanup EXIT

ssh=ssh
ssh_args=()
verbose=0
while [[ "$1" =~ ^- ]]; do
    case "$1" in
        --sshcmd)
            shift
            ssh="$1"
            ;;
        --ssharg)
            shift
            ssh_args+=("$1")
            ;;
        -h)
            usage
            exit 1
            ;;
        -v)
            verbose=1
            ;;
        *)
            echo "ERROR: unknown option '$1'" > /dev/stderr
            usage
            exit 1
            ;;
    esac
    shift
done
destination_host="$1"; shift
if [ -z "${destination_host}" ]; then
    echo "ERROR: cmdline arg 'destination host' missing" > /dev/stderr
    usage
    exit 1
fi
docker_image="$1"; shift
if [ -z "${docker_image}" ]; then
    echo "ERROR: cmdline arg 'docker_image' missing" > /dev/stderr
    usage
    exit 1
fi
if [ $# -gt 1 ]; then
    echo "ERROR: too many cmdline args" > /dev/stderr
    usage
    exit 1
fi

list_shas=$(base64 -w0 <<'ENDOFHERE'
image_ids=($(docker image ls -a --format "{{json . }}" | jq -c -r '.ID'))
shas=()
for image_id in "${image_ids[@]}"; do
    docker inspect --format '{{ json . }}' "${image_id}" | jq -c -r '.RootFS.Layers[]'
done
ENDOFHERE
)
# Deliberately not an array, since bash has no "in array/set" operator...
remote_shas=$("${ssh}" "${ssh_args[@]}" "${destination_host}" bash -e -o pipefail "<(echo ${list_shas} | base64 -d)")

tmpdir=$(mktemp -d)
cd "${tmpdir}"
docker save -o image.tar "${docker_image}"
tar xf image.tar manifest.json
if [ ${verbose} -eq 1 ]; then
    du_out=($(du -b --apparent-size image.tar | awk '{print $1}'))
    size_orig="${du_out[0]}"
fi
config_json=$(cat manifest.json | jq -c -r '.[0].Config')
image_layers=($(cat manifest.json | jq -c -r '.[0].Layers[]'))
if [ -z "${config_json}" ]; then
    echo "ERROR: cannot determine config JSON filename" > /dev/stderr
    exit 1
fi
tar xf image.tar "${config_json}"
image_shas=($(cat "${config_json}" | jq -c -r '.rootfs.diff_ids[]'))
layer_count=${#image_layers[@]}
sha_count=${#image_shas[@]}
if [ $layer_count -ne $sha_count ]; then
    echo "ERROR: inconsistent layer count in manifest and config" > /dev/stderr
    exit 1
fi
to_delete=()
for i in $(seq 0 $(($layer_count - 1))); do
    sha="${image_shas[$i]}"
    layer="${image_layers[$i]}"
    if [[ "${remote_shas}" =~ ${sha} ]]; then
        to_delete+=("${layer}")
        if [ ${verbose} -eq 1 ]; then
            echo "Layer Skip:     ${sha} ${layer}"
        fi
    else
        if [ ${verbose} -eq 1 ]; then
            echo "Layer Transfer: ${sha} ${layer}"
        fi
    fi
done

if [ ${#to_delete[@]} -ne 0 ]; then
    tar --delete --file image.tar "${to_delete[@]}"
fi
if [ ${verbose} -eq 1 ]; then
    du_out=($(du -b --apparent-size image.tar | awk '{print $1}'))
    size_transfer="${du_out[0]}"
    percent=$(($size_transfer * 100 / $size_orig))
    echo "Image: orig ${size_orig} transfer ${size_transfer} percent ~${percent}%"
fi
"${ssh}" "${ssh_args[@]}" "${destination_host}" docker load < image.tar
