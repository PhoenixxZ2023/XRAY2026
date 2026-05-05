#!/bin/bash
# generate_hashes.sh - TURBONET XRAY V1.0
# Gera arquivos .sha256 para todos os módulos do repositório.
# Execute na raiz do repositório antes de fazer push.
# Os arquivos .sha256 devem ser commitados junto com os módulos.

set -euo pipefail

MODULES_DIR="modulosxray"
ROOT_FILES=("installxray.sh" "menuxray.sh")

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

echo -e "${CYAN}=== TURBONET XRAY — Gerador de SHA256 ===${RESET}"
echo ""

count=0

# Módulos em modulosxray/
if [ -d "$MODULES_DIR" ]; then
    for f in "$MODULES_DIR"/*.sh "$MODULES_DIR"/*.py; do
        [ -f "$f" ] || continue
        sha256sum "$f" | awk '{print $1}' > "${f}.sha256"
        echo -e " ${GREEN}✓${RESET} $(basename $f).sha256"
        count=$(( count + 1 ))
    done
fi

# Arquivos raiz
for f in "${ROOT_FILES[@]}"; do
    [ -f "$f" ] || continue
    sha256sum "$f" | awk '{print $1}' > "${f}.sha256"
    echo -e " ${GREEN}✓${RESET} ${f}.sha256"
    count=$(( count + 1 ))
done

echo ""
echo -e "${GREEN}✅ ${count} arquivo(s) .sha256 gerados.${RESET}"
echo ""
echo -e "${YELLOW}Próximo passo — commitar os hashes:${RESET}"
echo "  git add **/*.sha256 *.sha256"
echo "  git commit -m 'chore: atualiza SHA256 dos módulos'"
echo "  git push"
