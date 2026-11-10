# Levanta el stack completo de microservicios (Traefik, orquestador, 5
# replicas de pdf-extractext, document-store, MongoDB y Redis) con un solo
# comando desde PowerShell, tanto con Docker Desktop como con Docker instalado
# dentro de WSL. La primera vez prepara lo que falte: .env con claves propias
# y los certificados TLS de mkcert.
#
# Uso (desde cualquier carpeta):
#   .\scripts\levantar.ps1                  # detecta el Docker, prepara, construye y levanta
#   .\scripts\levantar.ps1 -SinBuild        # no reconstruye las imagenes
#   .\scripts\levantar.ps1 -Apagar          # apaga el stack (los datos de MongoDB quedan)
#   .\scripts\levantar.ps1 -Docker wsl      # fuerza Docker de WSL (o windows)
#   .\scripts\levantar.ps1 -Distro Ubuntu   # distro de WSL a usar
#
# Si PowerShell no deja correr scripts:
#   powershell -ExecutionPolicy Bypass -File .\scripts\levantar.ps1
#
# Con Docker en WSL, la distro se apaga sola cuando no queda ningun proceso de
# WSL abierto, y Docker con ella. Por eso el script deja un "sleep infinity"
# oculto mientras el stack esta levantado; -Apagar lo termina.
#
# El stack del TP del monolito (pdf-extractext\scripts\levantar.ps1) usa los
# mismos puertos 80, 443 y 8080: no se pueden levantar a la vez.
param(
    [ValidateSet("auto", "windows", "wsl")]
    [string]$Docker = "auto",
    [switch]$Apagar,
    [switch]$SinBuild,
    [string]$Distro = ""
)

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$proyectos = Split-Path $repo -Parent
$keepAlive = Join-Path $env:TEMP "infrastructure-wsl-keepalive.pid"
# wsl.exe escribe en UTF-16 salvo con esta variable.
$env:WSL_UTF8 = "1"

function Paso($texto) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $texto" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Fallar($texto) {
    Write-Host ""
    Write-Host $texto -ForegroundColor Red
    exit 1
}

function Avisar($texto) {
    Write-Host $texto -ForegroundColor Yellow
}

# --- Preparacion: .env, certificados y repos hermanos ----------------------------

function Preparar-Env {
    $archivo = Join-Path $repo ".env"
    $ejemplo = Join-Path $repo ".env.example"
    if (-not (Test-Path $archivo)) {
        # Claves propias de 32 caracteres hexadecimales (no hace falta escaparlas
        # en las URLs de conexion). No se muestran: quedan solo en .env.
        $texto = [IO.File]::ReadAllText($ejemplo)
        foreach ($clave in "MONGO_ROOT_PASSWORD", "REDIS_PASSWORD") {
            $texto = $texto -replace "(?m)^$clave=cambiar-esta-clave", "$clave=$([guid]::NewGuid().ToString('N'))"
        }
        [IO.File]::WriteAllText($archivo, $texto)
        Write-Host "Se creo .env a partir de .env.example, con claves nuevas de MongoDB y Redis."
        return
    }
    # Un .env existente no se toca: la clave de MongoDB tiene que seguir siendo
    # la del volumen. Solo se avisa lo que le falta.
    $variable = "(?m)^([A-Z_]+)="
    $tiene = [regex]::Matches([IO.File]::ReadAllText($archivo), $variable) | ForEach-Object { $_.Groups[1].Value }
    $pide = [regex]::Matches([IO.File]::ReadAllText($ejemplo), $variable) | ForEach-Object { $_.Groups[1].Value }
    $faltan = @($pide | Where-Object { $tiene -notcontains $_ })
    if ($faltan.Count -gt 0) {
        Avisar "A .env le faltan variables de .env.example: $($faltan -join ', '). Copialas de .env.example (sin cambiar tu clave de MongoDB)."
    }
    if (Select-String -Path $archivo -Pattern "^[A-Z_]+=cambiar-esta-clave" -Quiet) {
        Avisar "En .env queda alguna clave en 'cambiar-esta-clave'. Ver 'Variables de entorno' en el README."
    }
    Write-Host ".env ya existe: no se modifica."
}

