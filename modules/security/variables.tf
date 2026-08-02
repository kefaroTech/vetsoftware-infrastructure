variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "cloudflare_tunnel_ipv4_cidrs" {
  description = "Rangos oficiales usados por los endpoints de Cloudflare Tunnel en el puerto 7844."
  type        = list(string)
  default = [
    "198.41.192.7/32",
    "198.41.192.27/32",
    "198.41.192.37/32",
    "198.41.192.47/32",
    "198.41.192.57/32",
    "198.41.192.67/32",
    "198.41.192.77/32",
    "198.41.192.107/32",
    "198.41.192.167/32",
    "198.41.192.227/32",
    "198.41.200.13/32",
    "198.41.200.23/32",
    "198.41.200.33/32",
    "198.41.200.43/32",
    "198.41.200.53/32",
    "198.41.200.63/32",
    "198.41.200.73/32",
    "198.41.200.113/32",
    "198.41.200.193/32",
    "198.41.200.233/32",
  ]
}

variable "alloy_grpc_port" {
  type    = number
  default = 4317
}

variable "alloy_http_port" {
  type    = number
  default = 4318
}

variable "tags" {
  type    = map(string)
  default = {}
}
