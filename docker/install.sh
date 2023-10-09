#!/bin/bash

# 如果是v2版本，则不能低于2.5.0版本
check_docker_compose() {
  # 检查是否有docker-compose命令
  if ! command -v docker-compose &> /dev/null
  then
    echo "❌ 未找到docker-compose命令，请先安装docker-compose。"
    exit 1
  fi

  local dockerComposeVersion=$(docker-compose version --short)
  if [[ -z "$dockerComposeVersion" ]]; then
    echo "❌ 错误：获取docker-compose版本失败。"
    exit 1
  fi

  local dockerComposeVersionMajor=$(echo "$dockerComposeVersion" | cut -d. -f1)
  local dockerComposeVersionMinor=$(echo "$dockerComposeVersion" | cut -d. -f2)
  local dockerComposeVersionPatch=$(echo "$dockerComposeVersion" | cut -d. -f3)

  # 如果是v1版本，则不需要判断
  if [[ $dockerComposeVersionMajor -eq 1 ]]; then
    echo "✅ docker-compose版本：$dockerComposeVersion"
    return
  fi

  # 如果是v2版本，则不能低于2.5.0版本
  if [[ $dockerComposeVersionMajor -eq 2 && $dockerComposeVersionMinor -lt 5 ]]; then
    echo "❌ 错误：docker-compose为v2时，版本不能低于2.5.0版本，当前版本${dockerComposeVersion}，请先升级docker-compose。"
    exit 1
  fi

  echo "✅ docker-compose版本：$dockerComposeVersion"
}

check_docker() {
  # 检查是否有docker命令
  if ! command -v docker &> /dev/null
  then
    echo "❌ 未找到docker命令，请先安装docker。"
    exit 1
  fi

  # 检查是否有执行docker命令的权限
  if ! docker info &> /dev/null
  then
    echo "❌ 当前用户没有执行docker命令的权限，请使用sudo执行(在命令前面加上「sudo 」，注意有一个空格)。"
    exit 1
  fi

  echo "✅ docker版本：$(docker -v)"
}

# 检查docker
check_docker

# 检查docker-compose
check_docker_compose

echo ""


OS=$(uname)

TIMEZONE="Asia/Shanghai"

SUDO_CMD="sudo"
# 有些系统可能没有sudo命令
if ! command -v sudo &> /dev/null
then
  SUDO_CMD=""
fi

# 系统挂载点列表
MOUNT_POINTS=()

while read line; do
  fileSystem=$(echo $line | awk '{print $1}')
  mountPoint=$(echo $line | awk '{print $6}')
  
  # 排除一些文件系统
  if [[ $fileSystem != *"CloudFS"* ]]; then
    MOUNT_POINTS=( "${MOUNT_POINTS[@]}" "$mountPoint" )
  fi
done < <(df -h | tail -n +2)


# echo "📁 系统挂载点列表："
# for i in ${!MOUNT_POINTS[@]}; do
#   echo "  $i: ${MOUNT_POINTS[$i]}"
# done


# 获取映射关系中的宿主机路径对应的挂载点
get_mount_point() {
  local targetMountPoint="/"

  local formerPath=$1

  while true; do
    for i in ${!MOUNT_POINTS[@]}; do
      mp=${MOUNT_POINTS[$i]}
      if [[ $formerPath == "$mp" ]]; then
        targetMountPoint=$mp
        break 2
      fi
    done

    formerPath=$(dirname $formerPath)

    if [[ $formerPath == "/" ]]; then
      break
    fi
  done

  echo $targetMountPoint
}


# 设置挂载点为共享挂载
make_shared() {
  $SUDO_CMD mount --make-shared $1
}


# 设置映射关系中的宿主机路径对应的挂载点为共享挂载
make_shared_by_path() {
  local mountPoint=$(get_mount_point $1)
  if [[ -z "$mountPoint" ]]; then
    echo false
  else
    echo "✅ 指定目录对应的系统挂载点是 $mountPoint"
    make_shared $mountPoint
  fi
}


# 发生错误时的退出处理
on_error() {
  local projectDir=$1
  
  # 询问是否删除目录
  read -p "❓ 是否删除项目目录 ${projectDir}？（y/n，默认为n）：" DELETE_DIR
  DELETE_DIR=${DELETE_DIR:-n}
  echo ""
  if [ "$DELETE_DIR" = "y" ]; then
    rm -rf "$projectDir"
    echo "🗑 已删除目录：${projectDir}"
  fi

  exit 1
}


