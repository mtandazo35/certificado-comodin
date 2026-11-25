# Lo cargan emitir.sh, distribuir.sh y estado.sh: configuración y rutas comunes.
# shellcheck shell=bash

[[ -f "$DIR/comodin.conf" ]] || { echo "ERROR: falta $DIR/comodin.conf (copiar comodin.conf.ejemplo y editarlo)" >&2; exit 1; }
# shellcheck source=/dev/null
. "$DIR/comodin.conf"

[[ -n "${DOMINIO:-}" && "$DOMINIO" == *.* ]] || { echo "ERROR: DOMINIO no válido en comodin.conf" >&2; exit 1; }
DESTINO="${DESTINO:-/etc/nginx/ssl/$DOMINIO}"
SNIPPET="/etc/nginx/snippets/ssl-$DOMINIO.conf"

ACME=/root/.acme.sh/acme.sh
ACME_CONF="$DIR/acme"                 # config-home propio: credenciales y cuenta solo de este dominio
LOG=/var/log/certificado-comodin.log
CLAVE=/root/.ssh/comodin
# El host key no se verifica a propósito: las IPs internas se reutilizan entre máquinas.
SSH_OPC=(-i "$CLAVE" -o BatchMode=yes -o ConnectTimeout=10
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
CRT="$DIR/actual/fullchain.pem"
KEY="$DIR/actual/key.pem"
