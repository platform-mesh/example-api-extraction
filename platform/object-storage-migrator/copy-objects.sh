#!/usr/bin/env sh

set -eu

# default to the paths mounted in the MigrationConfiguration so they can
# be overridden for local runs.
ORIGIN_DIR="${ORIGIN_DIR:-/secrets/origin}"
DEST_DIR="${DEST_DIR:-/secrets/dest}"

_seed() {
    d="$1"
    uri="$2"
    printf '%s' "$uri" > "$d/url"
    case "$uri" in
        (s3://*)
            printf 'http://localhost:4566' > "$d/endpoint"
            printf 'test' > "$d/access_key"
            printf 'test' > "$d/secret_key"
            ;;
        (gs://*)
            printf 'http://localhost:4588/' > "$d/endpoint"
            printf 'test-project' > "$d/project"
            printf 'true' > "$d/anonymous"
            ;;
        (az://*)
            printf 'devstoreaccount1' > "$d/account"
            printf 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==' > "$d/key"
            printf 'http://localhost:4577/devstoreaccount1' > "$d/endpoint"
            ;;
    esac
}

# copy-objects.sh local s3://mybucket az://mybucket
if [ "$#" -eq 3 ]; then
    kubectl port-forward -n floci-gcp services/floci-gcp 4588:4588 &>/dev/null &
    kubectl port-forward -n floci-az services/floci-az 4577:4577 &>/dev/null &
    kubectl port-forward -n floci-aws services/floci-aws 4566:4566 &>/dev/null &
    ORIGIN_DIR="$(mktemp -d)"
    _seed "$ORIGIN_DIR" "$2"
    DEST_DIR="$(mktemp -d)"
    _seed "$DEST_DIR" "$3"
fi

# secretval <dir> <file> <default>
# e.g.
#   secretval /secrets/origin access_key
secretval() {
    dir="$1"
    key="$2"
    default="${3:-}"
    if [ -f "$dir/$key" ]; then
        cat "$dir/$key"
    else
        printf '%s' "$default"
    fi
}


ORIGIN_URI="$(secretval "$ORIGIN_DIR" url)"
if [ -z "$ORIGIN_URI" ]; then
    echo "missing origin url"
    exit 1
fi

DESTINATION_URI="$(secretval "$DEST_DIR" url)"
if [ -z "$DESTINATION_URI" ]; then
    echo "missing destination url"
    exit 1
fi

setenv() {
    remote="$1"
    dir="$2"
    uri="$3"

    remote_upper="$(echo $remote | tr 'a-z' 'A-Z')"

    case "$uri" in
        (s3://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=s3"
            export "RCLONE_CONFIG_${remote_upper}_PROVIDER=Other"
            export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=$(secretval "$dir" endpoint)"
            export "RCLONE_CONFIG_${remote_upper}_ACCESS_KEY_ID=$(secretval "$dir" access_key)"
            export "RCLONE_CONFIG_${remote_upper}_SECRET_ACCESS_KEY=$(secretval "$dir" secret_key)"
            export "RCLONE_CONFIG_${remote_upper}_FORCE_PATH_STYLE=true"
            ;;
        (gs://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=google cloud storage"
            if [ -f "$dir/credentials" ]; then
                # for real GCD
                export "RCLONE_CONFIG_${remote_upper}_SERVICE_ACCOUNT_FILE=$dir/credentials"
            else
                export "RCLONE_CONFIG_${remote_upper}_PROJECT_NUMBER=$(secretval "$dir" project)"
                endpoint="$(secretval "$dir" endpoint)"
                [ -n "$endpoint" ] && export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=$endpoint"
                anonymous="$(secretval "$dir" anonymous)"
                [ -n "$anonymous" ] && export "RCLONE_CONFIG_${remote_upper}_ANONYMOUS=$anonymous"
            fi
            ;;
        (az://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=azureblob"
            export "RCLONE_CONFIG_${remote_upper}_ACCOUNT=$(secretval "$dir" account)"
            export "RCLONE_CONFIG_${remote_upper}_KEY=$(secretval "$dir" key)"
            endpoint="$(secretval "$dir" endpoint)"
            [ -n "$endpoint" ] && export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=$endpoint"
            ;;
        (local://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=local"
            ;;
        *)
            echo "unsupported protocol: $uri" >&2
            exit 1
            ;;
    esac
}

setenv origin "$ORIGIN_DIR" "$ORIGIN_URI"
setenv dest "$DEST_DIR" "$DESTINATION_URI"

exec rclone copyto -vvv "origin:${ORIGIN_URI#*://}" "dest:${DESTINATION_URI#*://}" --progress
