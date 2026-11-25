# certificado-comodin

Un certificado **comodín de Let's Encrypt** (`*.int.ejemplo.com`) para varias webs **internas** con
nginx y **IPs privadas**, emitido una sola vez y repartido a todos los servidores. Funciona con el DNS
en **DirectAdmin, cPanel o Cloudflare**.

- **Validación DNS-01** con la API del proveedor del DNS. Let's Encrypt no se conecta a ningún
  servidor: comprueba un registro TXT `_acme-challenge.int.ejemplo.com` en el DNS público. Por eso
  sirve con IPs privadas, y es el único desafío que admite comodines.
- **Un único servidor de gestión** guarda las credenciales del DNS y emite. Los servidores nginx solo
  reciben el certificado. Es lo que recomienda la documentación de Let's Encrypt: no repartir las
  credenciales del DNS por todos los servidores web.
- **Renovación automática:** un cron propio renueva cada ~60 días y llama a `distribuir.sh`, que copia
  el certificado por SSH, comprueba con `nginx -t` y recarga. Si `nginx -t` falla en un servidor, en
  ese servidor se deja el certificado anterior.
- **Funciona en todos los equipos sin instalarles nada**, porque la firma es de Let's Encrypt.

```
        DirectAdmin / cPanel / Cloudflare (TXT _acme-challenge)        Let's Encrypt
                          ▲                                                  │ comprueba el TXT
                          │ API                                              ▼
  servidor de gestión ── emitir.sh / acme.sh ────────────────────────────────┘
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

## Paso 1. Credenciales del DNS (según el proveedor)

**Primero, comprobar quién sirve el DNS del dominio:** `dig +short NS ejemplo.com`. Las credenciales
tienen que ser de **ese** proveedor. Si se crean en otro panel, el TXT queda donde nadie lo ve y la
validación falla.

### DirectAdmin

1. Entra con el usuario dueño del dominio.
2. Ve a **Advanced Features → Login Keys → Create key**:
   - **Key Name:** `acme-dns01`. **Key Value:** una clave larga, guardada en tu gestor de contraseñas.
   - **Expires:** con fecha.
   - **Commands:** solo **`CMD_API_DNS_CONTROL`** y **`CMD_API_SHOW_DOMAINS`**.
   - **Allowed IPs:** la IP **pública** con la que el servidor de gestión sale a internet.
3. `emitir.sh` te pedirá: `https://USUARIO:LOGIN_KEY@SERVIDOR-DIRECTADMIN:2222`.

### cPanel

1. Entra en cPanel con la cuenta del dominio.
2. Ve a **Seguridad → Manage API Tokens → Create**:
   - **Nombre:** `acme-dns01`.
   - **Caducidad:** con fecha.
3. Copia el token: solo se muestra una vez.
4. `emitir.sh` te pedirá:
   - el **usuario** de cPanel;
   - el **token**;
   - el **servidor**: `https://SERVIDOR-CPANEL:2083`.

**Ojo:** un token de cPanel **no se puede limitar al DNS**. Da acceso a toda la cuenta (web, correo,
archivos). Por eso no debe salir del servidor de gestión y conviene que caduque.

### Cloudflare

1. En Cloudflare ve a **My Profile → API Tokens → Create Token** y usa la plantilla **Edit zone DNS**.
2. Configura el token:
   - **Permissions:** `Zone → DNS → Edit`.
   - **Zone Resources:** `Include → Specific zone → ejemplo.com`.
   - **Client IP Address Filtering:** la IP **pública** del servidor de gestión.
   - **TTL:** con fecha de fin.
3. Crea el token y cópialo.
4. Copia también el **Zone ID**: está en la página **Overview** de la zona, en la columna derecha.
5. `emitir.sh` te pedirá el **token** y el **Zone ID**.

No uses la **Global API Key**: da acceso a toda la cuenta de Cloudflare.

## Paso 2. Servidor de gestión

Cualquier Debian/Ubuntu interno con salida a internet que llegue por SSH a los servidores nginx.
Mejor una VM de gestión que un servidor en producción.

El repo es privado y el servidor no tiene credenciales de GitHub. Se copia desde el PC:

```bash
# en el PC
scp -r C:/Users/<usuario>/Documents/GitHub/certificado-comodin root@10.0.0.5:/root/
```

