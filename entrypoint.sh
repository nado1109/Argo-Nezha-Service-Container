#!/usr/bin/env bash

# 如不分离备份的 github 账户，默认与哪吒登陆的 github 账户一致
GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}

error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

# 如参数不齐全，容器退出，另外处理某些环境变量填错后的处理
[[ -z "$GH_USER" || -z "$GH_CLIENTID" || -z "$GH_CLIENTSECRET" || -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]] && error " There are variables that are not set. "
[[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")  # Json 时，没有了"的处理
[ -n "$GH_REPO" ] && grep -q '/' <<< "$GH_REPO" && GH_REPO=$(awk -F '/' '{print $NF}' <<< "$GH_REPO")  # 填了项目全路径的处理

echo -e "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8844\nnameserver 2400:3200::1\n" > /etc/resolv.conf

# 根据参数生成哪吒服务端配置文件
[ ! -d data ] && mkdir data
cat > /dashboard/data/config.yaml << EOF
debug: false
site:
  brand: Nezha Probe
  cookiename: nezha-dashboard
  theme: default
  customcode: "<script>\r\nwindow.onload = function(){\r\nvar avatar=document.querySelector(\".item img\")\r\nvar footer=document.querySelector(\"div.is-size-7\")\r\nfooter.innerHTML=\"Powered by $GH_USER\"\r\nfooter.style.visibility=\"visible\"\r\navatar.src=\"https://raw.githubusercontent.com/Orz-3/mini/master/Color/Global.png\"\r\navatar.style.visibility=\"visible\"\r\n}\r\n</script>"
  viewpassword: ""
oauth2:
  type: github
  admin: $GH_USER
  clientid: $GH_CLIENTID
  clientsecret: $GH_CLIENTSECRET
httpport: 80
grpcport: 5555
grpchost: $ARGO_DOMAIN
proxygrpcport: 443
tls: true
enableipchangenotification: false
enableplainipinnotification: false
cover: 0
ignoredipnotification: ""
ignoredipnotificationserverids: {}
EOF

# SSH path 与 GH_CLIENTSECRET 一样
echo root:"$GH_CLIENTSECRET" | chpasswd root
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
service ssh restart

# 判断 ARGO_AUTH 为 json 还是 token
# 如为 json 将生成 argo.json 和 argo.yml 文件
if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
  ARGO_RUN='cloudflared tunnel --edge-ip-version auto --config /dashboard/argo.yml run'

  echo "$ARGO_AUTH" > /dashboard/argo.json

  cat > /dashboard/argo.yml << EOF
tunnel: $(cut -d '"' -f12 <<< "$ARGO_AUTH")
credentials-file: /dashboard/argo.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:443
    path: /proto.NezhaService/*
    originRequest:
      http2Origin: true
      noTLSVerify: true
  - hostname: $ARGO_DOMAIN
    service: ssh://localhost:22
    path: /$GH_CLIENTID/*
  - hostname: $ARGO_DOMAIN
    service: http://localhost:80
  - service: http_status:404
EOF

# 如为 token 时
elif [[ "$ARGO_AUTH" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
  ARGO_RUN="cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
fi

# 生成自签署SSL证书
openssl genrsa -out /dashboard/nezha.key 2048
openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr
openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem

# 生成备份和恢复脚本
if [[ -n "$GH_BACKUP_USER" && -n "$GH_EMAIL" && -n "$GH_REPO" && -n "$GH_PAT" ]]; then
  # 生成定时备份数据库脚本，定时任务，删除 30 天前的备份
  cat > /dashboard/backup.sh << EOF
#!/usr/bin/env bash

GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_EMAIL=$GH_EMAIL
GH_REPO=$GH_REPO

error() { echo -e "\033[31m\033[01m\$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m\$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m\$*\033[0m"; }   # 黄色

IS_PRIVATE="\$(wget -qO- --header="Authorization: token \$GH_PAT" https://api.github.com/repos/\$GH_BACKUP_USER/\$GH_REPO | grep -oPm1 '(?<="private": ).*(?=,)')"
if [ "\$?" != 0 ]; then
  error "\n Could not connect to Github. Stop backup. \n"
elif [ "\$IS_PRIVATE" != true ]; then
  error "\n This is not exist nor a private repository and the script exits. \n"
fi

[ -n "\$1" ] && WAY=Scheduled || WAY=Manualed

# 停掉面板才能备份
hint "\n\$(supervisorctl stop agent nezha grpcwebproxy)\n"
sleep 2

# 克隆现有备份库
cd /tmp
git clone https://\$GH_PAT@github.com/\$GH_BACKUP_USER/\$GH_REPO.git --depth 1 --quiet

# 检查更新面板主程序 app，然后 github 备份数据库，最后重启面板
if [[ \$(supervisorctl status nezha) =~ STOPPED ]]; then
  [ -e /version ] && NOW=\$(cat /version)
  LATEST=\$(wget -qO- https://raw.githubusercontent.com/fscarmen2/Argo-Nezha-Service-Container/main/app/README.md | awk '/Repo/{print \$NF}')
  if [[ "\$LATEST" =~ ^v([0-9]{1,3}\.){2}[0-9]{1,3}\$ && "\$NOW" != "\$LATEST" ]]; then
    hint "\n Renew dashboard app to \$LATEST \n"
    wget -O /dashboard/app https://raw.githubusercontent.com/fscarmen2/Argo-Nezha-Service-Container/main/app/app-\$(arch)
    echo "\$LATEST" > /version
  fi
  TIME=\$(date "+%Y-%m-%d-%H:%M:%S")
  tar czvf \$GH_REPO/dashboard-\$TIME.tar.gz --exclude='dashboard/*.sh' --exclude='dashboard/app' --exclude='dashboard/argo.*' --exclude='dashboard/nezha.*' --exclude='dashboard/data/config.yaml' /dashboard
  cd \$GH_REPO
  [ -e ./.git/index.lock ] && rm -f ./.git/index.lock
  echo "dashboard-\$TIME.tar.gz" > README.md
  find ./ -name '*.gz' | sort | head -n -5 | xargs rm -f
  git config --global user.email \$GH_EMAIL
  git config --global user.name \$GH_BACKUP_USER
  git checkout --orphan tmp_work
  git add .
  git commit -m "\$WAY at \$TIME ."
  git push -f -u origin HEAD:main --quiet
  IS_BACKUP="\$?"
  cd ..
  rm -rf \$GH_REPO
  [ "\$IS_BACKUP" = 0 ] && echo "dashboard-\$TIME.tar.gz" > /dbfile && info "\n Succeed to upload the backup files dashboard-\$TIME.tar.gz to Github.\n" || hint "\n Failed to upload the backup files dashboard-\$TIME.tar.gz to Github.\n"
  hint "\n\$(supervisorctl start agent nezha grpcwebproxy)\n"; sleep 2
fi

[ \$(supervisorctl status all | grep -c "RUNNING") = \$(grep -c '\[program:.*\]' /etc/supervisor/conf.d/damon.conf) ] && info "\n Done! \n" || error "\n Fail! \n"
EOF

  # 生成还原数据脚本
  cat > /dashboard/restore.sh << EOF
#!/usr/bin/env bash

GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_REPO=$GH_REPO

error() { echo -e "\033[31m\033[01m\$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m\$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m\$*\033[0m"; }   # 黄色

if [ "\$1" = a ]; then
  ONLINE="\$(wget -qO- --header="Authorization: token \$GH_PAT" "https://raw.githubusercontent.com/\$GH_BACKUP_USER/\$GH_REPO/main/README.md" | sed "/^$/d" | head -n 1)"
  [ "\$ONLINE" = "\$(cat /dbfile)" ] && exit
  [[ "\$ONLINE" =~ tar\.gz$ && "\$ONLINE" != "\$(cat /dbfile)" ]] && FILE="\$ONLINE" && echo "\$FILE" > /dbfile || exit
elif [[ "\$1" =~ tar\.gz$ ]]; then
  FILE="\$1"
fi

until [[ -n "\$FILE" || "\$i" = 5 ]]; do
  [ -z "\$FILE" ] && read -rp ' Please input the backup file name (*.tar.gz): ' FILE
  ((i++)) || true
done

if [ -n "\$FILE" ]; then
  [[ "\$FILE" =~ http.*/.*tar.gz ]] && FILE=\$(awk -F '/' '{print \$NF}' <<< \$FILE)