# 如果是macOS，提示不能挂载，是否继续
if [ "$OS" = 'Darwin' ]; then
  echo "❗️ 注意：macOS系统下，使用Docker部署并不支持挂载目录，只可以使用WebDAV服务，建议直接使用二进制版本。"
  read -p "❓ 是否继续进行docker部署？（y/n，默认为n）：" CONTINUE_INSTALL
  CONTINUE_INSTALL=${CONTINUE_INSTALL:-n}
  echo ""

  if [ "$CONTINUE_INSTALL" != "y" ]; then
    echo "👋 安装已取消。"
    exit 0
  fi
fi


# macOS不需要判断挂载点的情况
if [ "$OS" = 'Darwin' ]; then
  DOCKER_ROOT_DIR=""
  DOCKER_ROOT_DIR_MOUNT_POINT=""
else
  # Docker数据目录
  DOCKER_ROOT_DIR=$(docker info --format '{{.DockerRootDir}}')
  # echo "DOCKER_ROOT_DIR: ${DOCKER_ROOT_DIR}"

  # 获取Docker数据目录所在的挂载点
  DOCKER_ROOT_DIR_MOUNT_POINT=$(get_mount_point "${DOCKER_ROOT_DIR}")
  if [[ -z $DOCKER_ROOT_DIR_MOUNT_POINT ]]; then
    echo "❌ 错误：未找到Docker数据目录 ${DOCKER_ROOT_DIR} 所在的挂载点。"
    on_error "${DIR_FULL_PATH}"
  fi
fi


# 获取挂载点的共享类型
get_shared_type() {
  local mountPoint=$(get_mount_point $1)
  if [[ -z "$mountPoint" ]]; then
    echo ""
    return
  fi

  # 如果等于Docker数据目录所在的挂载点，则返回"rshared"
  # 只有当路径完全等于挂载点时，才需要"rshared/rslave"
  if [[ "$mountPoint" == "$DOCKER_ROOT_DIR_MOUNT_POINT" && "$1" == "$mountPoint" ]]; then
    echo "rshared"
  else
    echo "shared"
  fi
}


# 询问用户目录名称，默认为 "clouddrive2"
DEFAULT_DIR_NAME="clouddrive2"
echo "选择一个目录作为本docker项目的根目录(存放应用或容器的相关数据)，可以是目录路径或目录名称。"
read -p "❓ 请输入目录名称（回车使用默认名称: ${DEFAULT_DIR_NAME}）：" DIR_NAME
DIR_NAME=${DIR_NAME:-${DEFAULT_DIR_NAME}}
echo ""

# 检查目录是否已存在，如果已存在则提示用户输入其他目录名称
while [ -d "$DIR_NAME" ]; do
  echo "❌ 错误：目录已存在，请输入其他目录名称。"
  read -p "❓ 请输入目录名称（回车使用默认名称: ${DEFAULT_DIR_NAME}）：" DIR_NAME
  DIR_NAME=${DIR_NAME:-${DEFAULT_DIR_NAME}}
  echo ""
done

# 创建目录
mkdir -p "$DIR_NAME"

# 进入用户输入的目录名称
cd "$DIR_NAME"
DIR_FULL_PATH=$(pwd)
echo "📁 已创建并进入目录：$(pwd)"
echo ""


# 创建配置文件目录
mkdir -p config
echo "✅ 已创建配置目录：$(pwd)/config"
echo ""


# TODO 暂不考虑
# 环境变量：应用数据目录
# DEFAULT_CLOUDDRIVE_HOME=/Config
# read -p "🔘 请输入容器内的应用数据目录（回车使用默认目录: ${CLOUDDRIVE_HOME}）：" CLOUDDRIVE_HOME
# CLOUDDRIVE_HOME=${CLOUDDRIVE_HOME:-$DEFAULT_CLOUDDRIVE_HOME}
# echo ""
CLOUDDRIVE_HOME=/Config


# 创建挂载目录
mkdir -p data
echo "✅ 已创建挂载目录：$(pwd)/data"
echo "🔘 该目录映射到容器的路径为「/CloudNAS」，在以后进行挂载时你可以看到「/CloudNAS」这个目录。"
DEFAULT_MOUNT_DIR=$(pwd)/data
echo ""


# 设置web访问端口
DEFAULT_HTTP_PORT=19798
INTERNAL_HTTP_PORT=19798

read -p "❓ 请输入WEB访问端口（回车使用默认端口: ${DEFAULT_HTTP_PORT}）: " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}
# 检查端口格式是否正确
while ! echo "$HTTP_PORT" | grep -qE '^[0-9]+$'; do
  echo "❌ 错误：端口格式不正确，请输入数字。"
  read -p "❓ 请输入WEB访问端口（回车使用默认端口: ${DEFAULT_HTTP_PORT}）: " HTTP_PORT
  HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}
