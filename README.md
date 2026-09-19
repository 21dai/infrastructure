# Infrastructure

Infraestructura Docker del proyecto de microservicios.

Este repositorio contiene la configuración necesaria para ejecutar los microservicios utilizando **Docker Compose** y **Traefik** como reverse proxy y balanceador de carga.

## Estructura

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

- Docker
- Docker Compose
- OpenSSL

## Certificados TLS

Los certificados utilizados para desarrollo local no se almacenan en el repositorio.

Después de clonar el proyecto, generar los certificados ejecutando desde la carpeta `infrastructure`:

```bash
openssl req -x509 -nodes \
  -newkey rsa:2048 \
  -keyout certs/key.pem \
  -out certs/cert.pem \
  -days 365 \
  -subj "/CN=localhost"
```

Esto generará:

```text
certs/
├── cert.pem
└── key.pem
```

Estos archivos están excluidos de Git mediante `.gitignore`.

## Levantar la infraestructura

Desde la carpeta `infrastructure` ejecutar:

```bash
docker compose up --build
```

Esto inicia:

- Traefik
- Orchestrator Service
- Los servicios definidos en `docker-compose.yml`

## Verificar los contenedores

```bash
docker compose ps
```

## Traefik Dashboard

El dashboard de Traefik está disponible en:

```text
http://localhost:8080/dashboard/
```

## Probar el Orchestrator

El endpoint de health puede probarse con:

```bash
curl -k https://orchestrator.localhost/health
```

La respuesta esperada es:

```json
{
  "status": "ok"
}
```

## Detener la infraestructura

Para detener y eliminar los contenedores creados por Docker Compose:

```bash
docker compose down
```

## Arquitectura

El flujo principal de las solicitudes es:

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
Microservicios
```

Traefik actúa como punto de entrada a la arquitectura y se encarga del enrutamiento de las solicitudes hacia los servicios correspondientes.