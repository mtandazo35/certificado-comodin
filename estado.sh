#!/usr/bin/env bash
# Muestra, por servidor, hasta cuándo vale el certificado comodín que tiene en
# disco, si coincide con el del servidor de gestión y cuántos sitios de nginx
# lo usan.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/comun.sh"

if [[ -s "$CRT" ]]; then
  local_sha="$(sha256sum "$CRT" | cut -d' ' -f1)"
  echo "Gestión: *.$DOMINIO ($PROVEEDOR) vence $(openssl x509 -enddate -noout -in "$CRT" | cut -d= -f2)"
else
  local_sha=""
  echo "Gestión: sin certificado todavía (ejecutar emitir.sh)"
fi
echo

printf '%-22s %-26s %-10s %s\n' SERVIDOR VENCE "¿ACTUAL?" "SITIOS QUE LO USAN"
while read -r linea <&3; do
  linea="${linea%%#*}"; linea="${linea// /}"
  [[ -z "$linea" ]] && continue
  host="${linea%%:*}"; puerto=22
  [[ "$linea" == *:* ]] && puerto="${linea##*:}"
  datos="$(ssh -n "${SSH_OPC[@]}" -p "$puerto" "root@$host" "
    f='$DESTINO/fullchain.pem'
    if [ -s \"\$f\" ]; then
      echo \"\$(openssl x509 -enddate -noout -in \"\$f\" | cut -d= -f2)|\$(sha256sum \"\$f\" | cut -d' ' -f1)\"
    else echo 'sin certificado|'; fi
    nginx -T 2>/dev/null | grep -c 'include.*ssl-$DOMINIO.conf'
    true
  " 2>/dev/null)"
  if [[ $? -eq 255 ]]; then printf '%-22s %s\n' "$linea" "SIN ACCESO por SSH"; continue; fi
  vence="$(sed -n 1p <<<"$datos" | cut -d'|' -f1)"
  sha="$(sed -n 1p <<<"$datos" | cut -d'|' -f2)"
  sitios="$(sed -n 2p <<<"$datos")"
  actual="no"; [[ -n "$sha" && "$sha" == "$local_sha" ]] && actual="sí"
  printf '%-22s %-26s %-10s %s\n' "$linea" "$vence" "$actual" "${sitios:-0}"
done 3< "$DIR/servidores.txt"
