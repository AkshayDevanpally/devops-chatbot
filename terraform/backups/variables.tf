variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "keep_days" {
  description = "Off-site copies are deleted by S3 after this many days."
  type        = number
  default     = 30
}