done
echo ""


# 设置使用的网络 TODO 暂时固定为bridge
DEFAULT_NETWORK=bridge
# read -p "❓ 请输入容器使用的网络（回车使用默认网络: ${NETWORK}）: " NETWORK
NETWORK=${NETWORK:-$DEFAULT_NETWORK}
# echo ""

# 需要设置共享挂载的系统挂载点
MOUNT_POINTS_SHARED=()

# 映射列表
VOLUMES="- $(pwd)/config:${CLOUDDRIVE_HOME}"

VOLUMES="${VOLUMES}\n      - ${DEFAULT_MOUNT_DIR}:/CloudNAS"
# 如果不是macOS，在映射后面加上共享挂载标志
if [ "$OS" != 'Darwin' ]; then
  sharedType=$(get_shared_type "${DEFAULT_MOUNT_DIR}")
  if [[ -z $sharedType ]]; then
    echo "❌ 错误：未找到目录 $(pwd)/data 所在的挂载点。"
    on_error "${DIR_FULL_PATH}"
  fi
  VOLUMES="${VOLUMES}:${sharedType}"

  HOST_VOLUME_PATH_MOUNT_POINT=$(get_mount_point "${DEFAULT_MOUNT_DIR}")
  if [[ -z "$HOST_VOLUME_PATH_MOUNT_POINT" ]]; then
    echo "❌ 错误：不能判断 ${DEFAULT_MOUNT_DIR} 所属的系统挂载点！"
    continue
  fi
  # 添加到 MOUNT_POINTS_SHARED
  if [[ ! " ${MOUNT_POINTS_SHARED[@]} " =~ " ${HOST_VOLUME_PATH_MOUNT_POINT} " ]]; then
    MOUNT_POINTS_SHARED+=("$HOST_VOLUME_PATH_MOUNT_POINT")
  fi
fi

VOLUME_ITEMS=()
echo "🔘 如有需要，你可以添加更多挂载目录。也可以在之后通过修改「docker-compose.yml」文件设置挂载目录。"
echo "🔘 格式为「/path/to/movies:/movies」，其中「path/to/movies」为宿主机上的目录，「/movies」为容器内的目录，使用英文冒号间隔。"
while true; do
  read -p "❓ 请输入需要映射的挂载目录，每次输入一个映射，留空则进入下一步： " VOLUME_ITEM
  if [[ -z "$VOLUME_ITEM" ]]; then
    break
  elif ! echo "$VOLUME_ITEM" | grep -qE '^[^:]+:[^:]+$'; then
    echo "❌ 错误：输入格式不正确，请按格式输入"
    continue
  fi

  # 判断宿主机目录是否存在
  HOST_VOLUME_PATH=$(echo "$VOLUME_ITEM" | cut -d: -f1)
  if [ ! -d "$HOST_VOLUME_PATH" ]; then
    echo "❌ 错误：宿主机目录 ${HOST_VOLUME_PATH} 不存在，请输入正确的目录路径。"
    continue
  fi

  if [[ "$OS" != "Darwin" ]]; then
    HOST_VOLUME_PATH_MOUNT_POINT=$(get_mount_point "$HOST_VOLUME_PATH")
    if [[ -z "$HOST_VOLUME_PATH_MOUNT_POINT" ]]; then
      echo "❌ 错误：不能判断 ${HOST_VOLUME_PATH} 所属的系统挂载点！"
      continue
    fi
    # 添加到 MOUNT_POINTS_SHARED
    if [[ ! " ${MOUNT_POINTS_SHARED[@]} " =~ " ${HOST_VOLUME_PATH_MOUNT_POINT} " ]]; then
      MOUNT_POINTS_SHARED+=("$HOST_VOLUME_PATH_MOUNT_POINT")
    fi
  fi

  # 判断映射是否重复添加
  if [[ " ${VOLUME_ITEMS[@]} " =~ " ${VOLUME_ITEM} " ]]; then
    echo "❌ 错误：已添加过映射，请输入其他映射。"
    continue
  else
    VOLUME_ITEMS+=("$VOLUME_ITEM")
  fi

  # 如果不是macOS，在映射后面加上共享挂载标志
  if [ "$OS" != 'Darwin' ]; then
    sharedType=$(get_shared_type "${HOST_VOLUME_PATH}")
    if [[ -z $sharedType ]]; then
      echo "❌ 错误：未找到目录 ${HOST_VOLUME_PATH} 所在的挂载点。"
      continue
    fi
    VOLUME_ITEM="${VOLUME_ITEM}:${sharedType}"
  fi

  VOLUMES="$VOLUMES\n      - $VOLUME_ITEM"
