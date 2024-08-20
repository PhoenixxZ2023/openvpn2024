#!/bin/bash

# Verifica se o shell é o Bash
if [ -z "$BASH_VERSION" ]; then
  echo "Este script deve ser executado usando o Bash, e não o Dash."
  exit 1
fi

# Verifica se o script está sendo executado como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, execute como root."
  exit 1
fi

# Nome do arquivo EasyRSA
EASYRSA_VERSION="3.2.0"
EASYRSA_FILE="EasyRSA-${EASYRSA_VERSION}.tgz"
EASYRSA_DIR="EasyRSA-${EASYRSA_VERSION}"
EASYRSA_URL="https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/${EASYRSA_FILE}"

# Função para verificar a distribuição e versão do SO
check_os_version() {
  if [ -x "$(command -v lsb_release)" ]; then
    DISTRO=$(lsb_release -is)
    VERSION=$(lsb_release -rs)
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
  else
    echo "Não foi possível determinar a distribuição e versão do sistema operacional."
    exit 1
  fi

  if [[ "$DISTRO" == "Ubuntu" && "$VERSION" < "20.04" ]]; then
    echo "Este script só suporta Ubuntu 20.04 ou superior."
    exit 1
  elif [[ "$DISTRO" == "Debian" && "$VERSION" < "10" ]]; then
    echo "Este script só suporta Debian 10 ou superior."
    exit 1
  elif [[ "$DISTRO" != "Ubuntu" && "$DISTRO" != "Debian" ]]; then
    echo "Este script só suporta Ubuntu 20.04 ou superior e Debian 10 ou superior."
    exit 1
  fi

  echo "Sistema operacional compatível detectado: $DISTRO $VERSION"
}

# Função para verificar a disponibilidade do dispositivo TUN/TAP
check_tun_tap() {
  if [ ! -c /dev/net/tun ]; then
    echo "O dispositivo TUN/TAP não está disponível. Instalando..."
    apt-get install -y --no-install-recommends linux-headers-$(uname -r) openvpn || {
      echo "Erro ao instalar o OpenVPN ou os headers do kernel."
      exit 1
    }
  fi
  echo "Dispositivo TUN/TAP disponível."
}

# Função para escolher a porta
choose_port() {
  echo "A porta padrão recomendada é 1194."
  read -p "Deseja manter a porta 1194 (S/n)? " port_choice

  case $port_choice in
    [Nn]* )
      read -p "Digite a porta que deseja utilizar: " CUSTOM_PORT
      PORT=$CUSTOM_PORT
      ;;
    * )
      PORT=1194
      ;;
  esac
}

# Função para escolher o protocolo
choose_protocol() {
  echo "Escolha o protocolo para o OpenVPN:"
  echo "1) TCP (Recomendado)"
  echo "2) UDP"
  read -p "Escolha [1-2]: " protocol_choice

  case $protocol_choice in
    1) PROTOCOL="tcp" ;;
    2) PROTOCOL="udp" ;;
    *) echo "Opção inválida, usando TCP." ; PROTOCOL="tcp" ;;
  esac
}

# Função para escolher o DNS
choose_dns() {
  echo "Escolha o DNS a ser utilizado pelo OpenVPN:"
  echo "1) Google (8.8.8.8, 8.8.4.4)"
  echo "2) Cloudflare (1.1.1.1, 1.0.0.1)"
  echo "3) OpenDNS (208.67.222.222, 208.67.220.220)"
  read -p "Escolha [1-3]: " dns_choice

  case $dns_choice in
    1) DNS="8.8.8.8 8.8.4.4" ;;
    2) DNS="1.1.1.1 1.0.0.1" ;;
    3) DNS="208.67.222.222 208.67.220.220" ;;
    *) echo "Opção inválida, usando Google DNS." ; DNS="8.8.8.8 8.8.4.4" ;;
  esac
}

# Função para adicionar um cliente
add_client() {
  cd /etc/openvpn/${EASYRSA_DIR} || exit
  read -p "Digite o nome do cliente: " CLIENT_NAME
  ./easyrsa gen-req "${CLIENT_NAME}" nopass
  ./easyrsa sign-req client "${CLIENT_NAME}"
  mkdir -p /etc/openvpn/clients
  cp "pki/issued/${CLIENT_NAME}.crt" "pki/private/${CLIENT_NAME}.key" "pki/ca.crt" /etc/openvpn/clients/
  cat <<EOF > /etc/openvpn/clients/${CLIENT_NAME}.ovpn
client
dev tun
proto ${PROTOCOL}
remote YOUR_SERVER_IP ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3
<ca>
$(cat /etc/openvpn/clients/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/clients/${CLIENT_NAME}.crt)
</cert>
<key>
$(cat /etc/openvpn/clients/${CLIENT_NAME}.key)
</key>
EOF
  echo "Cliente ${CLIENT_NAME} adicionado com sucesso!"
}

