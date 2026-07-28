variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "alb_ingress_cidrs" {
  description = "CIDR autorizados a llegar al ALB. Puede limitarse a rangos de Cloudflare."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "backend_port" {
  type    = number
  default = 8080
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
