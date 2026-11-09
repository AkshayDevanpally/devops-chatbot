variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "instance_type" {
  description = "amd64 only: the images in the home registry are built for amd64."
  type        = string
  default     = "c6a.xlarge" # 4 vCPU / 8 GB
}

variable "spot" {
  description = "Spot (about a third of the price; AWS may take it back with 2 minutes' notice)."
  type        = bool
  default     = true
}

variable "home_cidr" {
  description = "Home public IP as /32. Only it may reach WireGuard."
  type        = string
}

variable "home_lan_ip" {
  description = "The home k3s node's own IP (k3s API and flannel VXLAN go to it through the tunnel)."
  type        = string
}

variable "home_public_key" {
  type = string
}

variable "aws_private_key" {
  description = "WireGuard key for this node, made fresh for each bring-up."
  type        = string
  sensitive   = true
}

variable "k3s_token" {
  description = "Short-lived k3s bootstrap token (expires an hour after bring-up)."
  type        = string
  sensitive   = true
}

variable "k3s_version" {
  description = "Must match the home server."
  type        = string
}

variable "apparmor_profile" {
  description = "k8s/apparmor/k8s-chatbot: every chatbot pod requires it on its node."
  type        = string
}

variable "idle_minutes" {
  description = "Power off (and so terminate) after this long with the node idle."
  type        = number
  default     = 30
}

variable "max_hours" {
  description = "Power off after this long no matter what, so a forgotten node can't run up a bill."
  type        = number
  default     = 6
}
