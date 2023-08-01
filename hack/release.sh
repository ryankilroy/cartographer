#!/usr/bin/env bash
# Copyright 2021 VMware
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname $0)"/.. && pwd)
readonly ROOT

readonly SCRATCH=${SCRATCH:-$(mktemp -d)}
readonly REGISTRY=${REGISTRY:-"$($ROOT/hack/ip.py):5001"}
readonly RELEASE_DATE=${RELEASE_DATE:-$(TZ=UTC date +"%Y-%m-%dT%H:%M:%SZ")}

readonly YTT_VERSION=0.42.0
readonly YTT_CHECKSUM=aa7074d08dc35e588ab0e014f53e98aec0cfed6c3babf8a953c4225007e49ae7

main() {
        readonly RELEASE_VERSION=${RELEASE_VERSION:-"v0.0.0-dev"}
        readonly RELEASE_IMAGE=${RELEASE_IMAGE:-$REGISTRY/cartographer:$RELEASE_VERSION}
        readonly PREVIOUS_VERSION=${PREVIOUS_VERSION:-$(git_previous_version $RELEASE_VERSION)}

        readonly RELEASE_USING_LEVER=${RELEASE_USING_LEVER:-false}
        readonly LEVER_KUBECONFIG_PATH=${LEVER_KUBECONFIG_PATH:-""}
        readonly LEVER_COMMIT_SHA=${LEVER_COMMIT_SHA:-"$(git rev-parse HEAD)"}

        show_vars
        cd $ROOT

        if [[ $RELEASE_USING_LEVER == true ]]; then
                if [[ -z $LEVER_KUBECONFIG_PATH ]]; then
                        echo "LEVER_KUBECONFIG_PATH must be set when RELEASE_USING_LEVER is true"
                        exit 1
                fi
                echo "Building using lever"
                lever_build_request
        else
                echo "Building locally"
                build_image
        fi
        generate_release
        create_release_notes
}

show_vars() {
        echo "
        PREVIOUS_VERSION:       $PREVIOUS_VERSION
        REGISTRY:               $REGISTRY
        RELEASE_DATE:           $RELEASE_DATE
        RELEASE_VERSION:        $RELEASE_VERSION
        RELEASE_IMAGE:          $RELEASE_IMAGE
        ROOT:                   $ROOT
        SCRATCH:                $SCRATCH
        YTT_VERSION:            $YTT_VERSION
        RELEASE_USING_LEVER:    $RELEASE_USING_LEVER
        LEVER_KUBECONFIG_PATH:  $LEVER_KUBECONFIG_PATH
        LEVER_COMMIT_SHA:       $LEVER_COMMIT_SHA
        "
}

lever_build_request() {
        ytt --ignore-unknown-comments -f ./hack/lever_build_request.yaml \
                --data-value commit_sha=$LEVER_COMMIT_SHA \
                --data-value release_image=$RELEASE_IMAGE \
                | kubectl --kubeconfig $LEVER_KUBECONFIG_PATH apply -f -
}

build_image() {
        docker build ../.. -t $RELEASE_IMAGE
        docker push $RELEASE_IMAGE
}

generate_release() {
        mkdir -p ./release
        ytt --ignore-unknown-comments -f ./config \
                -f ./hack/overlays/webhook-configuration.yaml \
                -f ./hack/overlays/component-labels.yaml \
                --data-value version=$RELEASE_VERSION \
                --data-value controller_image=$RELEASE_IMAGE > ./release/cartographer.yaml
}

create_release_notes() {
        local changeset
        changeset="$(git_changeset $RELEASE_VERSION $PREVIOUS_VERSION)"

        local assets_checksums
        assets_checksums=$(checksums ./release)

        release_body "$changeset" "$assets_checksums" "$PREVIOUS_VERSION" >./release/CHANGELOG.md
}

checksums() {
        local assets_directory=$1

        pushd $assets_directory &>/dev/null
        find . -name "*" -type f -exec sha256sum {} +
        popd &>/dev/null
}

git_changeset() {
        local current_version=$1
        local previous_version=$2

        [[ $current_version != v* ]] && current_version=v$current_version
        [[ $previous_version != v* ]] && previous_version=v$previous_version
        [[ $(git tag -l $current_version) == "" ]] && current_version=HEAD

        git -c log.showSignature=false \
                log \
                --pretty=oneline \
                --abbrev-commit \
                --no-decorate \
                --no-color \
                "${previous_version}..${current_version}"
}

git_previous_version() {
        local current_version=$1

        local version_filter
        version_filter=$(printf '^%s$' $current_version)

        [[ $(git tag -l $current_version) == "" ]] && version_filter='.'

        git tag --sort=-v:refname -l |
                grep -A30 $version_filter |
                grep -E '^v[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$' |
                head -n1
}

release_body() {
        local changeset="$1"
        local checksums="$2"
        local previous_version="$3"

        readonly fmt='
# 😎 Easy Installation

```
kubectl apply -f https://github.com/vmware-tanzu/cartographer/releases/download/<NEW_TAG>/cartographer.yaml
```

# 🚨 Breaking Changes

- <REPLACE_ME>

# 🚀 New Features

- <REPLACE_ME>

# 🐛 Bug Fixes

- <REPLACE_ME>

# ❤️ Thanks

Thanks to these contributors who contributed to <NEW_TAG>!
- <REPLACE_ME>

**Full Changelog**: https://github.com/vmware-tanzu/cartographer/compare/%s...<NEW_TAG>

# Change Set

%s


# Checksums

```
%s
```
  '
        printf "$fmt" "$previous_version" "$changeset" "$checksums"
}

main "$@"