# Função para remover um cliente
remove_client() {
  cd /etc/openvpn/${EASYRSA_DIR} || exit
  read -p "Digite o nome do cliente a ser removido: " CLIENT_NAME
  ./easyrsa revoke "${CLIENT_NAME}"
  ./easyrsa gen-crl
  rm -f /etc/openvpn/clients/${CLIENT_NAME}.crt /etc/openvpn/clients/${CLIENT_NAME}.key /etc/openvpn/clients/${CLIENT_NAME}.ovpn
  echo "Cliente ${CLIENT_NAME} removido com sucesso!"
}

# Função para desinstalar o OpenVPN
uninstall_openvpn() {
  read -p "Você tem certeza que deseja desinstalar o OpenVPN? (s/n): " confirm
  if [[ "$confirm" =~ ^[Ss]$ ]]; then
    systemctl stop openvpn@server
    systemctl disable openvpn@server
    apt-get remove --purge -y openvpn
    rm -rf /etc/openvpn
    echo "OpenVPN desinstalado com sucesso!"
  else
    echo "Desinstalação cancelada."
  fi
}

# Função para alterar a porta do OpenVPN
change_port() {
  choose_port
  sed -i "s/^port .*/port ${PORT}/" /etc/openvpn/server.conf
  systemctl restart openvpn@server
  echo "Porta do OpenVPN alterada para ${PORT} e serviço reiniciado."
}

# Função para alterar o DNS do OpenVPN
change_dns() {
  choose_dns
  sed -i "s/^push \"dhcp-option DNS .*/push \"dhcp-option DNS ${DNS}\"/" /etc/openvpn/server.conf
  systemctl restart openvpn@server
  echo "DNS do OpenVPN alterado para ${DNS} e serviço reiniciado."
}

# Função para mostrar o menu
show_menu() {
  clear
  echo "Escolha uma opção:"
  echo "1) Instalar e configurar OpenVPN"
  echo "2) Adicionar cliente"
  echo "3) Remover cliente"
  echo "4) Alterar porta do OpenVPN"
  echo "5) Alterar DNS do OpenVPN"
  echo "6) Desinstalar OpenVPN"
  echo "7) Sair"
  read -p "Opção [1-7]: " menu_choice

  case $menu_choice in
    1)
      install_openvpn
      ;;
    2)
      add_client
      ;;
    3)
      remove_client
      ;;
    4)
      change_port
      ;;
    5)
      change_dns
      ;;
    6)
      uninstall_openvpn
      ;;
    7)
      exit 0
      ;;
    *)
      echo "Opção inválida!"
      show_menu
      ;;
  esac
}

# Função para instalar e configurar o OpenVPN
install_openvpn() {
  # Verificação do sistema operacional
  check_os_version

  # Verificação do dispositivo TUN/TAP
  check_tun_tap

  # Escolher porta, protocolo e DNS
  choose_port
  choose_protocol
  choose_dns

  # Instalação de dependências e OpenVPN
  echo "Instalando dependências e a última versão do OpenVPN..."
  apt-get update
  apt-get install -y wget tar openssl openvpn

  # Baixar e extrair o EasyRSA
  echo "Baixando EasyRSA versão ${EASYRSA_VERSION}..."
  if wget -qO "${EASYRSA_FILE}" "${EASYRSA_URL}"; then
    echo "EasyRSA baixado com sucesso."
  else
    echo "Erro ao baixar EasyRSA. Verifique sua conexão e tente novamente."
    exit 1
  fi

  echo "Extraindo EasyRSA..."
  if tar xzf "${EASYRSA_FILE}"; then
    echo "EasyRSA extraído com sucesso."
  else
    echo "Erro ao extrair EasyRSA."
    exit 1
  fi

  # Mover o EasyRSA para /etc/openvpn/
  mv "${EASYRSA_DIR}" /etc/openvpn/

  # Configurando o EasyRSA
  cd /etc/openvpn/${EASYRSA_DIR} || exit
  echo "Inicializando a PKI..."
  ./easyrsa init-pki

  echo "Criando uma nova CA..."
  ./easyrsa build-ca nopass

  echo "Gerando chave e certificado para o servidor OpenVPN..."
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server

  echo "Gerando Diffie-Hellman para troca de chaves..."
  ./easyrsa gen-dh

  echo "Copiando certificados e chaves para a pasta do OpenVPN..."
  cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/

  # Criar arquivo de configuração do OpenVPN
  echo "Gerando arquivo de configuração do OpenVPN para a porta ${PORT}..."
  cat <<EOF > /etc/openvpn/server.conf
port ${PORT}
proto ${PROTOCOL}
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS}"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF

  # Adicionar configurações extras
  echo "Configurando o OpenVPN..."

  cat <<EOF >> /etc/openvpn/server.conf
