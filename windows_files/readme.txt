Windows 平台注意事项：
- Windows 无法安装 fail2ban
- Windows 没有 bash 菜单
- 忘记密码时，请用 https://sqlitebrowser.org/ 查看数据库
- 程序需要保持运行

默认设置：
http://127.0.0.1:2053/
用户名：admin
密码：admin
端口：2053

生成自签名证书：
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout localhost.key -out localhost.crt

------------------------------------------------------------
便携版管理器（Windows）
------------------------------------------------------------
x-ui-manager.bat 是唯一入口，需在命令行或双击运行。
  x-ui-manager.bat start          启动面板及其 Xray 内核
  x-ui-manager.bat stop           停止本目录启动的面板和 Xray
  x-ui-manager.bat status         显示面板、Xray、服务及订阅状态和数据路径
  x-ui-manager.bat reset          重新安装随包版本
  x-ui-manager.bat service-install  安装为 Windows 服务并启动
  x-ui-manager.bat service-remove   停止并卸载该服务
  x-ui-manager.bat service-status   查看服务状态
不带参数运行 x-ui-manager.bat 以普通权限显示菜单；安装、卸载和启停服务，以及服务已安装时重置，才请求管理员授权。操作结果在原窗口显示，按回车返回菜单。
说明：
- 首次执行 start 时会创建 runtime\db\x-ui.db；若数据库缺少 subPort 设置，会以 2196 补齐。
- Windows 管理页面和管理 API 固定监听 127.0.0.1，设置不能改为其他地址；订阅服务和代理入站的监听配置保持独立。
- 未安装服务时 start 隐藏启动普通后台实例，关闭管理器后继续运行；已安装服务时 start 和 stop 启停本目录注册的服务。安装服务时会停止普通实例并切换到服务运行。
- stop 只处理从本目录启动的进程。Windows 无法正常关闭时会强制终止，并在输出中明确提示。
- reset 会先要求确认，然后按 version.txt 记录的固定版本下载并检查 Windows 发布包。下载成功后停止运行，把本地全部数据（账户、设置、日志、证书及本目录其他文件）移入回收站，再解压恢复程序；执行入口在复制新文件前保留。完成后保持停止，执行 start 时重新生成默认数据库。服务注册保留。
- reset 通过 curl 下载，遵循 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 环境变量；未设置时直连。下载失败时不会删除任何本地文件。
- 服务名为 3x-ui，使用 Windows 内置 LocalService 账户，随系统启动，不需要登录或输入账户密码。脚本授予程序目录读取权限，以及 runtime、bin 目录写入权限，供数据库、日志、内核配置和资源更新使用。卸载服务不会删除数据。服务操作会核对注册路径，拒绝处理其他目录的同名服务。
- 所有路径都相对本目录解析，可整体移动或改名；移动后若已安装服务，需先卸载再重新安装。
- 数据库和日志位于 runtime\db、runtime\log，内核运行配置为 bin\config.json。状态查看从数据库读取当前配置；服务日志为 runtime\log\service.log。
