#!/bin/bash

set -uo pipefail

###############################################################################
# 基础配置
###############################################################################

HUB="registry.cn-hangzhou.aliyuncs.com"
REPO="chenby"

SKOPEO="/tmp/skopeo"

# 单个镜像同步最大运行时间：30 分钟
IMAGE_TIMEOUT=1800

# 上游 Manifest / 架构检测最大等待时间：90 秒
INSPECT_TIMEOUT=90

# 单个镜像最大重试次数
RETRY_COUNT=3

# 每次重试之间等待时间
RETRY_WAIT=10

# 优先同步的 Linux 平台。每个镜像会先检查上游 Manifest，
# 只选择实际存在的 amd64 / arm64，避免因缺少某个架构导致整个镜像失败。
PREFERRED_PLATFORMS="linux/amd64,linux/arm64"

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
    log "[INFO] copy timeout    : ${IMAGE_TIMEOUT}s"
    log "[INFO] inspect timeout : ${INSPECT_TIMEOUT}s"
    log "[INFO] retry           : ${RETRY_COUNT}"
    log "[INFO] preferred platforms: ${PREFERRED_PLATFORMS}"
    log "[INFO] log     : ${LOG_FILE}"

    # 方案 A 需要新版 Skopeo 的平台筛选参数，提前检查，避免运行到一半才失败。
    if ! "${SKOPEO}" copy --help 2>&1 | grep -q -- "--multi-arch"; then
        log "[ERROR] Installed Skopeo does not support --multi-arch. Please upgrade it."
        exit 1
    fi
}


###############################################################################
# 登录
###############################################################################

docker_login() {

    local login_log
    local login_status

    log ""
    log "========================================"
    log "Login registry"
    log "========================================"

    # Use stdin rather than -p so the registry password is not exposed in
    # the process argument list. Keep login output separate for safe diagnosis.
    login_log=$(mktemp "${LOG_DIR}/registry-login.XXXXXX.log")

    if printf '%s' "${HUB_PASSWORD}" | sudo "${SKOPEO}" login \
        --username "${HUB_USERNAME}" \
        --password-stdin \
        "${HUB}" >"${login_log}" 2>&1
    then
        log "[SUCCESS] Registry login success"
        rm -f "${login_log}"
    else
        login_status=$?
        log "[ERROR] Registry login failed (exit code: ${login_status})"
        log "[ERROR] Skopeo login diagnostic output (credentials redacted):"

        # Redact credentials before writing command output to the Actions log.
        HUB_USERNAME="${HUB_USERNAME}" HUB_PASSWORD="${HUB_PASSWORD}" \
            python3 - "${login_log}" <<'PY'
import os
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as stream:
    lines = stream.readlines()

username = os.environ.get("HUB_USERNAME", "")
password = os.environ.get("HUB_PASSWORD", "")
for line in lines[-40:]:
    if password:
        line = line.replace(password, "***")
    if username:
        line = line.replace(username, "***")
    print(line, end="")
PY
        log "[ERROR] End of registry login diagnostic output"
        rm -f "${login_log}"
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
# 自动检测上游镜像实际支持的平台
#
# 对 manifest list / OCI index 读取 manifests[].platform；
# 对单架构 manifest 则通过 skopeo inspect 读取 Os/Architecture。
# 只选择本项目计划维护的 linux/amd64 和 linux/arm64。
###############################################################################

detect_sync_platforms() {

    local source="$1"
    local raw
    local platforms

    log "[INFO] Inspecting source manifest (timeout: ${INSPECT_TIMEOUT}s): ${source}"

    if raw=$(timeout --foreground --kill-after=10s "${INSPECT_TIMEOUT}" \
        sudo "${SKOPEO}" inspect --raw "${source}" 2>>"${LOG_FILE}"); then
        :
    else
        local inspect_ret=$?
        if [ "${inspect_ret}" -eq 124 ]; then
            log "[TIMEOUT] Manifest inspection exceeded ${INSPECT_TIMEOUT}s: ${source}"
        else
            log "[ERROR] Manifest inspection failed (exit code ${inspect_ret}): ${source}"
        fi
        return 1
    fi

    platforms=$(printf '%s' "${raw}" | python3 -c '
import json
import sys

try:
    manifest = json.load(sys.stdin)
except Exception as exc:
    print("Unable to parse manifest: {}".format(exc), file=sys.stderr)
    sys.exit(2)

preferred = ("linux/amd64", "linux/arm64")
found = set()

for item in manifest.get("manifests", []) or []:
    platform = item.get("platform") or {}
    os_name = platform.get("os")
    arch = platform.get("architecture")
    if os_name and arch:
        value = "{}/{}".format(os_name, arch)
        if value in preferred:
            found.add(value)

# 非 manifest-list（单架构镜像）在这里没有 manifests 数组；
# 交由下面的 skopeo inspect 格式化输出处理。
if found:
    print(",".join(value for value in preferred if value in found))
') || return 1

    if [ -z "${platforms}" ]; then
        log "[INFO] Manifest is not an index; detecting single-image architecture"

        if platforms=$(timeout --foreground --kill-after=10s "${INSPECT_TIMEOUT}" \
            sudo "${SKOPEO}" inspect \
            --format '{{.Os}}/{{.Architecture}}' \
            "${source}" 2>>"${LOG_FILE}"); then
            :
        else
            local inspect_ret=$?
            if [ "${inspect_ret}" -eq 124 ]; then
                log "[TIMEOUT] Architecture inspection exceeded ${INSPECT_TIMEOUT}s: ${source}"
            else
                log "[ERROR] Architecture inspection failed (exit code ${inspect_ret}): ${source}"
            fi
            return 1
        fi

        case ",${PREFERRED_PLATFORMS}," in
            *",${platforms},"*) ;;
            *)
                log "[ERROR] Unsupported or unknown platform '${platforms}' for ${source}"
                return 1
                ;;
        esac
    fi

    printf '%s' "${platforms}"
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
    local sync_platforms

    source="docker://${registry}/${image}:${tag}"
    # target="docker://${HUB}/${REPO}/${image}:${tag}"
    target="docker://${HUB}/${REPO}/${image#*/}:${tag}"

    image_log="${LOG_DIR}/$(echo "${registry}_${image}_${tag}" | sed 's#[/:]#_#g').log"

    log ""
    log "============================================================"
    log "[IMAGE] ${source}"
    log "[IMAGE] -> ${target}"
    log "============================================================"

    # 每个镜像单独检测架构，缺少某个平台时自动降级为实际存在的平台。
    if ! sync_platforms=$(detect_sync_platforms "${source}"); then
        log "[FAILED] Platform detection failed: ${source}"
        FAILED_IMAGES+=("${registry}/${image}:${tag}")
        return 1
    fi

    log "[INFO] Platform detection complete: ${sync_platforms}"

    attempt=1

    while [ "${attempt}" -le "${RETRY_COUNT}" ]; do

        log "[INFO] Attempt ${attempt}/${RETRY_COUNT}"
        log "[INFO] Timeout ${IMAGE_TIMEOUT}s"

        : > "${image_log}"

        # 只同步指定平台，并从最终 manifest list 中移除未复制的平台。
        # 修改 manifest list 后需移除 list signature，否则签名校验会失败。
        timeout \
            --foreground \
            "${IMAGE_TIMEOUT}" \
            sudo "${SKOPEO}" \
            --insecure-policy \
            copy \
            --multi-arch="${sync_platforms}" \
            --strip-removed-platforms \
            --remove-list-signatures \
            "${source}" \
            "${target}" \
            >>"${image_log}" 2>&1

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
