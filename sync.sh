#!/bin/bash

set -uo pipefail

###############################################################################
# 基础配置
###############################################################################

HUB="registry.cn-hangzhou.aliyuncs.com"
REPO="chenby"

SKOPEO="/tmp/skopeo"

# 单个镜像最大运行时间：30 分钟
IMAGE_TIMEOUT=1800

# 单个镜像最大重试次数
RETRY_COUNT=3

# 每次重试之间等待时间
RETRY_WAIT=10

# 是否同步所有架构
# 1 = 是，相当于原来的 -a
# 0 = 否
SYNC_ALL_ARCH=true

# 日志目录
LOG_DIR="/tmp/sys_images_sync"

mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/sync-$(date '+%Y%m%d-%H%M%S').log"

###############################################################################
# 日志
###############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

###############################################################################
# 错误处理
###############################################################################

FAILED_IMAGES=()
SUCCESS_IMAGES=()
SKIPPED_IMAGES=()

###############################################################################
# 检查依赖
###############################################################################

check_environment() {

    log "========================================"
    log "Checking environment"
    log "========================================"

    if [ ! -x "${SKOPEO}" ]; then
        log "[ERROR] skopeo not found: ${SKOPEO}"
        exit 1
    fi

    if [ ! -f "sync.yaml" ]; then
        log "[ERROR] sync.yaml not found"
        exit 1
    fi

    if ! command -v timeout >/dev/null 2>&1; then
        log "[ERROR] timeout command not found"
        exit 1
    fi

    if [ -z "${HUB_USERNAME:-}" ]; then
        log "[ERROR] HUB_USERNAME is empty"
        exit 1
    fi

    if [ -z "${HUB_PASSWORD:-}" ]; then
        log "[ERROR] HUB_PASSWORD is empty"
        exit 1
    fi

    log "[INFO] skopeo  : ${SKOPEO}"
    log "[INFO] registry: ${HUB}"
    log "[INFO] repo    : ${REPO}"
    log "[INFO] timeout : ${IMAGE_TIMEOUT}s"
    log "[INFO] retry   : ${RETRY_COUNT}"
    log "[INFO] log     : ${LOG_FILE}"
}


###############################################################################
# 登录
###############################################################################

docker_login() {

    log ""
    log "========================================"
    log "Login registry"
    log "========================================"

    if sudo "${SKOPEO}" login \
        -u "${HUB_USERNAME}" \
        -p "${HUB_PASSWORD}" \
        "${HUB}" >>"${LOG_FILE}" 2>&1
    then
        log "[SUCCESS] Registry login success"
    else
        log "[ERROR] Registry login failed"
        exit 1
    fi
}


###############################################################################
# 获取 YAML 中的镜像列表
#
# 使用 Python + PyYAML 解析，避免依赖 yq。
#
# 输出格式：
#
# docker.elastic.co|beats/auditbeat|9.5.4
# docker.elastic.co|beats/filebeat|9.5.4
#
###############################################################################

