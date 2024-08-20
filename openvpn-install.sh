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
  
  # Obter o IP público da VPS
  SERVER_IP=$(curl -s ifconfig.me)
  
  # Gerar o arquivo de configuração .ovpn
  cat <<EOF > /etc/openvpn/clients/${CLIENT_NAME}.ovpn
client
dev tun
proto ${PROTOCOL}
remote ${SERVER_IP} ${PORT}
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

  # Download e instalação do EasyRSA
  cd /etc/openvpn || exit
  wget -O ${EASYRSA_FILE} ${EASYRSA_URL}
  tar xzf ${EASYRSA_FILE}
  cd ${EASYRSA_DIR} || exit

  # Configuração do EasyRSA
  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey --secret ta.key

  # Configuração do OpenVPN
  cd /etc/openvpn || exit
  cat <<EOF > /etc/openvpn/server.conf
port ${PORT}
proto ${PROTOCOL}
dev tun
ca /etc/openvpn/${EASYRSA_DIR}/pki/ca.crt
cert /etc/openvpn/${EASYRSA_DIR}/pki/issued/server.crt
key /etc/openvpn/${EASYRSA_DIR}/pki/private/server.key
dh /etc/openvpn/${EASYRSA_DIR}/pki/dh.pem
tls-auth /etc/openvpn/ta.key 0
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
log-append /var/log/openvpn.log
verb 3
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS}"
EOF

  # Ativação e início do OpenVPN
  systemctl enable openvpn@server
  systemctl start openvpn@server

  echo "OpenVPN instalado e configurado com sucesso!"
}

# Mostrar o menu
show_menu
