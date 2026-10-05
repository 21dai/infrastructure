# Infrastructure

Infraestructura Docker del proyecto de microservicios.

Este repositorio contiene la configuración necesaria para ejecutar el sistema utilizando **Docker Compose** y **Traefik** como reverse proxy y balanceador de carga.

## Estructura del proyecto

Los repositorios deben estar ubicados como carpetas hermanas:

```text
Proyecto/
├── orchestrator-service/
├── pdf-extractext/
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
Mongo crea el usuario solo al inicializar el volumen: si se cambia la clave,
hay que recrearlo con `docker compose down -v` (borra los datos).

## Levantar la infraestructura

Desde la carpeta `infrastructure`:

```powershell
docker compose up -d --build
```

Esto inicia:

- Traefik
- Orchestrator Service
- PDF Extractext (5 réplicas, 1 CPU y 1 GB cada una)
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
                                       │
                                       ▼
                                    MongoDB
```

Traefik funciona como punto de entrada al sistema y distribuye las solicitudes entre las réplicas disponibles del Orchestrator y, para `POST /extract`, entre las réplicas de PDF Extractext.

El Orchestrator se comunica internamente con `pdf-extractext` mediante la red de Docker Compose.

## Detener la infraestructura

```powershell
docker compose down
```

Los datos de MongoDB se mantienen en el volumen `mongo_data`.

Para eliminar también el volumen:

```powershell
docker compose down -v
```

Usar `-v` únicamente cuando se quieran eliminar también los datos persistidos en MongoDB.