else
  error "\n The input has failed more than 5 times and the script exits. \n"
fi

DOWNLOAD_URL=https://raw.githubusercontent.com/\$GH_BACKUP_USER/\$GH_REPO/main/\$FILE
wget --header="Authorization: token \$GH_PAT" --header='Accept: application/vnd.github.v3.raw' -O /tmp/backup.tar.gz "\$DOWNLOAD_URL"

if [ -e /tmp/backup.tar.gz ]; then
  hint "\n\$(supervisorctl stop agent nezha grpcwebproxy)\n"
  FILE_LIST=\$(tar -tzf /tmp/backup.tar.gz)
  grep -q "dashboard/app" <<< "\$FILE_LIST" && EXCLUDE[0]=--exclude='dashboard/app'
  grep -q "dashboard/.*\.sh" <<< "\$FILE_LIST" && EXCLUDE[1]=--exclude='dashboard/*.sh'
  grep -q "dashboard/argo\..*" <<< "\$FILE_LIST" && EXCLUDE[2]=--exclude='dashboard/argo.*'
  grep -q "dashboard/nezha\..*" <<< "\$FILE_LIST" && EXCLUDE[3]=--exclude='dashboard/nezha.*'
  grep -q "dashboard/data/config.yaml" <<< "\$FILE_LIST" && EXCLUDE[4]=--exclude='dashboard/data/config.yaml'
  tar xzvf /tmp/backup.tar.gz \${EXCLUDE[*]} -C /
  rm -f /tmp/backup.tar.gz
  hint "\n\$(supervisorctl start agent nezha grpcwebproxy)\n"; sleep 2