```bash
# en el servidor de gestión
cd /root/certificado-comodin
chmod +x emitir.sh distribuir.sh estado.sh
cp comodin.conf.ejemplo comodin.conf          # editar: PROVEEDOR, DOMINIO, CORREO
cp servidores.txt.ejemplo servidores.txt      # editar: una IP por línea

# Clave SSH solo para repartir el certificado (una para todos los dominios)
[ -f /root/.ssh/comodin ] || ssh-keygen -t ed25519 -f /root/.ssh/comodin -N '' -C certificado-comodin
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

- **La primera vez pide las credenciales del paso 1.** Lo secreto no se ve al escribirlo.
  Las guarda acme.sh en `./acme/` (solo root). Esa carpeta es exclusiva de este dominio: si otro
  dominio usa otra cuenta del mismo proveedor, sus credenciales no se mezclan.
- **Espera `ESPERA_DNS` segundos** (300 por defecto) a que el TXT se propague antes de validar.
  Según Let's Encrypt, en algunos proveedores tarda hasta una hora. Si falla con "TXT no
  encontrado", sube `ESPERA_DNS`.
- **Reparte el certificado** a todos los servidores de `servidores.txt`.
- **Deja la renovación diaria** en `/etc/cron.d/certificado-comodin-<dominio>`.

En cada servidor nginx quedan:

| Archivo | Qué es |
|---|---|
| `/etc/nginx/ssl/int.ejemplo.com/fullchain.pem` y `key.pem` | el certificado y su clave |
| `/etc/nginx/snippets/ssl-int.ejemplo.com.conf` | las líneas `ssl_certificate` listas para incluir |

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
    include snippets/ssl-int.ejemplo.com.conf;

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

No hace falta publicarlos en el panel del dominio: Let's Encrypt solo mira el TXT. Si los publicas
igualmente:
- **En Cloudflare**, déjalos en **DNS only** (nube gris). El proxy no llega a una IP privada.
- **Protección contra DNS rebinding.** Los resolvers que la tienen (Unbound con `private-address`,
  dnsmasq) descartan esas respuestas. Hay que añadir `private-domain: "int.ejemplo.com"` en Unbound o
  `rebind-domain-ok=/int.ejemplo.com/` en dnsmasq.

## Varios dominios o varios proveedores

**Una carpeta por dominio.** Cada carpeta tiene su `comodin.conf`, su `servidores.txt`, sus
credenciales (`./acme/`) y su cron. La clave SSH es la misma para todas.

```bash
cp -r /root/certificado-comodin /root/certificado-comodin-otrodominio
cd /root/certificado-comodin-otrodominio
rm -rf acme actual                 # que no herede credenciales ni certificado del otro
# editar comodin.conf (PROVEEDOR, DOMINIO) y servidores.txt
./emitir.sh
```

Un mismo servidor nginx puede recibir certificados de varios dominios: cada uno va a su carpeta
y a su snippet (`ssl-<dominio>.conf`).

## Día a día

```bash
./estado.sh                      # vencimiento por servidor, si está al día y cuántos sitios lo usan
./distribuir.sh                  # reparte donde falte o esté desactualizado
./distribuir.sh 10.0.0.23        # solo a un servidor (por ejemplo, uno nuevo)
./distribuir.sh --forzar         # vuelve a copiar a todos
/root/.acme.sh/acme.sh --list --config-home ./acme    # fecha de la próxima renovación
```

**Agregar un servidor nuevo:**
1. Pasos 3, 5 y 6 en ese servidor.
2. Añadir su IP a `servidores.txt`.
3. `./distribuir.sh <IP>`.

Registro de todo: `/var/log/certificado-comodin.log`.

## Problemas conocidos

| Síntoma | Causa | Arreglo |
|---|---|---|
| Error de la API al crear el TXT | credencial caducada o sin permisos; IP de salida no permitida (DirectAdmin, Cloudflare); Zone ID de otra zona | revisar la credencial del paso 1 |
| Validación falla: TXT no encontrado | el DNS público aún no tiene el TXT, o los NS del dominio no son de ese proveedor | subir `ESPERA_DNS`; comprobar `dig NS` |
| Cambió la credencial (caducó, se revocó) | acme.sh sigue usando la guardada | borrar `./acme/account.conf` **no**: editar ahí la variable o borrar solo esa línea y repetir `./emitir.sh` |
| `SIN ACCESO por SSH` | falta la clave en `authorized_keys`, o el `from=` no coincide con la IP del servidor de gestión | paso 3 |
| `nginx -t falló` | error en la configuración del sitio | el certificado anterior queda en su sitio; corregir y `./distribuir.sh <IP>` |
| El navegador muestra otro certificado | el sitio no incluye el snippet del dominio, o el nombre no es del comodín | paso 5 y la columna de sitios de `estado.sh` |
| Caduca sin aviso | la credencial del DNS caducó y la renovación falla en silencio | `./estado.sh` cada mes; renovar la credencial antes de su fecha |
