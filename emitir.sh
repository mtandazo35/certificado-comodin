#!/usr/bin/env bash
# Emite (o renueva) el certificado comodín *.DOMINIO de Let's Encrypt por DNS-01
# con la API del proveedor del DNS (DirectAdmin, cPanel o Cloudflare) y lo
# reparte a los servidores nginx (distribuir.sh).
#
# Se ejecuta una vez a mano. Deja un cron propio que renueva y vuelve a repartir.
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/comun.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root"
[[ -f "$DIR/servidores.txt" ]] || die "falta $DIR/servidores.txt (copiar servidores.txt.ejemplo y editarlo)"
[[ -f "$CLAVE" ]] || die "falta la clave SSH $CLAVE (ver README, paso 2)"
[[ "$DOMINIO" != *ejemplo.com ]] || die "comodin.conf todavía tiene el dominio de ejemplo"

case "${PROVEEDOR:-}" in
  directadmin) HOOK=dns_da;      VARS=(DA_Api) ;;
  cpanel)      HOOK=dns_cpanel;  VARS=(cPanel_Username cPanel_Apitoken cPanel_Hostname) ;;
  cloudflare)  HOOK=dns_cf;      VARS=(CF_Token CF_Zone_ID) ;;
  *) die "PROVEEDOR debe ser directadmin, cpanel o cloudflare (está: '${PROVEEDOR:-}')" ;;
esac

exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') emitir.sh: *.$DOMINIO ($PROVEEDOR)"

if [[ ! -x "$ACME" ]]; then
  echo "Instalando acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s email="$CORREO"
fi
install -d -m 700 "$ACME_CONF"
acme() { "$ACME" --home /root/.acme.sh --config-home "$ACME_CONF" "$@"; }
acme --set-default-ca --server letsencrypt

# ---------------------------------------------------------------- credenciales
# Se piden solo si acme.sh no las tiene ya guardadas en ./acme/account.conf.
guardada() { grep -qs "$1=" "$ACME_CONF/account.conf"; }
leer() {      # leer VARIABLE "texto" secreta(s/n)
  local valor
  if [[ "$3" == s ]]; then read -rsp "$2: " valor </dev/tty; echo
  else read -rp "$2: " valor </dev/tty; fi
  [[ -n "$valor" ]] || die "$1 vacío"
  export "$1=$valor"
}

faltan=0
for v in "${VARS[@]}"; do guardada "$v" || faltan=1; done
if [[ $faltan -eq 1 ]]; then
  echo
  case "$PROVEEDOR" in
    directadmin)
      echo "DirectAdmin: Login Key con CMD_API_DNS_CONTROL y CMD_API_SHOW_DOMAINS."
      leer DA_Api "DA_Api (https://USUARIO:LOGIN_KEY@SERVIDOR-DIRECTADMIN:2222)" s
      [[ "$DA_Api" == https://*:*@* ]] || die "formato de DA_Api no válido"
      ;;
    cpanel)
      echo "cPanel: token de Security → Manage API Tokens."
      leer cPanel_Username "Usuario de cPanel" n
      leer cPanel_Apitoken "Token de la API" s
      leer cPanel_Hostname "Servidor (https://SERVIDOR-CPANEL:2083)" n
      [[ "$cPanel_Hostname" == https://* ]] || die "cPanel_Hostname debe empezar por https://"
      ;;
    cloudflare)
      echo "Cloudflare: token con Zone > DNS > Edit solo para esta zona."
      leer CF_Token "Token de la API" s
      leer CF_Zone_ID "Zone ID (Overview de la zona, columna derecha)" n
      ;;
  esac
fi
[[ "$PROVEEDOR" == directadmin ]] && export DA_Api_Insecure="${DA_API_INSECURE:-0}"

# ---------------------------------------------------------------- emisión
rc=0
acme --issue --dns "$HOOK" -d "*.$DOMINIO" -d "$DOMINIO" --dnssleep "${ESPERA_DNS:-300}" || rc=$?
# 2 = el certificado sigue vigente y no toca renovarlo: no es error.
[[ $rc -eq 0 || $rc -eq 2 ]] || die "acme.sh --issue falló (código $rc); detalle arriba y en $LOG"

install -d -m 700 "$DIR/actual"
acme --install-cert -d "*.$DOMINIO" \
  --key-file "$KEY" \
  --fullchain-file "$CRT" \
  --reloadcmd "$DIR/distribuir.sh" ||
  echo "AVISO: el reparto tuvo errores (detalle arriba). Corregir y repetir: $DIR/distribuir.sh"
chmod 600 "$KEY"

# ---------------------------------------------------------------- renovación
# El cron que instala acme.sh solo mira su config-home por defecto: este dominio
# necesita el suyo. Un minuto al azar para no coincidir con otros dominios.
cron="/etc/cron.d/certificado-comodin-${DOMINIO//./-}"
if [[ ! -f "$cron" ]]; then
  cat > "$cron" <<EOF
# certificado-comodin: renovación de *.$DOMINIO ($DIR)
$((RANDOM % 60)) 3 * * * root $ACME --cron --home /root/.acme.sh --config-home $ACME_CONF >> $LOG 2>&1
EOF
  chmod 644 "$cron"
  echo "Renovación diaria programada en $cron"
fi

echo
echo "Listo. Próxima renovación: $ACME --list --config-home $ACME_CONF   ·   Estado: $DIR/estado.sh"