get_images_from_yaml() {

    local yaml_file="$1"

    if [ ! -f "${yaml_file}" ]; then
        return 0
    fi

    python3 - "${yaml_file}" <<'PY'
import sys
import yaml

filename = sys.argv[1]

with open(filename, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

if not isinstance(data, dict):
    sys.exit(0)

for registry, registry_data in data.items():

    if not isinstance(registry_data, dict):
        continue

    images = registry_data.get("images", {})

    if not isinstance(images, dict):
        continue

    for image, tags in images.items():

        if tags is None:
            continue

        if not isinstance(tags, list):
            tags = [tags]

        for tag in tags:

            if tag is None:
                continue

            tag = str(tag).strip()

            if not tag:
                continue

            print(
                "{}|{}|{}".format(
                    registry,
                    image,
                    tag
                )
            )
PY
}


###############################################################################
# 同步单个镜像
###############################################################################

sync_one_image() {

    local registry="$1"
    local image="$2"
    local tag="$3"

    local source
    local target
    local attempt
    local ret
    local image_log

    source="docker://${registry}/${image}:${tag}"
    target="docker://${HUB}/${REPO}/${image}:${tag}"

    image_log="${LOG_DIR}/$(echo "${registry}_${image}_${tag}" | sed 's#[/:]#_#g').log"

    log ""
    log "============================================================"
    log "[IMAGE] ${source}"
    log "[IMAGE] -> ${target}"
    log "============================================================"

    attempt=1

    while [ "${attempt}" -le "${RETRY_COUNT}" ]; do

        log "[INFO] Attempt ${attempt}/${RETRY_COUNT}"
        log "[INFO] Timeout ${IMAGE_TIMEOUT}s"

        : > "${image_log}"

        if [ "${SYNC_ALL_ARCH}" = true ]; then

            timeout \
                --foreground \
                "${IMAGE_TIMEOUT}" \
                sudo "${SKOPEO}" \
                --insecure-policy \
                copy \
                --all \
                "${source}" \
                "${target}" \
                >>"${image_log}" 2>&1

        else

            timeout \
                --foreground \
                "${IMAGE_TIMEOUT}" \
                sudo "${SKOPEO}" \
                --insecure-policy \
                copy \
                "${source}" \
                "${target}" \
                >>"${image_log}" 2>&1

        fi

        ret=$?

        # 输出本次同步日志
        cat "${image_log}" | tee -a "${LOG_FILE}"

        if [ "${ret}" -eq 0 ]; then

            log "[SUCCESS] ${source}"

            SUCCESS_IMAGES+=(
                "${registry}/${image}:${tag}"
            )

            return 0

        elif [ "${ret}" -eq 124 ]; then

            log "[TIMEOUT] ${source}"
            log "[TIMEOUT] exceeded ${IMAGE_TIMEOUT} seconds"

        else

            log "[FAILED] ${source}"
            log "[FAILED] exit code: ${ret}"

        fi

        if [ "${attempt}" -lt "${RETRY_COUNT}" ]; then

            log "[INFO] Waiting ${RETRY_WAIT}s before retry..."

            sleep "${RETRY_WAIT}"

        fi

        attempt=$((attempt + 1))

    done

    log "[ERROR] Failed after ${RETRY_COUNT} attempts:"
    log "[ERROR] ${source}"

    FAILED_IMAGES+=(
        "${registry}/${image}:${tag}"
    )

    return 1
}


###############################################################################
# 处理一个 YAML
###############################################################################

process_yaml() {

    local yaml_file="$1"

    log ""
    log "############################################################"
    log "# Processing ${yaml_file}"
    log "############################################################"

    if [ ! -f "${yaml_file}" ]; then

        log "[INFO] ${yaml_file} does not exist, skip."

        return 0
    fi

    local image_count=0

    while IFS='|' read -r registry image tag; do

        if [ -z "${registry}" ]; then
            continue
        fi

        if [ -z "${image}" ]; then
            continue
        fi

        if [ -z "${tag}" ]; then
            continue
        fi

        image_count=$((image_count + 1))

        sync_one_image \
            "${registry}" \
            "${image}" \
            "${tag}" \
            || true

    done < <(get_images_from_yaml "${yaml_file}")

    log ""
    log "[INFO] ${yaml_file} processed."
    log "[INFO] Images: ${image_count}"
}


###############################################################################
# 打印结果
###############################################################################

print_summary() {

    log ""
    log ""
    log "============================================================"
    log "SYNC SUMMARY"
    log "============================================================"

    log "[SUCCESS] count: ${#SUCCESS_IMAGES[@]}"

    if [ "${#SUCCESS_IMAGES[@]}" -gt 0 ]; then

        log ""
        log "Successful images:"

        for image in "${SUCCESS_IMAGES[@]}"; do
            log "  + ${image}"
        done

    fi


    log ""
    log "[FAILED] count: ${#FAILED_IMAGES[@]}"

    if [ "${#FAILED_IMAGES[@]}" -gt 0 ]; then

        log ""
        log "Failed images:"

        for image in "${FAILED_IMAGES[@]}"; do
            log "  - ${image}"
        done

    fi


    log ""
    log "[SKIPPED] count: ${#SKIPPED_IMAGES[@]}"

    if [ "${#SKIPPED_IMAGES[@]}" -gt 0 ]; then

        log ""
        log "Skipped images:"

        for image in "${SKIPPED_IMAGES[@]}"; do
            log "  - ${image}"
        done

    fi

    log ""
    log "Log file:"
    log "${LOG_FILE}"

    log "============================================================"
}


###############################################################################
# Main
###############################################################################

main() {

    log ""
    log "============================================================"
    log "sys_images sync start"
    log "============================================================"

    check_environment

    docker_login

    process_yaml "sync.yaml"

    process_yaml "custom_sync.yaml"

    print_summary

    if [ "${#FAILED_IMAGES[@]}" -gt 0 ]; then

        log ""
        log "[ERROR] Some images failed."
        log "[ERROR] Failed count: ${#FAILED_IMAGES[@]}"

        exit 1

    fi

    log ""
    log "[SUCCESS] All images synchronized successfully."

    exit 0
}


main "$@"
