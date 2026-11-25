# certificado-comodin

Un certificado **comodín de Let's Encrypt** (`*.int.ejemplo.com`) para varias webs **internas** con
nginx y **IPs privadas**, emitido una sola vez y repartido a todos los servidores.

- **Validación DNS-01** con la API de DirectAdmin. Let's Encrypt no se conecta a ningún servidor:
  comprueba un registro TXT `_acme-challenge.int.ejemplo.com` en el DNS público. Por eso sirve con
  IPs privadas, y es el único desafío que admite comodines.
- **Un único servidor de gestión** guarda la clave de la API y emite. Los servidores nginx solo
  reciben el certificado. Es lo que recomienda la documentación de Let's Encrypt: no repartir las
  credenciales del DNS por todos los servidores web.
- **Renovación automática:** acme.sh renueva cada ~60 días y llama a `distribuir.sh`, que copia el
  certificado por SSH, comprueba con `nginx -t` y recarga. Si `nginx -t` falla en un servidor, en ese
  servidor se deja el certificado anterior.
- **Funciona en todos los equipos sin instalarles nada**, porque la firma es de Let's Encrypt.

```
                 DirectAdmin (TXT _acme-challenge)          Let's Encrypt
                          ▲                                       │ comprueba el TXT
                          │ API (solo DNS)                        ▼
  servidor de gestión ── emitir.sh / acme.sh ─────────────────────┘
        │  distribuir.sh (SSH)
        ├──► nginx 10.0.0.20   web.int.ejemplo.com
        ├──► nginx 10.0.0.21   app.int.ejemplo.com
        └──► nginx 10.0.0.22   …
```

## Qué nombres usar

El comodín cubre **un solo nivel**: `*.int.ejemplo.com` vale para `web.int.ejemplo.com` pero no para
`int.ejemplo.com` (por eso se emite también ese nombre) ni para `a.web.int.ejemplo.com`.

Conviene usar un **subdominio dedicado** (`int.`) y no `*.ejemplo.com`. La clave privada del comodín
va copiada en todos los servidores internos. Con `*.ejemplo.com`, quien la robe en cualquiera de
ellos podría suplantar también la web y el correo públicos del dominio.

## Paso 1. Login Key en DirectAdmin

1. Entra en DirectAdmin con el usuario dueño del dominio.
2. Ve a **Advanced Features → Login Keys → Create key**:
   - **Key Name:** `acme-dns01`. **Key Value:** una clave larga, guardada en tu gestor de contraseñas.
   - **Expires:** con fecha. Antes de esa fecha hay que crear otra y repetir el paso 4.
   - **Commands:** solo **`CMD_API_DNS_CONTROL`**.
   - **Allowed IPs:** la IP **pública** con la que el servidor de gestión sale a internet.

Comprueba también que el DNS del dominio lo sirve ese DirectAdmin:
`dig +short NS ejemplo.com`. Si los NS son de otro proveedor, el TXT se crea donde nadie lo ve y la
validación falla.

## Paso 2. Servidor de gestión

Cualquier Debian/Ubuntu interno con salida a internet que llegue por SSH a los servidores nginx.
Mejor una VM de gestión que un servidor en producción.

```bash
cd /root
git clone https://github.com/mtandazo35/certificado-comodin.git
cd certificado-comodin
cp comodin.conf.ejemplo comodin.conf          # editar: DOMINIO, CORREO
cp servidores.txt.ejemplo servidores.txt      # editar: una IP por línea

# Clave SSH solo para repartir el certificado
ssh-keygen -t ed25519 -f /root/.ssh/comodin -N '' -C certificado-comodin
cat /root/.ssh/comodin.pub
```

## Paso 3. Autorizar la clave en cada servidor nginx

En **cada** servidor nginx, añade a `/root/.ssh/authorized_keys` la clave pública **limitada a la IP
interna del servidor de gestión**:

```
from="10.0.0.5" ssh-ed25519 AAAA...resto-de-la-clave... certificado-comodin
```

Con `from=`, aunque alguien robe la clave no puede usarla desde otra máquina. Pruébalo desde el
servidor de gestión:
`ssh -i /root/.ssh/comodin root@10.0.0.20 nginx -v`.

## Paso 4. Emitir y repartir

```bash
cd /root/certificado-comodin
./emitir.sh
```

