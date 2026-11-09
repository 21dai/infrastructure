# Infrastructure

Infraestructura Docker del proyecto de microservicios.

Este repositorio contiene la configuración necesaria para ejecutar el sistema utilizando **Docker Compose** y **Traefik** como reverse proxy y balanceador de carga.

## Estructura del proyecto

Los repositorios deben estar ubicados como carpetas hermanas:

```text
Proyecto/
├── orchestrator-service/
├── pdf-extractext/
├── document-store/
└── infrastructure/
```

Esto es necesario porque `docker-compose.yml` construye las imágenes utilizando rutas hacia los repositorios vecinos.

## Estructura del repositorio

```text
infrastructure/
├── certs/
│   └── .gitkeep
├── config/
│   └── tls.yml
├── docker-compose.yml
├── docker-compose.override.yml
├── .env.example
├── .gitignore
└── README.md
```

## Requisitos

Para ejecutar la infraestructura es necesario tener instalado:

- Docker Desktop
- Docker Compose
- mkcert

También deben estar clonados los repositorios:

- `orchestrator-service`
- `pdf-extractext`
- `document-store`

## Certificados TLS

Los certificados utilizados para desarrollo local no se almacenan en Git.

Primero instalar la autoridad certificadora local de `mkcert`:

```powershell
mkcert -install
```

Después, desde la carpeta `infrastructure`, generar los certificados:

```powershell
mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem "*.proyecto.localhost" "proyecto.localhost" localhost 127.0.0.1 ::1
```

Esto genera:

```text
certs/
├── local-cert.pem
└── local-key.pem
```

Estos archivos están excluidos de Git mediante `.gitignore`.

## Configurar el dominio local

El Orchestrator se expone mediante:

```text
https://orchestrator.proyecto.localhost
```

En Windows, si el dominio no resuelve automáticamente, agregar al archivo:

```text
C:\Windows\System32\drivers\etc\hosts
```

la siguiente línea:

```text
127.0.0.1 orchestrator.proyecto.localhost
```

## Variables de entorno

Las credenciales de MongoDB no estan en el compose: se leen de un `.env`
(ignorado por git). La primera vez, desde la carpeta `infrastructure`:

```powershell
copy .env.example .env
```

Sin `.env`, `docker compose` se niega a arrancar y dice que variable falta.

Variables opcionales (si no se definen, se usan los valores por defecto):

| Variable | Default | Para qué |
|---|---|---|
| `ORCHESTRATOR_PORT` | `8000` | Puerto del orquestador: `PORT`, su healthcheck y la label de Traefik |
| `PDF_EXTRACTEXT_PORT` | `8000` | Puerto de pdf-extractext: `PORT`, healthcheck, label de Traefik y la URL que usa el orquestador |
| `DOCUMENT_STORE_PORT` | `8000` | Puerto de document-store: `PORT`, healthcheck y la URL que usa el orquestador |
| `STACK_SUBNET` | `172.28.0.0/16` | Subred de la red del stack. El orquestador solo acepta `X-Forwarded-*` de esta red (`FORWARDED_ALLOW_IPS`). Cambiarla solo si choca con otra red de la máquina (`docker network inspect`) |

Cada puerto sale de **una sola variable** (12-Factor VII): no hay ningún `8000`
escrito salvo como valor por defecto.
Tambien define los tags de las imagenes (`ORCHESTRATOR_TAG`,
`PDF_EXTRACTEXT_TAG`, `DOCUMENT_STORE_TAG`): la version de cada servicio, que
hay que subir en cada release para que cada imagen quede identificada en vez de
pisar un `latest`.
Mongo crea el usuario solo al inicializar el volumen: si se cambia la clave,
hay que recrearlo con `docker compose down -v` (borra los datos).

