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

## Levantar la infraestructura

Desde la carpeta `infrastructure`:

```powershell
docker compose up -d --build
```

Esto inicia:

- Traefik
- Orchestrator Service
- PDF Extractext
- MongoDB

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
Traefik
   │
   ▼
Orchestrator Service
   │
   ▼
PDF Extractext
   │
   ▼
MongoDB
```

Traefik funciona como punto de entrada al sistema y distribuye las solicitudes entre las réplicas disponibles del Orchestrator.

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