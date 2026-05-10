# ⚡ TURBONET XRAY Manager | V1.1

![Version](https://img.shields.io/badge/Version-1.1-blue?style=for-the-badge&labelColor=black)
![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Bot-Python3-yellow?style=for-the-badge&logo=python&logoColor=white)
![Xray](https://img.shields.io/badge/Core-Xray-purple?style=for-the-badge)
![Security](https://img.shields.io/badge/Security-SHA256-red?style=for-the-badge)
![License](https://img.shields.io/badge/License-Free-green?style=for-the-badge)

> **Gerenciador Xray híbrido (Bash + Python)** com arquitetura modular, hot reload via API, bot Telegram, API pública de consulta, autenticação por API-Key e suporte a CheckUser para apps VPN (Conecta4G, DTunnel).
> Ideal para quem administra múltiplos usuários VLESS/Trojan e precisa de painel local + bot Telegram sem derrubar conexões ativas.

---

## 🚀 Instalação Rápida

Execute como **root** na sua VPS:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/PhoenixxZ2023/XRAY2026/main/installxray.sh)
```

Após instalar, acesse o painel a qualquer momento com:

```bash
xray-menu
```

---

## ✅ O que este projeto entrega

### 🧩 Arquitetura Modular (Cache Local)
- O `installxray.sh` instala apenas o **launcher** e dependências essenciais.
- O `menuxray.sh` baixa os módulos **sob demanda** e mantém cache em `/usr/local/bin`.
- Mesmo se o GitHub ficar fora do ar, o painel segue funcionando com os módulos já cacheados.
- Suporte a `PINNED_REF` para fixar versão por branch, tag ou commit hash.
- **Verificação SHA256** automática em cada download — módulo corrompido ou adulterado é rejeitado.

### ⚡ Hot Reload — Sem Derrubar Conexões
- Adicionar, remover, bloquear e desbloquear usuários via **API do Xray em tempo real**.
- Nenhum cliente conectado é derrubado durante operações de gerenciamento.
- Fallback automático para reload do serviço se a API não estiver disponível.
- Funciona tanto pelo terminal quanto pelo bot Telegram.

### 🌐 Protocolos Suportados (8 opções)

| Protocolo | TLS | Sem TLS | Descrição |
|-----------|-----|---------|-----------|
| XHTTP | ✅ | ✅ | Otimizado — recomendado |
| WebSocket (WS) | ✅ | ✅ | Ampla compatibilidade |
| gRPC | ✅ | ✅ | Alta performance |
| TCP | ✅ | ✅ | Simples e direto |
| VISION (XTLS) | ✅ | ❌ | Máxima performance com TLS |
| HTTPUpgrade | ✅ | ✅ | Boa compatibilidade com CDNs |
| HTTP/2 | ✅ | ❌ | Multiplexação nativa |
| Trojan | ✅ | ❌ | Disfarça como HTTPS — bypass DPI |

### 🛡️ Bloqueio Seguro (UUID Scramble)
- Bloquear **não deleta** o usuário — mantém histórico no `users.db`.
- Troca UUID por falso e aplica prefixo `LOCKED_` — fácil de reverter.
- Desbloqueio restaura o UUID original do banco de dados.

### 🔍 API `/check` com Autenticação
- Endpoint HTTP para consulta de status de usuário sem acesso SSH.
- **Autenticação por API-Key** (X-API-Key header) para proteger dados sensíveis.
- Rate limiting: 60 requisições por minuto por IP.
- Ideal para revendedores e aplicativos VPN verificarem clientes.
- Respostas em JSON com nome, UUID, expiração, status e dias restantes.

```bash
# Endpoints da API
GET /health                    → healthcheck (público)
GET /check?user=NOME           → status por nome
GET /check?uuid=UUID           → status por UUID
GET /check/status              → status geral do servidor
GET /check/connections         → conexões ativas por usuário

# Autenticação
Header: X-API-Key: <sua_api_key>
```

**Gerar API Key:**
```bash
head -c 32 /dev/urandom | xxd -p
# Guarde em /opt/XrayTools/.api_key
```

### 📱 CheckUser API — Suporte para Apps VPN 
- API dedicada para apps VPN que usam autenticação por **usuário/senha**.
- Mapeia user+password para UUID internamente.
- Retorna: nome, conexões ativas, data de expiração, dias restantes, limite de conexões.
- Perfeito para revendedores que usam apps de terceiros.

```bash
# Endpoint CheckUser
GET /checkuserxray?user=NICK&pass=SENHA

# Resposta
{
  "username": "usuario1",
  "count_connections": 1,
  "expiration_date": "01/06/2026",
  "expiration_days": 30,
  "limit_connections": 2
}
```

**Para apps VPN (apps.config):**
```json
{
  "server": "https://seu-dominio.com",
  "path": "/checkuserxray"
}
```

### 🔐 Segurança
- Verificação **SHA256** em todos os downloads — gerada automaticamente via GitHub Actions a cada push.
- **Autenticação API-Key** para endpoints sensíveis (X-API-Key header).
- **Rate limiting** por IP para prevenir ataques de força bruta.
- Validação de domínio RFC 1123 e rejeição de IPs privados/reservados.
- `config.json` com permissão `0660 root:nogroup` — Xray lê, bot escreve, outros sem acesso.
- `privkey.pem` com permissão `0640 root:nogroup` — chave privada TLS nunca legível por outros.
- `renew_cert.sh` com `0700 root:root` — não modificável por processos não-root.
- Wrappers setuid com `4750 root:botxray` — apenas o grupo `botxray` executa como root.
- Escrita atômica via `tmpfile + os.replace()` em todos os arquivos críticos.
- Lock file com detecção de idade — remove locks antigos automaticamente.
- **Sanitização de entrada** em todos os módulos — proteção contra injeção.

### 🤖 Bot Telegram (Seguro e Funcional)
- Bot roda como usuário dedicado **não-root** (`botxray`) com venv isolado.
- Token e Admin ID em `EnvironmentFile` — nunca hardcoded.
- `SupplementaryGroups=nogroup` no systemd — acesso correto ao config.json.
- `PrivateTmp=true` — /tmp isolado por segurança.
- Todas as operações via **API do Xray** — sem restart, sem derrubar clientes.
- Backup pelo bot gera SHA256 e envia junto ao admin.

### 📦 Backup Compacto com Integridade
- Inclui: `users.db`, configs do Xray e certificados SSL.
- SHA256 gerado automaticamente ao lado de cada backup.
- Snapshot antes do restore — rollback disponível se falhar.
- Rotação automática — mantém apenas os 5 backups mais recentes.

### 📊 Limitador de Consumo por GB
- Controle de tráfego individual por usuário via API do Xray.
- Lock exclusivo com `flock` — evita race condition entre cron e UI.
- Bloqueio automático ao atingir o limite — sem restart do serviço.

### 📡 Monitor Online (API-only)
- Usa a API do Xray — sem alterar loglevel, sem restart.
- Delta real de tráfego por ciclo de polling.
- Janela deslizante de atividade configurável (padrão 15s).

### 🚀 Otimização TCP (BBR)
- Ativa/desativa BBR com detecção automática de kernel compatível.
- Persiste entre reinicializações via `/etc/sysctl.d/`.

### 👥 Sistema de Usuários com Senha e Limite de Conexões
- Cada usuário pode ter **senha** além do UUID.
- **Limite de conexões simultâneas** por usuário (0 = ilimitado).
- Migração automática de usuários existentes para novo formato.

---

## 📋 Menu Principal

```
[01] CRIAR USUÁRIO
[02] REMOVER USUÁRIO
[03] LISTAR USUÁRIOS
[04] INSTALAR/CONFIGURAR XRAY
[05] LIMPAR EXPIRADOS
[06] DESINSTALAR XRAY
[07] LIMITADOR CONSUMO (GB)
[08] BOT TELEGRAM
[09] BACKUP / RESTORE
[10] BLOQUEAR USUÁRIOS
[11] DESBLOQUEAR USUÁRIOS
[12] MONITOR ONLINE
[13] ATIVAR BBR (OTIMIZAÇÃO TCP)
[14] API /CHECK (CONSULTA DE USUÁRIOS)
[15] CDN / RELAY VERCEL
[16] CHECKUSER (APPS VPN)          ← NOVO!
[99] ATUALIZAR MÓDULOS (FORÇA DOWNLOAD)
[00] SAIR
```

---

## 🤖 Bot Telegram — Funcionalidades

| Função | Descrição |
|--------|-----------|
| `/start` ou `/menu` | Abre o painel |
| 👤 CRIAR | Cria usuário — exibe Nome, UUID e data de expiração |
| 🗑️ REMOVER | Remove usuário do sistema |
| ⛔ SUSPENDER | Bloqueia sem deletar (scramble UUID) |
| ✅ REATIVAR | Restaura UUID original e reativa |
| 📋 LISTAR (TXT) | Envia arquivo `.txt` com todos os usuários |
| 📥 BACKUP | Gera backup compacto + SHA256 e envia via Telegram |
| ❌ SAIR | Fecha o painel |

---

## 🔐 Tabela de Permissões

| Arquivo / Diretório | Permissão | Dono |
|---|---|---|
| `/usr/local/etc/xray/` | `0770` | `root:nogroup` |
| `config.json` | `0660` | `root:nogroup` |
| `preset.json` | `0660` | `root:nogroup` |
| `connection_info.txt` | `0600` | `root:root` |
| `users/*.txt` | `0600` | `root:root` |
| `users.db` | `0600` | `root:root` |
| `limits.db / usage.db / session.db` | `0600` | `botxray:botxray` |
| `.api_key` | `0600` | `root:root` |
| `.bot_env` | `0640` | `root:botxray` |
| `botxray.py` | `0640` | `root:botxray` |
| `TurbonetCoreSSL/` | `0750` | `root:nogroup` |
| `fullchain.pem` | `0644` | `root:root` |
| `privkey.pem` | `0640` | `root:nogroup` |
| `renew_cert.sh` | `0700` | `root:root` |
| `wrap_*` (setuid) | `4750` | `root:botxray` |

---

## 📋 Requisitos

| Item | Requisito |
|------|-----------|
| Sistema Operacional | Ubuntu 20.04+ ou Debian 11/12 |
| Arquitetura | amd64 (x86_64) ou arm64 |
| Acesso | root |
| Python | 3.8+ (para o bot Telegram) |
| TLS (Let's Encrypt) | Porta 80 livre durante emissão/renovação |
| DNS (Let's Encrypt) | Domínio deve apontar para o IP da VPS |

---

## 📁 Estrutura do Projeto

```
XRAY2026/
├── installxray.sh              # Instalador do launcher
├── menuxray.sh                 # Menu principal
├── generate_hashes.sh          # Gerador de SHA256 local
├── migrate_users.sh            # Migração de users.db para novo formato
├── .github/
│   └── workflows/
│       └── generate-hashes.yml # GitHub Actions — SHA256 automático
└── modulosxray/
    ├── core_manager.sh         # Wizard de configuração do Xray (8 protocolos)
    ├── certxray.sh             # Emissão de certificados TLS
    ├── add_user.sh             # Criar usuário (senha + limite) - V1.1
    ├── remover_user.sh         # Remover usuário (hot reload)
    ├── lista_users.sh          # Listar usuários com status
    ├── block_user.sh           # Bloquear usuário (hot reload)
    ├── unblock_user.sh         # Desbloquear usuário (hot reload)
    ├── remover_expirados.sh    # Limpar usuários vencidos
    ├── limiterxray.sh          # Controle de consumo por GB (V1.2)
    ├── onlinexray.sh           # Monitor online (API)
    ├── backup.sh               # Backup e restore
    ├── bbr.sh                  # Ativar/desativar BBR
    ├── check_api.sh            # API /check com autenticação (V1.1)
    ├── checkuser.sh            # CheckUser API para apps VPN
    ├── sanitize.sh             # Módulo de sanitização de entrada
    ├── botxray.sh              # Instalador do bot Telegram
    ├── botxray.py              # Bot Telegram (Python)
    ├── uninstall.sh            # Desinstalação completa
    └── *.sha256                # Hashes de integridade (automáticos)
```

---

## 📝 Changelog — V1.1

### Novas Funcionalidades
- **CheckUser API** — suporte para apps VPN (Conecta4G, DTunnel)
- **Autenticação API-Key** — proteção com X-API-Key header
- **Rate Limiting** — 60 req/min por IP para prevenir ataques
- **Senha por usuário** — autenticação adicional além do UUID
- **Limite de conexões** — controle de dispositivos simultâneos
- **Módulo sanitize.sh** — sanitização de entrada em todos os módulos
- **Migração users.db** — script para converter usuários existentes

### Melhorias de Segurança
- Autenticação em endpoints `/check`
- Rate limiting por IP
- Sanitização de entrada (proteção contra injeção)
- Validação de campos em todos os módulos

### Correções
- Portas sincronizadas entre módulos (API Xray: 1080)
- Cache de status melhorado no menu
- Verificação de integridade SHA256 mais robusta

---

## 📄 Licença

Projeto de uso livre para administração pessoal de servidores VPS.