> **Si ya tenías un `.env`**: cambiá los tags a `ORCHESTRATOR_TAG=0.2.0`,
> `DOCUMENT_STORE_TAG=0.2.0` y `PDF_EXTRACTEXT_TAG=2.0.1` (o volvé a copiar
> `.env.example`, conservando tu clave de MongoDB). Si quedan los viejos,
> `docker compose up --build` construye el código nuevo con la etiqueta vieja y
> pisa esa imagen. Además, la red del stack ahora tiene una subred fija: la
> primera vez hacé `docker compose down` antes del `up`, o Compose no puede
> recrear la red.

> **Si ya tenías un `.env`**: agregale `DOCUMENT_STORE_TAG=0.1.0` (o volvé a
> copiar `.env.example`). Sin esa variable `docker compose` no arranca y
> muestra `required variable DOCUMENT_STORE_TAG is missing a value`.

> **Si ya tenías un `.env`**: cambiá `PDF_EXTRACTEXT_TAG` a `2.0.0` (o volvé a
> copiar `.env.example`). Si queda en `1.4.0`, `docker compose` construye el
> código de la 2.0.0 y lo etiqueta `pdf-extractext:1.4.0`, pisando la imagen
> vieja con código nuevo.

## Levantar la infraestructura

Desde la carpeta `infrastructure`:

```powershell
docker compose up -d --build
```

Esto inicia:

- Traefik
- Orchestrator Service
- PDF Extractext (5 réplicas, 1 CPU y 1 GB cada una, sin base de datos)
- Document Store
- MongoDB (la base de Document Store)

`docker-compose.override.yml` se aplica solo y ajusta la concurrencia para las
pruebas de carga (1 proceso de uvicorn por réplica, Bulkhead del orquestador en
5). Para levantar sin esos ajustes:

```powershell
docker compose -f docker-compose.yml up -d --build
```

Esperar a que todo diga `healthy` en `docker compose ps` antes de probar:
mientras arranca, Traefik no tiene a dónde mandar el tráfico y responde 404.

### Orden de arranque y healthchecks

Los servicios arrancan en el orden que pidió la cátedra, cada uno recién cuando
el anterior está `healthy` (`depends_on` con `condition: service_healthy`):

```text
mongo → document-store → pdf-extractext → orchestrator
```

pdf-extractext no necesita a document-store para funcionar (no lo llama
nunca): esperarlo es solo el orden de arranque. El orquestador sí necesita a
los dos.

| Servicio | Healthcheck | Qué verifica |
|---|---|---|
| mongo | `mongosh ... ping` | La base responde |
| document-store | `GET /ready` | El proceso responde **y** MongoDB contesta el `ping` (503 si no) |
| pdf-extractext | `GET /health` | El proceso responde (no depende de nadie) |
| orchestrator | `GET /health` | El proceso responde |

Los tres servicios Python usan el mismo chequeo liviano (`python -S -I` con un
socket, sin cargar `urllib`), leen el puerto de `PORT` y chequean cada 10 s
(cada 1 s mientras arrancan), así que todo queda `healthy` pocos segundos
después del `up`. El del orquestador reemplaza al `HEALTHCHECK` de su
Dockerfile.

```powershell
docker compose ps        # STATUS: (healthy) en los cuatro
```

Con MongoDB detenido, document-store pasa a `unhealthy` (su `/ready` responde
503) y las altas responden 503 con Problem Details; al volver MongoDB, vuelve a
`healthy` solo.

## PDF Extractext: réplicas y POST /extract

`pdf-extractext` corre con 5 réplicas (el máximo del TP de carga) y sin
`container_name`, porque un nombre fijo impide crear réplicas. El orquestador
lo sigue encontrando por el nombre del servicio (`http://pdf-extractext:8000`).

`pdf-extractext` solo expone `POST /extract`: desde la 2.0.0 ya no tiene CRUD
ni base de datos (ADR-0008 de ese repo), así que una caída de MongoDB o de
document-store no lo afecta (en el arranque los espera solo por el orden). Traefik lo publica directo a las
réplicas, sin pasar por el orquestador:

