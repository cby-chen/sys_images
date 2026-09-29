import os
import re
import yaml
import requests
from packaging.version import Version, InvalidVersion


# 基本配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.yaml')
SYNC_FILE = os.path.join(BASE_DIR, 'sync.yaml')
CUSTOM_SYNC_FILE = os.path.join(BASE_DIR, 'custom_sync.yaml')

# HTTP 请求超时时间
REQUEST_TIMEOUT = 30

# User-Agent
HEADERS = {
    'User-Agent': (
        'docker/19.03.12 '
        'go/go1.13.10 '
        'git-commit/48a66213fe '
        'kernel/5.8.0-1.el7.elrepo.x86_64 '
        'os/linux '
        'arch/amd64 '
        'UpstreamClient(Docker-Client/19.03.12 (linux))'
    )
}


def is_exclude_tag(tag):
    """
    排除不需要同步的 tag

    :param tag:
    :return:
    """
    if not tag:
        return True

    excludes = [
        'alpha',
        'beta',
        'rc',
        'dev',
        'test',
        'amd64',
        'ppc64le',
        'arm64',
        'arm',
        's390x',
        'SNAPSHOT',
        'debug',
        'main'
    ]

    for e in excludes:
        if e.lower() in tag.lower():
            return True

    # 长度过长的 tag 通常为 commit hash 或临时 tag
    if len(tag) >= 40:
        return True

    # 处理带有 - 字符的 tag
    if re.search(r"-\d$", tag, re.M | re.I):
        return False

    if re.search(r"-\w{9}", tag, re.M | re.I):
        return True

    if '-' in tag:
        return True

    return False


def sort_docker_tags(tags_data):
    """
    对 Docker 镜像 tag 进行安全排序。

    原代码使用：

        sorted(tags_data, key=LooseVersion, reverse=True)

    Docker tag 中经常同时存在：

        0.27.4
        v0.27.3
        latest
        master
        stable

    LooseVersion 在比较不同类型的版本字段时可能出现：

        TypeError:
        '<' not supported between instances of 'int' and 'str'

    因此这里将：
      1. 可以识别的版本号按照 Version 排序
      2. 无法识别的普通 tag 放到后面
      3. 普通 tag 自身按照字符串倒序排列

    :param tags_data: tag 字符串列表
    :return: 排序后的 tag 列表
    """

    version_tags = []
    other_tags = []

    for tag in tags_data:
        if not tag:
            continue

        try:
            version = Version(tag)
            version_tags.append((tag, version))
        except (InvalidVersion, TypeError, ValueError):
            other_tags.append(tag)

    # 版本号从新到旧
    version_tags.sort(
        key=lambda item: item[1],
        reverse=True
    )

    # 非版本 tag 字符串排序
    other_tags.sort(reverse=True)

    return [
        tag
        for tag, _ in version_tags
    ] + other_tags


