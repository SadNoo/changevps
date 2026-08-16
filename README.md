# changevps

## 说明

用于 Debian 系统定时检测 `baidu.com`。每次发送 4 次 Ping；收到响应时不执行其他操作，全部超时时请求安装时填写的 Change IP URL。

## 使用方法

```bash
git clone https://github.com/SadNoo/changevps.git
cd changevps
sudo bash install.sh
```

根据提示输入完整的 Change IP URL 和检测间隔分钟数。重新运行安装命令可修改配置。

## 查看日志

```bash
sudo tail -f /var/log/changevps.log
```

## 删除

```bash
cd changevps
sudo bash install.sh uninstall
```