```powershell
curl.exe -k -X POST https://extract.proyecto.localhost/extract -H "Content-Type: application/pdf" --data-binary "@documento.pdf"
```

Devuelve `{"content": "<Markdown>", "page_count": N}`. El contrato y las
pruebas de carga están en el repo `pdf-extractext` (`README.md` y
`tests/stress/`).

## Document Store

`document-store` guarda los documentos procesados. El orquestador le manda el
texto extraído, la cantidad de páginas y el SHA-256 que calcula del PDF
(ADR-0003 de `orchestrator-service`). Responde `201`, o `409` si ese checksum
ya está guardado.

- **Interno**: no tiene labels de Traefik ni puertos publicados. Solo lo llama
  el orquestador por la red de Compose (`http://document-store:8000`, variable
  `DOCUMENT_STORE_BASE_URL`).
- **MongoDB** del stack, en la base `document_store` (colecciones `documents`
  y `counters`). Es la única base del stack: ningún otro servicio usa MongoDB.
- pdf-extractext y el orquestador esperan a que esté `healthy` antes de
  arrancar. Su healthcheck usa `/ready`, que hace `ping` a MongoDB: si la base
  no responde, pasa a `unhealthy` y las altas fallan con `503`. `/health` solo
  dice que el proceso está vivo.

## Probar el flujo completo con un PDF

Con todo en `healthy`, desde la carpeta donde está el PDF:

```powershell
curl.exe -k -F "file=@documento.pdf" https://orchestrator.proyecto.localhost/api/v1/documents
```

Responde `201` con el `document_id`, el `checksum` y el texto extraído. Para
ponerle otro nombre, agregar `-F "name=Mi documento"`.

Si se sube el mismo PDF otra vez, responde `409` (Problem Details) porque el
checksum ya existe:

```powershell
curl.exe -k -i -F "file=@documento.pdf" https://orchestrator.proyecto.localhost/api/v1/documents
```

Para ver lo guardado en MongoDB (usuario y clave del `.env`):

```powershell
docker compose exec mongo mongosh -u admin -p 9009 --authenticationDatabase admin --eval "db.getSiblingDB('document_store').documents.find({}, { extracted_text: 0 }).toArray()"
```

Con `document-store` detenido, el alta responde `503` y el detalle lo nombra:

```powershell
docker compose stop document-store
curl.exe -k -i -F "file=@otro.pdf" https://orchestrator.proyecto.localhost/api/v1/documents
docker compose start document-store
```

## Apagado ordenado (12-Factor IX)

Ante `docker compose stop`, `down`, un `--scale` hacia abajo o un redeploy,
Docker manda `SIGTERM` y espera `stop_grace_period` antes de matar el proceso
con `SIGKILL`. uvicorn es el PID 1 de cada contenedor (`CMD ["python",
"main.py"]`): al recibir la señal deja de aceptar conexiones, espera las
requests en curso hasta `GRACEFUL_SHUTDOWN_SECONDS` y ejecuta el cierre del
`lifespan` (el orquestador cierra sus clients httpx; document-store, el cliente
de MongoDB).

| Servicio | `GRACEFUL_SHUTDOWN_SECONDS` | `stop_grace_period` | Por qué |
|---|---|---|---|
| orchestrator | 60 | 70s | Una request puede esperar a pdf-extractext hasta 60 s (`HTTP_TIMEOUT_SECONDS` del override) |
| document-store | 10 | 15s | Consultas e inserts cortos (timeout de MongoDB de 3 s) |
| pdf-extractext | — | 35s | Termina su cola: hasta 25 s por request (`EXTRACT_MAX_WAIT_SECONDS`) |

En cada servicio la espera de uvicorn es **menor** que la de Docker, así el
cierre termina antes del `SIGKILL`.

Cómo se probó: mientras se sube un PDF grande, en otra terminal
`docker compose stop orchestrator`. La subida termina con su `201` y los logs
muestran el cierre ordenado:

