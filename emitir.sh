#!/usr/bin/env bash
# Emite (o renueva) el certificado comodín *.DOMINIO de Let's Encrypt por DNS-01
# con la API de DirectAdmin, y lo reparte a los servidores nginx (distribuir.sh).
# Se ejecuta una vez a mano; después acme.sh renueva solo y vuelve a repartir.
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME=/root/.acme.sh/acme.sh
LOG=/var/log/certificado-comodin.log

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root"
[[ -f "$DIR/comodin.conf" ]] || die "falta $DIR/comodin.conf (copiar comodin.conf.ejemplo y editarlo)"
[[ -f "$DIR/servidores.txt" ]] || die "falta $DIR/servidores.txt (copiar servidores.txt.ejemplo y editarlo)"
[[ -f /root/.ssh/comodin ]] || die "falta la clave SSH /root/.ssh/comodin (ver README, paso 2)"
# shellcheck source=/dev/null
. "$DIR/comodin.conf"
[[ -n "${DOMINIO:-}" && "$DOMINIO" == *.* ]] || die "DOMINIO no válido en comodin.conf"
[[ "$DOMINIO" != *ejemplo.com ]] || die "comodin.conf todavía tiene el dominio de ejemplo"

exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') emitir.sh: *.$DOMINIO"

if [[ ! -x "$ACME" ]]; then
  echo "Instalando acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s email="$CORREO"
fi
"$ACME" --set-default-ca --server letsencrypt

# La clave de DirectAdmin: si acme.sh ya la guardó, no se vuelve a pedir.
if ! grep -qs 'DA_Api=' /root/.acme.sh/account.conf /root/.acme.sh/*/*.conf; then
  echo
  echo "Clave de la API de DirectAdmin (Login Key solo con CMD_API_DNS_CONTROL)."
  echo "Formato: https://USUARIO:LOGIN_KEY@SERVIDOR-DIRECTADMIN:2222"
  read -rsp "DA_Api: " DA_Api </dev/tty
  echo
  [[ "$DA_Api" == https://*:*@* ]] || die "formato no válido"
  export DA_Api
fi
export DA_Api_Insecure="${DA_API_INSECURE:-0}"

rc=0
"$ACME" --issue --dns dns_da -d "*.$DOMINIO" -d "$DOMINIO" --dnssleep "${ESPERA_DNS:-300}" || rc=$?
# 2 = el certificado existe y aún no toca renovarlo: no es error.
[[ $rc -eq 0 || $rc -eq 2 ]] || die "acme.sh --issue falló (código $rc); detalle arriba y en $LOG"

install -d -m 700 "$DIR/actual"
"$ACME" --install-cert -d "*.$DOMINIO" \
  --key-file "$DIR/actual/key.pem" \
  --fullchain-file "$DIR/actual/fullchain.pem" \
  --reloadcmd "$DIR/distribuir.sh" ||
  echo "AVISO: el reparto tuvo errores (detalle arriba). Corregir y repetir: $DIR/distribuir.sh"
chmod 600 "$DIR/actual/key.pem"

echo
echo "Listo. Renovación automática: acme.sh --list   ·   Estado: $DIR/estado.sh"
