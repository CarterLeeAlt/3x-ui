Windows 平台注意事项：
- Windows 无法安装 fail2ban
- Windows 没有 bash 菜单
- 忘记密码时，请用 https://sqlitebrowser.org/ 查看数据库
- 程序需要保持运行

默认设置：
http://localhost:2053/
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
  x-ui-manager.bat status         显示进程状态和数据路径
  x-ui-manager.bat reset          重新安装随包版本
  x-ui-manager.bat service-install  安装为 Windows 服务并启动
  x-ui-manager.bat service-remove   停止并卸载该服务
  x-ui-manager.bat service-status   查看服务状态
不带参数运行 x-ui-manager.bat 会显示交互菜单；安装或卸载服务需以管理员身份运行。
说明：
- 首次执行 start 时会创建 runtime\db\x-ui.db；若数据库缺少 subPort 设置，会以 2196 补齐。
- stop 只处理从本目录启动的进程。Windows 无法正常关闭时会强制终止，并在输出中明确提示。
- reset 会先要求确认，然后按 version.txt 记录的版本下载对应 Windows 发布包，再把本地全部数据（账户、设置、日志、证书及本目录其他文件）移入回收站。完成后面板保持停止状态，需执行 start 重新生成数据库。已安装的服务会先被停止。
- reset 通过 curl 下载，遵循 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 环境变量；未设置时直连。下载失败时不会删除任何本地文件。
- 服务名为 3x-ui，随系统启动，不需要登录即可运行；安装时会把本目录权限授予当前用户。卸载服务不会删除数据。
- 所有路径都相对本目录解析，可整体移动或改名；移动后若已安装服务，需先卸载再重新安装。
- 运行数据位于 runtime\db、runtime\log 和 runtime\subport.current。日志超过 20 MB 时轮转为 3xui.log.1 至 3xui.log.3；服务日志为 runtime\log\service.log。