function Preparar-Certificados {
    $cert = Join-Path $repo "certs\local-cert.pem"
    $clave = Join-Path $repo "certs\local-key.pem"
    if ((Test-Path $cert) -and (Test-Path $clave)) {
        Write-Host "Certificados TLS: ya estan en certs\."
        return
    }
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Fallar "Faltan los certificados TLS y no esta mkcert. Instalalo (choco install mkcert, o winget install FiloSottile.mkcert) y volve a correr el script."
    }
    Write-Host "Generando los certificados TLS con mkcert"
    # Instala la autoridad local en Windows (si ya esta, no hace nada).
    mkcert -install
    Push-Location $repo
    mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem "*.proyecto.localhost" "proyecto.localhost" localhost 127.0.0.1 ::1
    $codigo = $LASTEXITCODE
    Pop-Location
    if ($codigo -ne 0) { Fallar "mkcert no pudo generar los certificados." }
}

function Verificar-Repos {
    $faltan = @("orchestrator-service", "pdf-extractext", "document-store") |
        Where-Object { -not (Test-Path (Join-Path $proyectos $_)) }
    if ($faltan) {
        Fallar "Faltan repos al lado de infrastructure, en ${proyectos}: $($faltan -join ', '). Clonalos de https://github.com/21dai en esa carpeta."
    }
    Write-Host "Repos hermanos: orchestrator-service, pdf-extractext y document-store."
}

# --- Deteccion del Docker -----------------------------------------------------

function Probar-DockerWindows {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return "falta" }
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return "ok" }
    return "apagado"
}

function Distros-Wsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $lista = (wsl.exe -l -q 2>$null) -replace "`0", "" | ForEach-Object { $_.Trim() }
    # Las distros internas de Docker Desktop no sirven para correr comandos.
    return @($lista | Where-Object { $_ -and $_ -notlike "docker-desktop*" })
}

function Probar-DockerWsl($nombre) {
    wsl.exe -d $nombre --exec sh -c "command -v docker" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return "falta" }
    # Si la distro estaba apagada, el daemon tarda unos segundos en arrancar.
    for ($i = 0; $i -lt 10; $i++) {
        wsl.exe -d $nombre --exec docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return "ok" }
        Start-Sleep -Seconds 2
    }
    return "apagado"
}

function Elegir-Wsl {
    $candidatas = if ($Distro) { @($Distro) } else { Distros-Wsl }
    if ($candidatas.Count -eq 0) { return $null }
    foreach ($d in $candidatas) {
        $estado = Probar-DockerWsl $d
        if ($estado -eq "ok") { return $d }
        if ($estado -eq "apagado") {
            Fallar "Docker esta instalado en WSL ($d) pero el daemon no responde. Abri Ubuntu y corre: sudo service docker start"
        }
    }
    return $null
}

function Detectar-Docker {
    if ($Docker -ne "wsl") {
        $estado = Probar-DockerWindows
        if ($estado -eq "ok") { return @{ Modo = "windows"; Distro = "" } }
        if ($Docker -eq "windows") {
            if ($estado -eq "apagado") { Fallar "Docker Desktop esta instalado pero no responde: abrilo y espera a que diga 'Engine running'." }
            Fallar "No se encontro el comando docker en Windows. Instala Docker Desktop o usa -Docker wsl."
        }
        if ($estado -eq "apagado") {
            Fallar "Docker Desktop esta instalado pero no responde: abrilo y espera a que diga 'Engine running'."
        }
    }
    $d = Elegir-Wsl
    if ($d) { return @{ Modo = "wsl"; Distro = $d } }
    Fallar "No se encontro Docker ni en Windows (Docker Desktop) ni en ninguna distro de WSL."
}

# --- Comandos de Docker en el modo elegido -------------------------------------

# Corre "docker <argumentos>" en la carpeta del repo; el codigo de salida queda
# en $LASTEXITCODE. En WSL, --cd acepta la ruta de Windows y --exec evita que
# bash vuelva a interpretar los argumentos.
function Docker-Run([string[]]$argumentos) {
    if ($script:modo -eq "windows") {
        Push-Location $repo
        & docker @argumentos
        Pop-Location
    } else {
        & wsl.exe -d $script:distro --cd $repo --exec docker @argumentos
    }
}

function Compose([string[]]$argumentos) {
    Docker-Run (@("compose") + $argumentos)
}

# Nombre del proyecto de compose: el de la carpeta, normalizado por compose.
function Proyecto-Compose {
    # PowerShell 5.1 convierte cada linea por separado: unirlas antes.
    $json = (Compose @("config", "--format", "json")) -join "`n"
    return ($json | ConvertFrom-Json).name
}

