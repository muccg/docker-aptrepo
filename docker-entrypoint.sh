#!/bin/bash

set -e
set -x

TEMPLATE=/repo-template

function defaults {
    : ${SYNC_DEST="s3://repo.ccgapps.com.au/repo/ccg/ubuntu"}
    : ${REPO="/data/repo"}

    if ! [[ -z "$SYNC_FORCE" ]] ; then
        echo "Sync is forced"
        rm -f ${REPO}/.created
    fi

    if [[ -z "$SYNC_DELETE" ]] ; then
        SYNC_DELETE=""
    else
        echo "Sync will delete at destination"
        SYNC_DELETE="--delete"
    fi

    if [[ -z "$SYNC_DRYRUN" ]] ; then
        SYNC_DRYRUN=""
    else
        echo "Sync will be a dry run"
        SYNC_DRYRUN="--dryrun"
    fi

    echo "SYNC_DEST is ${SYNC_DEST}"

    export REPO SYNC_DEST SYNC_DELETE SYNC_DRYRUN
}


function lock {
    REPO_PATH=$1
    LOCKFILE="${REPO_PATH}/lock"
    echo "Getting lock on ${LOCKFILE}"
    lockfile ${LOCKFILE}
    trap 'unlock ${REPO_PATH}' EXIT SIGINT SIGTERM SIGHUP
}


function unlock {
    REPO_PATH=$1
    LOCKFILE="${REPO_PATH}/lock"
    echo "Removing ${LOCKFILE}."
    rm -f ${LOCKFILE}
    trap - EXIT
}

function initrepo {
    if [ ! -e ${REPO}/.created ]; then
        mkdir -p ${REPO}
        cp -R ${TEMPLATE}/* ${REPO}
        if [ -n "${KEY_ID}" ]; then
            perl -p -i -e "s/^#?SignWith:.*/SignWith: ${KEY_ID}/g" ${REPO}/conf/distributions
        fi
        touch ${REPO}/.created

        gpg --list-keys > /dev/null
        gpg --import /keys/*.asc
        gpg --import /data/keys/*.asc || true
    fi
}

function check_created {
    if [ ! -e ${REPO}/.created ]; then
        echo "[Error] First setup repo with \"initrepo\" command"
        exit 1
    fi
}

function uploadrepo {
    lock ${REPO}

    echo "Uploading ${REPO} to ${SYNC_DEST}"

    time aws s3 sync \
        ${REPO}/ ${SYNC_DEST} \
        ${SYNC_DELETE} \
        ${SYNC_DRYRUN} \
        --exclude "*.sh" \
        --exclude "conf/*" \
        --exclude ".created" \
        --exclude "lock"

    unlock ${REPO}
}

# download only RPMs
function downloadrepo {
    mkdir -p ${REPO}

    lock ${REPO}

    echo "Lock acquired, downloading repo"
    time aws s3 sync \
        ${SYNC_DEST} ${REPO} \
        ${SYNC_DELETE} \
        ${SYNC_DRYRUN} \
        --exclude "*" \
        --include "*.deb"

    unlock ${REPO}
}

function processincoming {
    check_created
    reprepro --ignore=undefinedtarget -Vb . processincoming ccg
}

defaults
initrepo
cd ${REPO}

case $1 in
initrepo)
    echo "[Run] Init repo"
    initrepo
    ;;
downloadrepo)
    echo "[Run] Download repo"
    downloadrepo
    ;;
uploadrepo)
    echo "[Run] Upload repo"
    uploadrepo
    ;;
processincoming)
    echo "[Run] Process incoming packages"
    processincoming
    ;;
update)
    echo "[Run] Processing incoming packages"
    processincoming
    echo "[Run] Upload repo"
    uploadrepo
    ;;
*)
    echo "[RUN]: Builtin command not provided [initrepo|downloadrepo|uploadrepo|processincoming|update]"
    echo "[RUN]: $@"
    exec "$@"
    ;;
esac

exit 0
