# Registre et nom de l'image publiée (surchargeables par variable d'environnement)
variable "REGISTRY" {
  default = "ghcr.io/corentinbl"
}

variable "IMAGE" {
  default = "dev-docker-tp1-api"
}

# Version SemVer : la CI passe le tag Git (ex. v1.1.0), le "v" est retiré plus bas
variable "VERSION" {
  default = "0.0.0-dev"
}

# Commit construit, pour un tag immuable traçable jusqu'au code source
variable "GIT_SHA" {
  default = "local"
}

group "default" {
  targets = ["app"]
}

target "app" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "runtime"

  # Index multi-architecture : postes x86_64 et ARM (Mac M, Graviton)
  platforms = ["linux/amd64", "linux/arm64"]

  # Pas de "latest" : uniquement des tags qui désignent une version précise
  tags = [
    "${REGISTRY}/${IMAGE}:${trimprefix(VERSION, "v")}",
    "${REGISTRY}/${IMAGE}:sha-${GIT_SHA}",
  ]

  # Jeton lu depuis la variable d'environnement PKG_TOKEN, monté en mémoire le temps d'un RUN
  secret = ["id=pkg_token,env=PKG_TOKEN"]

  # Cache partagé sur le registre, mode=max pour garder aussi les couches intermédiaires
  cache-from = ["type=registry,ref=${REGISTRY}/${IMAGE}:buildcache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${IMAGE}:buildcache,mode=max"]

  output = ["type=registry"]
}