variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "home_cidr" {
  description = "Home public IP as /32. Only it may reach WireGuard."
  type        = string
}

variable "home_public_key" {
  description = "WireGuard public key of the home server."
  type        = string
}

variable "aws_private_key" {
  description = "WireGuard private key for this endpoint, made fresh for each bring-up."
  type        = string
  sensitive   = true
}

variable "postgres_ca" {
  description = "Local CA certificate (public) so clients here can use sslmode=verify-full."
  type        = string
}