done

echo ""

# 选择使用的镜像
echo "请选择使用的镜像："
echo "  1. cloudnas/clouddrive - 稳定版"
echo "  2. cloudnas/clouddrive2-unstable - 测试版，可能存在BUG，但是有最新的功能"
read -p "❓ 请输入数字（回车使用默认选项1，即稳定版）：" IMAGE_INDEX
IMAGE_INDEX=${IMAGE_INDEX:-1}
if [[ $IMAGE_INDEX -eq 1 ]]; then
  IMAGE_NAME=cloudnas/clouddrive
elif [[ $IMAGE_INDEX -eq 2 ]]; then
  IMAGE_NAME=cloudnas/clouddrive2-unstable
else
  echo "❌ 错误：输入的数字不正确。"
  exit 1
fi
echo "🔘 使用镜像：$IMAGE_NAME"
echo ""


# 版本tag
DEFAULT_IMAGE_TAG=latest
read -p "❓ 请输入镜像版本（回车使用默认版本: ${DEFAULT_IMAGE_TAG}）：" IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-${DEFAULT_IMAGE_TAG}}

# 镜像名称
IMAGE_NAME=${IMAGE_NAME}:${IMAGE_TAG}
echo "✅ 镜像名称：$IMAGE_NAME"
echo ""


# 服务名称
SERVICE_NAME=clouddrive2

# 容器名称
DEFAULT_CONTAINER_NAME=clouddrive2
read -p "❓ 请输入容器名称（回车使用默认名称: ${DEFAULT_CONTAINER_NAME}）：" CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-${DEFAULT_CONTAINER_NAME}}

# 判断是否已存在同名容器
while [[ -n $(docker ps -aqf "name=${CONTAINER_NAME}") ]]; do
  echo "❌ 错误：容器已存在，请输入其他容器名称。"
  read -p "❓ 请输入容器名称（回车使用默认名称: ${DEFAULT_CONTAINER_NAME}）：" CONTAINER_NAME
  CONTAINER_NAME=${CONTAINER_NAME:-${DEFAULT_CONTAINER_NAME}}
done

echo "✅ 容器名称：$CONTAINER_NAME"
echo ""
echo ""



# 展示信息，并询问确认信息是否正确
echo ""
echo "📝 以下是准备部署的容器的详细信息："
echo ""

# 镜像名称
echo "🔘 镜像名称：$IMAGE_NAME"

# 容器名称
echo "🔘 容器名称：$CONTAINER_NAME"

# web访问端口
echo "🔘 访问端口：$HTTP_PORT"

# 映射目录列表
echo "🔘 映射目录："
echo -e "      ${VOLUMES[*]}\n"
echo ""

# read -p "❓ 确认信息是否填写正确（yes/y确认，no/n退出）：" CONFIRMED
# 如果用户输入的不是yes或y，则退出
while [[ ! "$CONFIRMED" =~ ^[yY](es)?$ ]] && [[ ! "$CONFIRMED" =~ ^[nN](o)?$ ]]; do
  read -p "❓ 是否确认？请输入 yes/y 或 no/n : " CONFIRMED
done
echo ""

if [[ "$CONFIRMED" =~ ^[nN](o)?$ ]]; then
  echo ""
  echo "⭕️ 操作已取消。"
  # 删除创建的目录
  rm -rf "${DIR_FULL_PATH}"
  echo "🗑️ 已删除创建的目录「${DIR_FULL_PATH}」"
  echo "👋 欢迎下次使用！"
  exit 0
fi


# 如果不是macOS，设置共享挂载
if [[ "$OS" != "Darwin" ]]; then
  echo "⏳ 设置共享挂载..."
  MOUNT_COMMANDS=()
  for MOUNT_POINT in "${MOUNT_POINTS_SHARED[@]}"; do
    echo "🔘 设置共享挂载：$MOUNT_POINT"
    make_shared "$MOUNT_POINT"
    if [[ $? -ne 0 ]]; then
      echo "❌ 错误：设置挂载点 ${MOUNT_POINT} 共享挂载失败！"
      on_error "${DIR_FULL_PATH}"
    fi

    MOUNT_COMMANDS+=("$SUDO_CMD mount --make-shared $MOUNT_POINT")
  done
  echo "✅ 已设置共享挂载"
  echo ""

  echo "🔘 请注意！你需要将以下命令添加到系统启动项，以确保重启系统后还能正常挂载！"

  touch "add-to-startup.sh"
  echo "#!/bin/bash" >> "add-to-startup.sh"
  echo "" >> "add-to-startup.sh"
  echo "# 请将以下命令添加到系统启动项" >> "add-to-startup.sh"
  echo "" >> "add-to-startup.sh"
  for MOUNT_COMMAND in "${MOUNT_COMMANDS[@]}"; do
    echo "$MOUNT_COMMAND" >> "add-to-startup.sh"
    echo "$MOUNT_COMMAND"
  done
  
  echo ""
  echo "✅ 相关的命令已写入到 add-to-startup.sh 文件，方便以后查阅。"
  echo ""