fi

[ \$(supervisorctl status all | grep -c "RUNNING") = \$(grep -c '\[program:.*\]' /etc/supervisor/conf.d/damon.conf) ] && info "\n Done! \n" || error "\n Fail! \n"
EOF

  # 生成定时任务，每天北京时间 4:00:00 备份一次，并重启 cron 服务; 每分钟自动检测在线备份文件里的内容
  grep -q '/dashboard/backup.sh' /etc/crontab || echo "0 4 * * * root bash /dashboard/backup.sh a" >> /etc/crontab
  grep -q '/dashboard/restore.sh' /etc/crontab || echo "* * * * * root bash /dashboard/restore.sh a" >> /etc/crontab
  service cron restart
fi

# 生成 supervisor 进程守护配置文件
cat > /etc/supervisor/conf.d/damon.conf << EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:grpcwebproxy]
command=grpcwebproxy --server_tls_cert_file=/dashboard/nezha.pem --server_tls_key_file=/dashboard/nezha.key --server_http_tls_port=443 --backend_addr=localhost:5555 --backend_tls_noverify --server_http_max_read_timeout=300s --server_http_max_write_timeout=300s
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:nezha]
command=/dashboard/app
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:agent]
command=nezha-agent -s localhost:5555 -p abcdefghijklmnopqr
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:argo]
command=$ARGO_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF

# 赋执行权给 sh  文件
chmod +x /dashboard/*.sh

# 运行 supervisor 进程守护
supervisord -c /etc/supervisor/supervisord.conf
