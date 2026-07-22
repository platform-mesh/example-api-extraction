#!/usr/bin/env sh

set -eu

# to allow local execution against in-kind floci
floci_gcp="floci-gcp.floci-gcp.svc.cluster.local:4588"
floci_az="floci-az.floci-az.svc.cluster.local:4577"
# copy-object.sh local <origin> <destination>
if [ "$#" -eq 3 ]; then
    kubectl port-forward -n floci-gcp services/floci-gcp 4588:4588 &>/dev/null &
    floci_gcp="localhost:4588"
    kubectl port-forward -n floci-az services/floci-az 4577:4577 &>/dev/null &
    floci_az="localhost:4577"
    ORIGIN_URI="$2"
    DESTINATION_URI="$3"
fi

# setenv sets protocol specific environment variables for the rclone backend
setenv() {
    remote="$1"
    uri="$2"

    remote_upper="$(echo $remote | tr 'a-z' 'A-Z')"

    case "$uri" in
        # these are just guess values from claude, real values tbd
        (s3://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=s3"
            export "RCLONE_CONFIG_${remote_upper}_PROVIDER=AWS"
            export "RCLONE_CONFIG_${remote_upper}_REGION=eu"
            export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=" # TODO
            ;;
        (gs://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=google cloud storage"
            export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=http://${floci_gcp}/"
            export "RCLONE_CONFIG_${remote_upper}_PROJECT_NUMBER=test-project"
            export "RCLONE_CONFIG_${remote_upper}_ANONYMOUS=true"
            ;;
        (az://*)
            export "RCLONE_CONFIG_${remote_upper}_TYPE=azureblob"
            export "RCLONE_CONFIG_${remote_upper}_ACCOUNT=devstoreaccount1"
            export "RCLONE_CONFIG_${remote_upper}_KEY=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
            export "RCLONE_CONFIG_${remote_upper}_ENDPOINT=http://${floci_az}/devstoreaccount1"
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

setenv origin "$ORIGIN_URI"
setenv dest "$DESTINATION_URI"

exec rclone copyto -vvv "origin:${ORIGIN_URI#*://}" "dest:${DESTINATION_URI#*://}" --progress