fi


# 创建docker-compose.yml文件
echo "⏳ 创建docker-compose.yml文件..."
touch docker-compose.yml
echo "✅ 已创建docker-compose.yml文件"
# 写入docker-compose.yml文件
echo "⏳ 写入docker-compose.yml文件..."
echo "version: '3'" >> docker-compose.yml
echo "services:" >> docker-compose.yml
echo "  $SERVICE_NAME:" >> docker-compose.yml
echo "    image: $IMAGE_NAME" >> docker-compose.yml
echo "    container_name: $CONTAINER_NAME" >> docker-compose.yml

# environment
echo "    environment:" >> docker-compose.yml
echo "      - TZ=${TIMEZONE}" >> docker-compose.yml
echo "      - CLOUDDRIVE_HOME=${CLOUDDRIVE_HOME}" >> docker-compose.yml

# devices
echo "    devices:" >> docker-compose.yml
echo "      - /dev/fuse:/dev/fuse" >> docker-compose.yml

# privileged
echo "    privileged: true" >> docker-compose.yml

# pid
echo "    pid: host" >> docker-compose.yml

# volumes
echo "    volumes:" >> docker-compose.yml
echo -e "      $VOLUMES" >> docker-compose.yml

# network_mode
echo "    network_mode: ${NETWORK}" >> docker-compose.yml

# ports
echo "    ports:" >> docker-compose.yml
echo "      - ${HTTP_PORT}:${INTERNAL_HTTP_PORT}" >> docker-compose.yml

# restart
echo "    restart: unless-stopped" >> docker-compose.yml

echo "✅ 已写入docker-compose.yml文件"
echo ""



# 拉取镜像
echo ""
echo "⏳ 拉取镜像 ${IMAGE_NAME}..."
docker-compose pull
if [ $? -eq 0 ]; then
  echo "✅ 拉取镜像完成"
else
  echo "❌ 拉取镜像失败，请检查错误日志。如果是网络问题，在解决后你可以使用以下命令重新拉取和运行: "
  echo "cd ${DIR_FULL_PATH}"
  echo "docker-compose pull"
  echo "docker-compose up -d"

  on_error "${DIR_FULL_PATH}"
fi


# 更新脚本
update_tips() {
  echo ""

  touch update.sh

  echo "#!/bin/bash" >> update.sh
  echo "" >> update.sh
  echo "cd ${DIR_FULL_PATH}" >> update.sh
  echo "docker-compose pull" >> update.sh
  echo "docker-compose up -d" >> update.sh

  echo "✅ 更新脚本已写入到 update.sh 文件。"
  echo "🔘 你可以通过以下命令更新容器："
  echo "cd ${DIR_FULL_PATH} && bash update.sh"
  echo "或者:"
  echo "bash ${DIR_FULL_PATH}/update.sh"
  echo ""
}


echo ""
read -p "❓ 是否运行容器？[y/n] " RUN_CONTAINER
if [[ "$RUN_CONTAINER" =~ ^[Yy](es)?$ ]]; then
  docker-compose up -d
  if [ $? -eq 0 ]; then
    echo "✅ 容器已经成功运行！"
    echo ""
    echo "🔘 可以通过以下命令查看容器运行状态:"
    echo "🔘 docker ps -a | grep $CONTAINER_NAME"
    echo ""
    echo "打开浏览器，访问 http://192.168.1.100:${HTTP_PORT} 进入管理界面，「192.168.1.100」替换为你的服务器IP地址。"
  else
    echo "❌ 容器启动失败，请检查错误日志"

    on_error "${DIR_FULL_PATH}"
  fi
else
  # 创建容器
  docker-compose create

  echo "🔘 你可以之后通过以下命令启动容器:"
  echo "cd ${DIR_FULL_PATH} && docker-compose up -d"
fi


update_tips


echo ""
echo "👋 Enjoy！"