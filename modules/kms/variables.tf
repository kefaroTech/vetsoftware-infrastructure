variable "name" {
  type = string
}

variable "deletion_window_in_days" {
  type    = number
  default = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days debe estar entre 7 y 30."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