float
cipher AES-256-CBC
comp-lzo yes
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
management localhost 7505
verb 3
crl-verify crl.pem
client-to-client
client-cert-not-required
username-as-common-name
plugin $(find /usr -type f -name 'openvpn-plugin-auth-pam.so') login
duplicate-cn
EOF

  # Habilitar o redirecionamento de pacotes IPv4
  sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
  if ! grep -q "\<net.ipv4.ip_forward\>" /etc/sysctl.conf; then
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
  echo 1 > /proc/sys/net/ipv4/ip_forward

  # Configuração do RCLocal se necessário
  if [[ "$OS" = 'debian' && ! -e $RCLOCAL ]]; then
      echo '#!/bin/sh -e
  exit 0' > $RCLOCAL
  fi
  chmod +x $RCLOCAL

  # Configuração de regras do IPTables
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP
  sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP" $RCLOCAL

  # Configuração do FirewallD se presente
  if pgrep firewalld; then
      firewall-cmd --zone=public --add-port=$PORT/$PROTOCOL
      firewall-cmd --zone=trusted --add-source=10.8.0.0/24
      firewall-cmd --permanent --zone=public --add-port=$PORT/$PROTOCOL
      firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
  fi

  # Ajuste de regras adicionais de IPTables se necessário
  if iptables -L -n | grep -qE 'REJECT|DROP'; then
      iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
      iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
      iptables -F
      iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
      sed -i "1 a\iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT" $RCLOCAL
      sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" $RCLOCAL
      sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
  fi

  # Configuração do SELinux se necessário
  if hash sestatus 2>/dev/null; then
      if sestatus | grep "Current mode" | grep -qs "enforcing"; then
          if [[ "$PORT" != '1194' || "$PROTOCOL" = 'tcp' ]]; then
              if ! hash semanage 2>/dev/null; then
                  yum install policycoreutils-python -y
              fi
              semanage port -a -t openvpn_port_t -p $PROTOCOL $PORT
          fi
      fi
  fi

  # Reiniciar o OpenVPN
  fun_ropen() {
      [[ "$OS" = 'debian' ]] && {
          if pgrep systemd-journal; then
              systemctl restart openvpn@server.service
          else
              /etc/init.d/openvpn restart
          fi
      } || {
          if pgrep systemd-journal; then
              systemctl restart openvpn@server.service
              systemctl enable openvpn@server.service
          else
              service openvpn restart
              chkconfig openvpn on
          fi
      }
  }

  echo "Reiniciando o OpenVPN..."
  fun_ropen

  # Verificar e ajustar o IP se necessário
  IP2=$(wget -4qO- "http://whatismyip.akamai.com/")
  if [[ "$IP" != "$IP2" ]]; then
      IP="$IP2"
  fi

  # Configuração do arquivo de cliente
  [[ $(grep -wc 'open.py' /etc/autostart) != '0' ]] && pt_proxy=$(grep -w 'open.py' /etc/autostart | cut -d' ' -f6) || pt_proxy=80
  cat <<-EOF >/etc/openvpn/client-common.txt
  client
  dev tun
  proto $PROTOCOL
  sndbuf 0
  rcvbuf 0
  remote $IP $PORT
  http-proxy $IP $pt_proxy
  resolv-retry 5
  nobind
  persist-key
  persist-tun
  remote-cert-tls server
  cipher AES-256-CBC
  comp-lzo yes
  setenv opt block-outside-dns
  key-direction 1
  verb 3
  auth-user-pass
  keepalive 10 120
  float
EOF

  # Gerar client.ovpn
  newclient "SSHPLUS"

  # Verificação final
  if [[ "$(netstat -nplt | grep -wc 'openvpn')" != '0' ]]; then
      echo -e "\n\033[1;32mOPENVPN INSTALADO COM SUCESSO\033[0m"
  else
      echo -e "\n\033[1;31mERRO! A INSTALAÇÃO FALHOU\033[0m"
  fi

  # Configurações adicionais no RC.local
  sed -i '$ i\echo 1 > /proc/sys/net/ipv4/ip_forward' /etc/rc.local
  sed -i '$ i\echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6' /etc/rc.local
  sed -i '$ i\iptables -A INPUT -p tcp --dport 25 -j DROP' /etc/rc.local
  sed -i '$ i\iptables -A INPUT -p tcp --dport 110 -j DROP' /etc/rc.local
  sed -i '$ i\iptables -A OUTPUT -p tcp --dport 25 -j DROP' /etc/rc.local
  sed -i '$ i\iptables -A OUTPUT -p tcp --dport 110 -j DROP' /etc/rc.local
  sed -i '$ i\iptables -A FORWARD -p tcp --dport 25 -j DROP' /etc/rc.local
  sed -i '$ i\iptables -A FORWARD -p tcp --dport 110 -j DROP' /etc/rc.local
}

# Exibe o menu
while true; do
  show_menu
done
