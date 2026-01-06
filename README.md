# ⚡ DragonCore Xray Manager | V7.3

![Version](https://img.shields.io/badge/Version-7.3-blue?style=for-the-badge&labelColor=black)
![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Bot-Python3-yellow?style=for-the-badge&logo=python&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-purple?style=for-the-badge)
![Security](https://img.shields.io/badge/Security-UUID_Scramble-red?style=for-the-badge)

> **A evolução do gerenciamento Xray.** Uma solução híbrida (Bash + Python) robusta, offline-ready e focada em segurança para provedores de VPN profissional.

---

## 🚀 O Que Há de Novo na V7.3?

O **DragonCore Xray Manager** foi reescrito para eliminar dependências externas críticas. Diferente de scripts comuns, ele possui um ecossistema integrado:

### 🛡️ Segurança e Estabilidade
* **Offline-Ready:** As funções de bloquear/desbloquear agora vivem dentro do script. O painel não quebra se o GitHub/Gitea cair.
* **Bloqueio "Scramble":** O sistema **não deleta** o usuário ao bloquear. Ele altera o UUID para um falso e renomeia para `LOCKED_`, mantendo o histórico e backup seguros.
* **Validação Rigorosa:** Impede criação de usuários com nomes quebrados (Regra: 5-9 caracteres, apenas letras/números).

### 🤖 Automação e Bot Telegram
* **Bot Python Nativo:** Painel de controle completo via Telegram.
* **Relatórios em TXT:** Gera listas de usuários em arquivo `.txt` limpo para evitar poluição visual no chat.
* **Anti-Freeze:** Sistema de conversação inteligente que não trava se o usuário clicar em botões errados.

### ⚡ Funcionalidades do Core
* **Protocolos Modernos:** Suporte nativo a VLESS, XTLS-Vision, gRPC, WebSocket e TCP.
* **Limitador de Consumo:** Monitoramento em tempo real com bloqueio automático ao exceder a franquia (GB).
* **Backup Inteligente:** Sistema que verifica a integridade do arquivo antes de substituir o backup anterior.
* **Auto-Instalação:** Configura tudo (Xray, Certificados, Python, Cron) com um único comando.

---

## 🛠️ Instalação Rápida

Compatível com **Ubuntu 20.04+** (Recomendado) e Debian 11+.
Execute **um** dos comandos abaixo no terminal da sua VPS (como root):

### Opção 1 (Recomendada - via wget)

````
apt update -y && apt install -y wget && wget -O installxray.sh https://gitea.com/KAKAROTO/Xray2026/raw/branch/main/installxray.sh && chmod +x installxray.sh && ./installxray.sh
````

### Opção 2 ( via bash)

````
bash <(curl -s https://gitea.com/KAKAROTO/Xray2026/raw/branch/main/installxray.sh)
````