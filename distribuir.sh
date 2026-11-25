#!/usr/bin/env bash
# Copia el certificado comodín a cada servidor de servidores.txt, comprueba
# nginx -t y recarga. Si nginx -t falla, restaura el certificado anterior en
# ese servidor y sigue con los demás.
#
# Lo llama acme.sh tras cada renovación. A mano:
#   ./distribuir.sh            reparte solo donde el certificado es distinto
#   ./distribuir.sh --forzar   reparte a todos
#   ./distribuir.sh 10.0.0.20  solo a ese servidor
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/certificado-comodin.log
CLAVE=/root/.ssh/comodin
# El host key no se verifica a propósito: las IPs internas se reutilizan entre máquinas.
SSH_OPC=(-i "$CLAVE" -o BatchMode=yes -o ConnectTimeout=10
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') distribuir.sh $*"

# shellcheck source=/dev/null
. "$DIR/comodin.conf" || { echo "ERROR: falta comodin.conf"; exit 1; }
CRT="$DIR/actual/fullchain.pem"
KEY="$DIR/actual/key.pem"
[[ -s "$CRT" && -s "$KEY" ]] || { echo "ERROR: no hay certificado en $DIR/actual (ejecutar emitir.sh)"; exit 1; }

forzar=0
solo=""
for a in "$@"; do
  case "$a" in
    --forzar) forzar=1 ;;
    *) solo="$a" ;;
  esac
done

local_sha="$(sha256sum "$CRT" | cut -d' ' -f1)"
ok=0; igual=0; fallos=()

# Se ejecuta en cada servidor: instala el certificado nuevo, prueba y recarga.
REMOTO='
set -u
d="$1"
command -v nginx >/dev/null || { echo "nginx no está instalado"; exit 3; }
mkdir -p /etc/nginx/snippets
if [ ! -f /etc/nginx/snippets/comodin-ssl.conf ]; then
  cat > /etc/nginx/snippets/comodin-ssl.conf <<EOF
# Generado por certificado-comodin. Se incluye en cada server { listen 443 ssl; ... }
ssl_certificate     $d/fullchain.pem;
ssl_certificate_key $d/key.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
EOF
fi
rm -rf "$d.anterior"
[ -d "$d" ] && cp -a "$d" "$d.anterior"
mkdir -p "$d" && chmod 700 "$d"
install -m 644 "$d.nuevo/fullchain.pem" "$d/fullchain.pem"
install -m 600 "$d.nuevo/key.pem" "$d/key.pem"
rm -rf "$d.nuevo"
if nginx -t >/tmp/comodin-nginx-t.txt 2>&1; then
  systemctl reload nginx && echo "recargado"
else
  cat /tmp/comodin-nginx-t.txt
  rm -rf "$d"
  [ -d "$d.anterior" ] && mv "$d.anterior" "$d"
  echo "nginx -t falló: se restauró el certificado anterior"
  exit 4
fi
'

# La lista se lee por el descriptor 3: ssh lee stdin y, si no, se comería el resto de líneas.
while read -r linea <&3; do
  linea="${linea%%#*}"; linea="${linea// /}"
  [[ -z "$linea" ]] && continue
  [[ -n "$solo" && "$linea" != "$solo" && "${linea%%:*}" != "$solo" ]] && continue
  host="${linea%%:*}"; puerto=22
  [[ "$linea" == *:* ]] && puerto="${linea##*:}"

  printf '%-22s ' "$linea"
  remoto_sha="$(ssh -n "${SSH_OPC[@]}" -p "$puerto" "root@$host" \
    "sha256sum '$DESTINO/fullchain.pem' 2>/dev/null | cut -d' ' -f1" 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 255 ]]; then
    echo "SIN ACCESO por SSH"; fallos+=("$linea (SSH)"); continue
  fi
  if [[ $forzar -eq 0 && "$remoto_sha" == "$local_sha" ]]; then
    echo "ya tiene el certificado actual"; igual=$((igual + 1)); continue
  fi

  if ! ssh -n "${SSH_OPC[@]}" -p "$puerto" "root@$host" "mkdir -p '$DESTINO.nuevo' && chmod 700 '$DESTINO.nuevo'" ||
     ! scp -q "${SSH_OPC[@]}" -P "$puerto" "$CRT" "$KEY" "root@$host:$DESTINO.nuevo/"; then
    echo "ERROR al copiar"; fallos+=("$linea (copia)"); continue
  fi
  if salida="$(ssh "${SSH_OPC[@]}" -p "$puerto" "root@$host" "bash -s -- '$DESTINO'" <<<"$REMOTO" 2>&1)"; then
    echo "OK, $salida"; ok=$((ok + 1))
  else
    echo "ERROR"; echo "$salida" | sed 's/^/    /'; fallos+=("$linea (nginx)")
  fi
done 3< "$DIR/servidores.txt"

echo "Resumen: $ok actualizados, $igual ya al día, ${#fallos[@]} con error."
if [[ ${#fallos[@]} -gt 0 ]]; then
  printf '  - %s\n' "${fallos[@]}"
  exit 1
fi
