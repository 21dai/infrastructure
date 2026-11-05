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
Tambien define los tags de las imagenes (`ORCHESTRATOR_TAG`,
`PDF_EXTRACTEXT_TAG`, `DOCUMENT_STORE_TAG`): la version de cada servicio, que
hay que subir en cada release para que cada imagen quede identificada en vez de
pisar un `latest`.
Mongo crea el usuario solo al inicializar el volumen: si se cambia la clave,
hay que recrearlo con `docker compose down -v` (borra los datos).

> **Si ya tenías un `.env`**: agregale `DOCUMENT_STORE_TAG=0.1.0` (o volvé a
> copiar `.env.example`). Sin esa variable `docker compose` no arranca y
> muestra `required variable DOCUMENT_STORE_TAG is missing a value`.

## Levantar la infraestructura

Desde la carpeta `infrastructure`:

```powershell
docker compose up -d --build
```

Esto inicia:

- Traefik
- Orchestrator Service
- PDF Extractext (5 réplicas, 1 CPU y 1 GB cada una)
- Document Store
- MongoDB

`docker-compose.override.yml` se aplica solo y ajusta la concurrencia para las
pruebas de carga (1 proceso de uvicorn por réplica, Bulkhead del orquestador en
5). Para levantar sin esos ajustes:

```powershell
docker compose -f docker-compose.yml up -d --build
```

Esperar a que todo diga `healthy` en `docker compose ps` antes de probar:
mientras arranca, Traefik no tiene a dónde mandar el tráfico y responde 404.

## PDF Extractext: réplicas y POST /extract

`pdf-extractext` corre con 5 réplicas (el máximo del TP de carga) y sin
`container_name`, porque un nombre fijo impide crear réplicas. El orquestador
lo sigue encontrando por el nombre del servicio (`http://pdf-extractext:8000`).

Traefik expone **solo** `POST /extract`, directo a las réplicas y sin pasar por
el orquestador; el CRUD de `pdf-extractext` sigue siendo interno:

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
- **Mismo MongoDB** del stack, en su propia base `document_store` (colecciones
  `documents` y `counters`), separada de `pdf_extract`.
- El orquestador espera a que esté `healthy` antes de arrancar. Su `/health`
  no consulta MongoDB: si la base no responde, el healthcheck sigue en verde y
  las altas fallan con `503`.

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

El dashboard local está disponible en:

```text
http://localhost:8080/dashboard/
```

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
Orchestrator Service ──────▶ PDF Extractext (x5)
   │                                   │
   ▼                                   │
Document Store                         │
   │  base document_store              │  base pdf_extract
   ▼                                   ▼
MongoDB ◀──────────────────────────────┘
```

Traefik funciona como punto de entrada al sistema y distribuye las solicitudes entre las réplicas disponibles del Orchestrator y, para `POST /extract`, entre las réplicas de PDF Extractext.

El Orchestrator se comunica internamente con `pdf-extractext` (extrae el texto
con `POST /extract`) y con `document-store` (guarda el documento con
`POST /api/v1/documents`) mediante la red de Docker Compose. `document-store`
no está expuesto en Traefik.

## Detener la infraestructura

```powershell
docker compose down
```

Los datos de MongoDB (las bases `pdf_extract` y `document_store`) se mantienen
en el volumen `mongo_data`.

Para eliminar también el volumen:

```powershell
docker compose down -v
```

Usar `-v` únicamente cuando se quieran eliminar también los datos persistidos en MongoDB.