- La primera vez pide la clave de la API, con el formato
  `https://USUARIO:LOGIN_KEY@SERVIDOR-DIRECTADMIN:2222`. No se ve al escribirla.
- acme.sh la guarda en `/root/.acme.sh/`, que solo puede leer root. Las renovaciones la usan desde
  ahí.
- Espera `ESPERA_DNS` segundos (300 por defecto) a que el TXT se propague antes de validar. Según
  Let's Encrypt, en algunos proveedores tarda hasta una hora. Si falla con "TXT no encontrado", sube
  `ESPERA_DNS` en `comodin.conf`.
- Al terminar, reparte el certificado a todos los servidores de `servidores.txt`.

En cada servidor nginx quedan:
- `/etc/nginx/ssl/comodin/fullchain.pem` y `key.pem`;
- `/etc/nginx/snippets/comodin-ssl.conf`, con las líneas `ssl_certificate` listas para incluir.

## Paso 5. Activar HTTPS en cada sitio

En cada servidor, **respaldo primero**:
`tar -czf /root/backups/nginx-pre-ssl-$(date +%F-%H%M).tar.gz /etc/nginx`.

Después edita el sitio (`/etc/nginx/sites-available/<sitio>`). El bloque del 80 pasa al 443 y el 80
queda solo para redirigir:

```nginx
server {
    listen 80;
    server_name web.int.ejemplo.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name web.int.ejemplo.com;
    include snippets/comodin-ssl.conf;

    # Aquí va todo lo que tenía el bloque del 80: root, index, location, proxy_pass…
}
```

```bash
nginx -t && systemctl reload nginx
```

Si `nginx -t` da error, no recargues: corrige o restaura el respaldo.

## Paso 6. Nombres en el DNS interno

Cada nombre tiene que resolver a la IP privada de su servidor **en el DNS que usan los equipos**. Por
ejemplo, en Pi-hole → **Settings → Local DNS Records**:

| Dominio | IP |
|---|---|
| `web.int.ejemplo.com` | `10.0.0.20` |
| `app.int.ejemplo.com` | `10.0.0.21` |

No hace falta publicarlos en DirectAdmin: Let's Encrypt solo mira el TXT. Si los publicas igualmente,
los resolvers con protección contra DNS rebinding (Unbound con `private-address`, dnsmasq) descartan
la respuesta. Hay que añadir `private-domain: "int.ejemplo.com"` en Unbound o
`rebind-domain-ok=/int.ejemplo.com/` en dnsmasq.

## Día a día

```bash
./estado.sh                      # vencimiento por servidor, si está al día y cuántos sitios lo usan
./distribuir.sh                  # reparte donde falte o esté desactualizado
./distribuir.sh 10.0.0.23        # solo a un servidor (por ejemplo, uno nuevo)
./distribuir.sh --forzar         # vuelve a copiar a todos
/root/.acme.sh/acme.sh --list    # fecha de la próxima renovación
```

**Agregar un servidor nuevo:** pasos 3, 5 y 6 en ese servidor, añadir su IP a `servidores.txt` y
`./distribuir.sh <IP>`.

Registro de todo: `/var/log/certificado-comodin.log`.

## Problemas conocidos

| Síntoma | Causa | Arreglo |
|---|---|---|
| `Invalid domain` o error de la API al crear el TXT | Login Key sin `CMD_API_DNS_CONTROL`, caducada, o la IP de salida no está en Allowed IPs | revisar la Login Key |
| Validación falla: TXT no encontrado | el DNS público aún no tiene el TXT, o los NS del dominio no son ese DirectAdmin | subir `ESPERA_DNS`; comprobar `dig NS` |
| `SIN ACCESO por SSH` | falta la clave en `authorized_keys`, o el `from=` no coincide con la IP del servidor de gestión | paso 3 |
| `nginx -t falló` | error en la configuración del sitio | el certificado anterior queda en su sitio; corregir y `./distribuir.sh <IP>` |
| El navegador muestra otro certificado | el sitio no incluye `snippets/comodin-ssl.conf`, o el nombre no es del comodín | paso 5 y la columna de sitios de `estado.sh` |
| Caduca sin aviso | la Login Key caducó o se revocó; la renovación falla en silencio | `./estado.sh` cada mes; crear una Login Key nueva y repetir `./emitir.sh` |