def get_repo_aliyun_tags(image):
    """
    获取 aliyuncs repo 最新的 tag

    :param image:
    :return:
    """

    image_name = image.split('/')[-1]

    tags = []

    headers = HEADERS.copy()

    token_url = (
        "https://dockerauth.cn-hangzhou.aliyuncs.com/auth"
        "?scope=repository:chenby/{image}:pull"
        "&service=registry.aliyuncs.com:cn-hangzhou:26842"
    ).format(
        image=image_name
    )

    try:
        token_res = requests.get(
            url=token_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        token_res.raise_for_status()

        token_data = token_res.json()
        access_token = token_data['token']

    except Exception as e:
        print('[Get repo token]', e)
        return tags

    tag_url = (
        "https://registry.cn-hangzhou.aliyuncs.com"
        "/v2/chenby/{image}/tags/list"
    ).format(
        image=image_name
    )

    headers['Authorization'] = 'Bearer ' + access_token

    try:
        tag_res = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_res.raise_for_status()

        tag_data = tag_res.json()

        print('[aliyun tag]: ', tag_data)

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    tags = tag_data.get('tags', [])

    if tags is None:
        tags = []

    return tags


def get_repo_gcr_tags(image, limit=5, host="k8s.gcr.io"):
    """
    获取 gcr.io repo 最新的 tag

    :param host:
    :param image:
    :param limit:
    :return:
    """

    headers = HEADERS.copy()

    tag_url = (
        "https://{host}/v2/{image}/tags/list"
    ).format(
        host=host,
        image=image
    )

    tags = []
    tags_data = []
    manifest_data = []

    try:
        tag_rep = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_rep.raise_for_status()

        tag_req_json = tag_rep.json()

        manifest_data = tag_req_json.get('manifest', {})

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    for manifest in manifest_data:
        sha256_data = manifest_data[manifest]

        sha256_tag = sha256_data.get('tag', [])

        if len(sha256_tag) > 0:

            tag = sha256_tag[0]

            # 排除 tag
            if is_exclude_tag(tag):
                continue

            tags_data.append({
                'tag': tag,
                'timeUploadedMs': sha256_data.get(
                    'timeUploadedMs'
                )
            })

    # 按上传时间排序
    tags_sort_data = sorted(
        tags_data,
        key=lambda i: i.get('timeUploadedMs') or 0,
        reverse=True
    )

    # limit tag
    tags_limit_data = tags_sort_data[:limit]

    image_aliyun_tags = get_repo_aliyun_tags(image)

    for t in tags_limit_data:

        # 去除已经同步过的 tag
        if t['tag'] in image_aliyun_tags:
            continue

        tags.append(t['tag'])

    print('[repo tag]', tags)

    return tags


def get_repo_quay_tags(image, limit=5):
    """
    获取 quay.io repo 最新的 tag

    :param image:
    :param limit:
    :return:
    """

    headers = HEADERS.copy()

    tag_url = (
        "https://quay.io/api/v1/repository/{image}/tag/"
        "?onlyActiveTags=true&limit=100"
    ).format(
        image=image
    )

    tags = []
    tags_data = []
    manifest_data = []

    try:
        tag_rep = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_rep.raise_for_status()

        tag_req_json = tag_rep.json()

        manifest_data = tag_req_json.get('tags', [])

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    for manifest in manifest_data:

        name = manifest.get('name', '')

        # 排除 tag
        if is_exclude_tag(name):
            continue

        tags_data.append({
            'tag': name,
            'start_ts': manifest.get('start_ts')
        })

    tags_sort_data = sorted(
        tags_data,
        key=lambda i: i.get('start_ts') or 0,
        reverse=True
    )

    # limit tag
    tags_limit_data = tags_sort_data[:limit]

    image_aliyun_tags = get_repo_aliyun_tags(image)

    for t in tags_limit_data:

        # 去除已经同步过的 tag
        if t['tag'] in image_aliyun_tags:
            continue

        tags.append(t['tag'])

    print('[repo tag]', tags)

    return tags


def get_repo_elastic_tags(image, limit=5):
    """
    获取 elastic.io repo 最新的 tag

    :param image:
    :param limit:
    :return:
    """

    token_url = (
        "https://docker-auth.elastic.co/auth"
        "?service=token-service"
        "&scope=repository:{image}:pull"
    ).format(
        image=image
    )

    tag_url = (
        "https://docker.elastic.co/v2/{image}/tags/list"
    ).format(
        image=image
    )

    tags = []
    tags_data = []
    manifest_data = []

    headers = HEADERS.copy()

    try:
        token_res = requests.get(
            url=token_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        token_res.raise_for_status()

        token_data = token_res.json()

        access_token = token_data['token']

    except Exception as e:
        print('[Get repo token]', e)
        return tags

    headers['Authorization'] = 'Bearer ' + access_token

    try:
        tag_rep = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_rep.raise_for_status()

        tag_req_json = tag_rep.json()

        manifest_data = tag_req_json.get('tags', [])

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    for tag in manifest_data:

        # 排除 tag
        if is_exclude_tag(tag):
            continue

        tags_data.append(tag)

    # 使用安全的 Docker tag 排序
    tags_sort_data = sort_docker_tags(tags_data)

    # limit tag
    tags_limit_data = tags_sort_data[:limit]

    image_aliyun_tags = get_repo_aliyun_tags(image)

    for t in tags_limit_data:

        # 去除已经同步过的 tag
        if t in image_aliyun_tags:
            continue

        tags.append(t)

    print('[repo tag]', tags)

    return tags


def get_repo_ghcr_tags(image, limit=5):
    """
    获取 ghcr.io repo 最新的 tag

    :param image:
    :param limit:
    :return:
    """

    token_url = (
        "https://ghcr.io/token"
        "?service=ghcr.io"
        "&scope=repository:{image}:pull"
    ).format(
        image=image
    )

    tag_url = (
        "https://ghcr.io/v2/{image}/tags/list"
    ).format(
        image=image
    )

    tags = []
    tags_data = []

    headers = HEADERS.copy()

    try:
        token_res = requests.get(
            url=token_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        token_res.raise_for_status()

        token_data = token_res.json()

        print(
            "token_data",
            token_url,
            token_data
        )

        access_token = token_data['token']

    except Exception as e:
        print('[Get repo token]', e)
        return tags

    headers['Authorization'] = 'Bearer ' + access_token

    try:
        tag_rep = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_rep.raise_for_status()

        tag_req_json = tag_rep.json()

        manifest_data = tag_req_json.get('tags', [])

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    for tag in manifest_data:

        # 排除 tag
        if is_exclude_tag(tag):
            continue

        tags_data.append(tag)

    # 使用安全的 Docker tag 排序
    tags_sort_data = sort_docker_tags(tags_data)

    # limit tag
    tags_limit_data = tags_sort_data[:limit]

    image_aliyun_tags = get_repo_aliyun_tags(image)

    for t in tags_limit_data:

        # 去除已经同步过的 tag
        if t in image_aliyun_tags:
            continue

        tags.append(t)

    print('[repo tag]', tags)

    return tags


def get_docker_io_tags(image, limit=5):
    """
    获取 Docker Hub repo 最新的 tag

    :param image:
        例如：
            flannel/flannel
            calico/node

    :param limit:
        获取多少个 tag

    :return:
        tag list
    """

    headers = HEADERS.copy()

    namespace_image = image.split('/')

    if len(namespace_image) != 2:
        print(
            '[Docker Hub Error] invalid image:',
            image
        )
        return []

    username = namespace_image[0]
    image_name = namespace_image[1]

    tag_url = (
        "https://hub.docker.com/v2/namespaces/"
        "{username}/repositories/{image}/tags"
        "?page=1&page_size=1000"
    ).format(
        username=username,
        image=image_name
    )

    print(tag_url)

    tags = []
    tags_data = []
    manifest_data = []

    try:
        tag_rep = requests.get(
            url=tag_url,
            headers=headers,
            timeout=REQUEST_TIMEOUT
        )

        tag_rep.raise_for_status()

        tag_req_json = tag_rep.json()

        manifest_data = tag_req_json.get('results', [])

    except Exception as e:
        print('[Get tag Error]', e)
        return tags

    for tag in manifest_data:

        name = tag.get('name', '')

        # 排除 tag
        if is_exclude_tag(name):
            continue

        if not name:
            continue

        tags_data.append(name)

    # Docker Hub tag 可能包含：
    #
    #   v0.27.4
    #   v0.27.3
    #   latest
    #   master
    #
    # 不能再使用 LooseVersion
    tags_sort_data = sort_docker_tags(tags_data)

    # limit tag
    tags_limit_data = tags_sort_data[:limit]

    # 获取阿里云已经存在的 tag
    #
    # 原代码虽然获取了这个数据：
    #
    # image_aliyun_tags = get_repo_aliyun_tags(namespace_image[1])
    #
    # 但是后面实际上没有判断。
    #
    # 这里补上。
    image_aliyun_tags = get_repo_aliyun_tags(image_name)

    for t in tags_limit_data:

        # 去除空 tag
        if t == '':
            continue

        # 去除已经同步到阿里云的 tag
        if t in image_aliyun_tags:
            continue

        tags.append(t)

    print('[repo tag]', tags)

    return tags


def get_repo_tags(repo, image, limit=5):
    """
    获取 repo 最新的 tag

    :param repo:
    :param image:
    :param limit:
    :return:
    """

    tags_data = []

    if repo == 'gcr.io':

        tags_data = get_repo_gcr_tags(
            image,
            limit,
            "gcr.io"
        )

    elif repo == 'k8s.gcr.io':

        tags_data = get_repo_gcr_tags(
            image,
            limit,
            "k8s.gcr.io"
        )

    elif repo == 'registry.k8s.io':

        tags_data = get_repo_gcr_tags(
            image,
            limit,
            "registry.k8s.io"
        )

    elif repo == 'quay.io':

        tags_data = get_repo_quay_tags(
            image,
            limit
        )

    elif repo == 'docker.elastic.co':

        tags_data = get_repo_elastic_tags(
            image,
            limit
        )

    elif repo == 'ghcr.io':

        tags_data = get_repo_ghcr_tags(
            image,
            limit
        )

    elif repo == 'docker.io':

        tags_data = get_docker_io_tags(
            image,
            limit
        )

    return tags_data


def generate_dynamic_conf():
    """
    生成动态同步配置

    :return:
    """

    print('[generate_dynamic_conf] start.')

    config = None

    with open(CONFIG_FILE, 'r') as stream:

        try:

            config = yaml.safe_load(stream)

        except yaml.YAMLError as e:

            print('[Get Config]', e)

            exit(1)

    print('[config]', config)

    skopeo_sync_data = {}

    for repo in config['images']:

        if repo not in skopeo_sync_data:

            skopeo_sync_data[repo] = {
                'images': {}
            }

        if config['images'][repo] is None:
            continue

        for image in config['images'][repo]:

            print(
                "[image] {image}".format(
                    image=image
                )
            )

            sync_tags = get_repo_tags(
                repo,
                image,
                config['last']
            )

            if len(sync_tags) > 0:

                skopeo_sync_data[repo]['images'][image] = sync_tags

            else:

                print(
                    '[{image}] no sync tag.'.format(
                        image=image
                    )
                )

    print(
        '[sync data]',
        skopeo_sync_data
    )

    with open(SYNC_FILE, 'w+') as f:

        yaml.safe_dump(
            skopeo_sync_data,
            f,
            default_flow_style=False
        )

    print(
        '[generate_dynamic_conf] done.',
        end='\n\n'
    )


def generate_custom_conf():
    """
    生成自定义的同步配置

    :return:
    """

    print('[generate_custom_conf] start.')

    custom_sync_config = None

    with open(CUSTOM_SYNC_FILE, 'r') as stream:

        try:

            custom_sync_config = yaml.safe_load(stream)

        except yaml.YAMLError as e:

            print('[Get Config]', e)

            exit(1)

    print(
        '[custom_sync config]',
        custom_sync_config
    )

    custom_skopeo_sync_data = {}

    for repo in custom_sync_config:

        if repo not in custom_skopeo_sync_data:

            custom_skopeo_sync_data[repo] = {
                'images': {}
            }

        if custom_sync_config[repo]['images'] is None:
            continue

        for image in custom_sync_config[repo]['images']:

            image_aliyun_tags = get_repo_aliyun_tags(
                image
            )

            for tag in custom_sync_config[repo]['images'][image]:

                if tag in image_aliyun_tags:
                    continue

                if image not in custom_skopeo_sync_data[repo]['images']:

                    custom_skopeo_sync_data[repo]['images'][image] = [
                        tag
                    ]

                else:

                    custom_skopeo_sync_data[repo]['images'][image].append(
                        tag
                    )

    print(
        '[custom_sync data]',
        custom_skopeo_sync_data
    )

    with open(CUSTOM_SYNC_FILE, 'w+') as f:

        yaml.safe_dump(
            custom_skopeo_sync_data,
            f,
            default_flow_style=False
        )

    print(
        '[generate_custom_conf] done.',
        end='\n\n'
    )


if __name__ == '__main__':

    generate_dynamic_conf()

    generate_custom_conf()
