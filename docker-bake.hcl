variable "REGISTRY" {
  default = "registry.org"
}

variable "IMAGE" {
  default = "mon-app"
}

variable "VERSION" {
  default = "1.0"
}

group "default" {
  targets = ["app"]
}

target "app" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "runtime"

  platforms = ["linux/amd64", "linux/arm64"]

  tags = [
    "${REGISTRY}/${IMAGE}:${VERSION}",
    "${REGISTRY}/${IMAGE}:latest",
  ]

  secret = ["id=pkg_token,src=./secrets/pkg_token.txt"]

  cache-from = ["type=registry,ref=${REGISTRY}/${IMAGE}:buildcache"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${IMAGE}:buildcache,mode=max"]

  output = ["type=registry"]
}