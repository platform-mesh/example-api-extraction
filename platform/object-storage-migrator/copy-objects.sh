#!/usr/bin/env sh

set -eu

# setenv sets protocol specific environment variables for the rclone backend
setenv() {
    remote="$1"
    uri="$2"
    dir="$3"

    case "$uri" in
        # these are just guess values from claude, real values tbd
        (s3://*)
            export "RCLONE_CONFIG_${remote}_TYPE=s3"
            export "RCLONE_CONFIG_${remote}_PROVIDER=AWS"
            export "RCLONE_CONFIG_${remote}_REGION=eu"
            export "RCLONE_CONFIG_${remote}_ENDPOINT=" # TODO
            ;;
        (gs://*)
            export "RCLONE_CONFIG_${remote}_TYPE=google cloud storage"
            export "RCLONE_CONFIG_${remote}_ENDPOINT=http://floci-gcp.floci-gcp.svc.cluster.local:4588/"
            ;;
        (az://*)
            export "RCLONE_CONFIG_${remote}_TYPE=azureblob"
            export "RCLONE_CONFIG_${remote}_ACCOUNT=devstoreaccount1"
            export "RCLONE_CONFIG_${remote}_KEY=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
            export "RCLONE_CONFIG_${remote}_ENDPOINT=http://floci-azure.floci-azure.svc.cluster.local:4577/devstoreaccount1"
            ;;
        *)
            echo "unsupported protocol: $uri" >&2
            exit 1
            ;;
    esac
}

setenv origin "$ORIGIN_URI" /creds/origin
setenv dest "$DESTINATION_URI" /creds/destination

exec rclone copy "origin:${ORIGIN_PATH}" "dest:${DESTINATION_PATH}" --progress