# Contenedores de otro proyecto de compose que ya ocupan el puerto 443.
function Choque-De-Puertos($proyecto) {
    $filas = Docker-Run @("ps", "--filter", "publish=443", "--format", "{{.Names}};{{.Labels}}")
    foreach ($fila in @($filas)) {
        if (-not $fila) { continue }
        $nombre, $labels = $fila -split ";", 2
        $otro = ""
        if ($labels -match "com\.docker\.compose\.project=([^,]+)") { $otro = $Matches[1] }
        if ($otro -ne $proyecto) { return @{ Nombre = $nombre; Proyecto = $otro } }
    }
    return $null
}

function Iniciar-KeepAlive {
    if (Test-Path $keepAlive) {
        $id = Get-Content $keepAlive -ErrorAction SilentlyContinue
        if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { return }
    }
    $p = Start-Process wsl.exe -ArgumentList @("-d", $script:distro, "--exec", "sleep", "infinity") -WindowStyle Hidden -PassThru
    Set-Content -Path $keepAlive -Value $p.Id
}

function Detener-KeepAlive {
    if (-not (Test-Path $keepAlive)) { return }
    $id = Get-Content $keepAlive -ErrorAction SilentlyContinue
    $p = if ($id) { Get-Process -Id $id -ErrorAction SilentlyContinue }
    if ($p -and $p.ProcessName -eq "wsl") { Stop-Process -Id $id -Force }
    Remove-Item $keepAlive -ErrorAction SilentlyContinue
}

# --- Principal --------------------------------------------------------------------

if (-not $Apagar) {
    Paso "Preparando .env, certificados y repos"
    Preparar-Env
    Preparar-Certificados
    Verificar-Repos
}

Paso "Detectando Docker"
$elegido = Detectar-Docker
$script:modo = $elegido.Modo
$script:distro = $elegido.Distro
if ($script:modo -eq "wsl") {
    Write-Host "Docker de WSL, distro $($script:distro)"
} else {
    Write-Host "Docker Desktop"
}

if ($Apagar) {
    Paso "Apagando el stack completo"
    Compose @("down")
    $codigo = $LASTEXITCODE
    if ($script:modo -eq "wsl") { Detener-KeepAlive }
    exit $codigo
}

$choque = Choque-De-Puertos (Proyecto-Compose)
if ($choque) {
    $como = if ($choque.Proyecto -eq "pdf-extractext-tp") {
        "Apagalo con: ..\pdf-extractext\scripts\levantar.ps1 -Apagar"
    } else {
        "Apagalo antes de seguir (docker stop $($choque.Nombre))."
    }
    Fallar "El puerto 443 ya lo usa '$($choque.Nombre)' (proyecto '$($choque.Proyecto)'). $como"
}

Paso "Levantando el stack completo (espera a que todo este healthy)"
$up = @("up", "-d", "--wait", "--wait-timeout", "300")
if (-not $SinBuild) { $up += "--build" }
Compose $up
if ($LASTEXITCODE -ne 0) {
    Compose @("ps")
    Fallar "El stack no quedo healthy. Revisa los logs con: docker compose logs"
}
if ($script:modo -eq "wsl") { Iniciar-KeepAlive }

Compose @("ps")

Paso "Chequeo desde Windows"
$estado = curl.exe -k -s -o NUL -w "%{http_code}" https://orchestrator.proyecto.localhost/health
if ($estado -eq "200") {
    Write-Host "GET https://orchestrator.proyecto.localhost/health -> 200" -ForegroundColor Green
} elseif ($estado -eq "000") {
    Avisar "No se pudo conectar a orchestrator.proyecto.localhost. Si el dominio no resuelve, agrega '127.0.0.1 orchestrator.proyecto.localhost' a C:\Windows\System32\drivers\etc\hosts (ver el README)."
} else {
    Avisar "GET https://orchestrator.proyecto.localhost/health -> $estado (esperaba 200)"
}

Write-Host ""
Write-Host "Orquestador:             https://orchestrator.proyecto.localhost/api/v1/documents"
Write-Host "POST /extract directo:   https://extract.proyecto.localhost/extract"
Write-Host "Dashboard de Traefik:    http://localhost:8080/dashboard/"
Write-Host "Para apagar:             .\scripts\levantar.ps1 -Apagar"