```powershell
docker compose logs orchestrator | Select-String "Shutting down|Waiting for application shutdown|Application shutdown complete"
```

## Levantar varias réplicas del Orchestrator

Para ejecutar tres instancias:

```powershell
docker compose up -d --build --scale orchestrator=3
```

Traefik detecta automáticamente las réplicas y distribuye las solicitudes entre ellas.

## Verificar las réplicas

```powershell
docker compose ps orchestrator
```

## Traefik Dashboard

El dashboard local está disponible **solo desde la máquina anfitriona** en:

```text
http://localhost:8080/dashboard/
```

El puerto 8080 está publicado únicamente en `127.0.0.1` (localhost), no en todas las interfaces (`0.0.0.0`). Esto evita la exposición del dashboard administrativo y la API insegura de Traefik a la red, cumpliendo con los criterios de seguridad de la issue #3.

Para acceder desde otra máquina en la red local, se requiere un túnel SSH o configurar autenticación/TLS en Traefik (fuera del alcance de esta mitigación).

## Probar el Orchestrator

```powershell
curl.exe -k https://orchestrator.proyecto.localhost/health
```

Respuesta esperada:

```json
{
  "status": "ok"
}
```

## Verificar el balanceo de carga

Se pueden generar varias solicitudes con PowerShell:

```powershell
1..30 | ForEach-Object {
    curl.exe -k -s -o NUL https://orchestrator.proyecto.localhost/openapi.json
}
```

Luego se pueden revisar los logs de las réplicas:

```powershell
docker compose logs orchestrator --since 2m | Select-String "GET /openapi.json"
```

## Arquitectura

```text
Cliente
   │
   ▼
Traefik ──────── POST /extract ────────┐
   │                                   │
   ▼                                   ▼
Orchestrator Service ──────▶ PDF Extractext (x5, sin base)
   │
   ▼
Document Store
   │  base document_store
   ▼
MongoDB
```

Traefik funciona como punto de entrada al sistema y distribuye las solicitudes entre las réplicas disponibles del Orchestrator y, para `POST /extract`, entre las réplicas de PDF Extractext.

Traefik termina TLS y le pasa al orquestador `X-Forwarded-Proto` y
`X-Forwarded-For`. El orquestador solo los acepta de la red del stack
(`FORWARDED_ALLOW_IPS` = `STACK_SUBNET`), así que las URLs que arma (por
ejemplo `instance` en los errores) salen con `https://`, y un contenedor que le
hable sin pasar por Traefik no puede falsear la IP ni el esquema del cliente.

El Orchestrator se comunica internamente con `pdf-extractext` (extrae el texto
con `POST /extract`) y con `document-store` (guarda el documento con
`POST /api/v1/documents`) mediante la red de Docker Compose. `document-store`
no está expuesto en Traefik.

## Detener la infraestructura

```powershell
docker compose down
```

Los datos de MongoDB (la base `document_store`, de Document Store) se mantienen
en el volumen `mongo_data`.

> **Opcional, en volúmenes viejos:** si el volumen viene de antes de
> pdf-extractext 2.0.0, puede quedar la base `pdf_extract` con los documentos
> del CRUD anterior. Ya no la usa nadie y no molesta. Para verla:
>
> ```powershell
> docker compose exec mongo mongosh -u admin -p 9009 --authenticationDatabase admin --eval "db.getMongo().getDBNames()"
> ```
>
> Para borrarla (**borra esos datos** y no se puede deshacer):
>
> ```powershell
> docker compose exec mongo mongosh -u admin -p 9009 --authenticationDatabase admin --eval "db.getSiblingDB('pdf_extract').dropDatabase()"
> ```

Para eliminar también el volumen:

```powershell
docker compose down -v
```

Usar `-v` únicamente cuando se quieran eliminar también los datos persistidos en MongoDB.