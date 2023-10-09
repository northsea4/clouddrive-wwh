[![GitHub stars](https://img.shields.io/github/stars/northsea4/clouddrive-wwh.svg?style=flat&label=Stars&maxAge=3600)](https://GitHub.com/northsea4/clouddrive-wwh)


# clouddrive-wwh
CloudDrive, WHAT, WHY and HOW.


## 安装
### Docker
#### 脚本部署
> 选择一种方式执行即可。支持选择稳定版或测试版，默认为稳定版。

curl:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/northsea4/clouddrive-wwh/main/docker/install.sh)"
```
wget:
```bash
bash -c "$(wget https://raw.githubusercontent.com/northsea4/clouddrive-wwh/main/docker/install.sh -O -)"
```

> 如果不能访问`raw.githubusercontent.com`，可以尝试下面`ghproxy`的方式。

curl:
```bash
bash -c "$(curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/northsea4/clouddrive-wwh/main/docker/install.sh)"
```
wget:
```bash
bash -c "$(wget https://ghproxy.com/https://raw.githubusercontent.com/northsea4/clouddrive-wwh/main/docker/install.sh -O -)"
```


### 更新
```bash
# `/path/to/clouddrive2`替换为实际的路径
cd /path/to/clouddrive2
docker-compose pull && docker-compose up -d
```
