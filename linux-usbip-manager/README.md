# Linux USB/IP Manager

Instalador e daemon C++ para thin clients Linux que exportam dispositivos USB
para um Windows Server via USB/IP.

## O que ele configura

- Usa somente o gerenciador nativo C++ deste projeto.
- Instala ou reutiliza apenas o runtime USB/IP do Linux (`usbip`, `usbipd`).
- Carrega `usbip-core` e `usbip-host` no boot.
- Cria `usbipd.service` para expor dispositivos na porta TCP 3240.
- Cria `usbip-manager.service` para reconciliar e fazer rebind automatico.
- Exige `bin/usbip-manager-linux-<arquitetura>` no pendrive.
- Cria regra `udev` para reagir a insercao/remocao de USB.
- Ignora ModemManager/brltty para ESP32-S3 e bridges seriais comuns.
- Pode avisar um broker Windows via JSON TCP na porta 12000.

## Instalacao rapida

```bash
sudo bash ./install.sh
```

Por padrao, o instalador ja usa o Windows Server `10.0.64.28` para liberar o
firewall TCP 3240 e enviar notificacoes ao broker na porta 12000.

Se `usbip` ou `usbipd` nao estiverem instalados, o instalador tenta instalar
automaticamente o runtime USB/IP do Linux usando `apt-get`. Ele tenta, nesta
ordem: `usbip`, `linux-tools-$(uname -r)`, `linux-tools-generic`,
`linux-cloud-tools-generic` e pacotes Armbian `linux-tools-current/edge/legacy`.
Com `--skip-packages`, nenhuma instalacao via APT e feita.

Se precisar trocar o servidor:

```bash
sudo bash ./install.sh --server-ip 192.168.100.26 --notify-host 192.168.100.26 --notify-port 12000
```

Se quiser instalar sem notificar o Windows:

```bash
sudo bash ./install.sh --no-notify
```

Se o thin client estiver sem DNS/internet, mas ja tiver `usbip`, `usbipd`,
`modprobe`, `udevadm` e `systemctl`, instale sem APT:

```bash
sudo bash ./install.sh --skip-packages
```

Com o binario C++ no pendrive, `python3` nao e necessario.

Para exportar somente dispositivos na allowlist:

```bash
sudo bash ./install.sh --allowlist-only
```

Se o thin client nao usa ModemManager/brltty, e voce quer evitar conflito com
ESP32-S3 durante boot/flash:

```bash
sudo bash ./install.sh --disable-conflicting-services
```

## Gerenciador nativo C++

Para thin client com pouco espaco/memoria, leve o binario nativo no pendrive.
Este pacote ja inclui:

```text
bin/usbip-manager-linux-arm64
SHA256: BD808BBBE20E22B8E1E8A25F8F42CB7C911E7F31A3AC1B81FBAD75819F99C0D9
```

Se precisar recompilar em uma maquina Linux/Armbian da mesma arquitetura do
thin client:

```bash
cd linux-usbip-manager
sudo apt-get install -y g++
bash ./build-native.sh
```

Isso gera:

```text
bin/usbip-manager-linux-arm64
```

Copie a pasta `linux-usbip-manager` inteira para o pendrive. No thin client:

```bash
sudo bash ./install.sh --skip-packages
```

O instalador detecta automaticamente o binario C++ e cria o systemd apontando
para `/opt/usbip-manager/usbip_manager`. Se o binario nao existir, a instalacao
para com erro.

## Comandos uteis

```bash
systemctl status usbipd.service usbip-manager.service
journalctl -u usbip-manager.service -f
/opt/usbip-manager/usbip_manager --config /etc/usbip-manager/config.json scan
/opt/usbip-manager/usbip_manager --config /etc/usbip-manager/config.json status
usbip list -l
```

No Windows, o cliente deve conseguir listar e anexar:

```powershell
usbip.exe list -r <ip-do-thinclient>
usbip.exe attach -r <ip-do-thinclient> -b <busid>
```

## APT em Debian/Armbian Bullseye

Se o thin client mostrar erro como:

```text
The repository 'http://deb.debian.org/debian bullseye-backports Release' no longer has a Release file
```

o problema esta nos repositorios APT do sistema, nao no USB/IP. O instalador
tenta comentar automaticamente entradas `bullseye-backports` obsoletas, criando
backup do arquivo original com sufixo `.usbip-manager.<data>.bak`.

Correcao manual equivalente:

```bash
sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i -E '/bullseye-backports/ s/^/# disabled: /' /etc/apt/sources.list
sudo find /etc/apt/sources.list.d -name '*.list' -type f -exec sed -i -E '/bullseye-backports/ s/^/# disabled: /' {} \;
sudo apt-get update --allow-releaseinfo-change
```

Se o retorno for:

```text
Nao foi possivel resolver 'deb.debian.org'
Nao foi possivel resolver 'apt.armbian.com'
```

o thin client esta sem DNS/internet. Teste:

```bash
ip route
ping -c 3 8.8.8.8
getent hosts deb.debian.org
cat /etc/resolv.conf
```

Correcao rapida de DNS para testar:

```bash
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee /etc/resolv.conf
sudo apt-get update --allow-releaseinfo-change
sudo bash ./install.sh
```

Se preferir nao corrigir DNS agora e os comandos USB/IP ja existirem:

```bash
command -v usbip usbipd modprobe udevadm systemctl
sudo bash ./install.sh --skip-packages
```

Se aparecer `Nao ha espaco disponivel no dispositivo`, libere espaco e repare
o `dpkg`:

```bash
df -h / /var /tmp
sudo apt-get clean
sudo rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*
sudo journalctl --vacuum-size=20M 2>/dev/null || true
sudo find /var/log -type f -name "*.gz" -delete
sudo find /var/log -type f -name "*.1" -delete
sudo dpkg --configure -a
```

Depois, se os comandos USB/IP ja existirem, rode:

```bash
sudo bash ./install.sh --skip-packages
```

## Politicas

`bind_policy` em `/etc/usbip-manager/config.json`:

- `allow_all`: exporta todos os USBs, exceto hubs/root hubs e bloqueios.
- `allowlist`: exporta apenas VID/PID em `allowed_devices`.
- `disabled`: nao exporta automaticamente.

Para ESP32-S3 nativo, a entrada principal e:

```json
{"vid": "303a", "pid": "1001", "name": "Espressif ESP32-S3 USB Serial/JTAG"}
```

Para ESP-PROG, mantenha tambem:

```json
{"vid": "0403", "pid": "6010", "name": "ESP-PROG / FTDI FT2232H"}
```

## Desinstalacao

```bash
sudo bash ./install.sh --uninstall
```

Limpeza agressiva para thin client dedicado com pouco espaco:

```bash
sudo bash ./uninstall.sh --clean-system --purge-optional --purge-python --force
```

Isso remove o USB/IP Manager, limpa cache/listas/logs do APT/dpkg, remove
`hwdata`/`usbutils` e tenta purgar Python. Use `--purge-python` somente em imagem
dedicada, porque outros componentes do sistema podem depender dele.
