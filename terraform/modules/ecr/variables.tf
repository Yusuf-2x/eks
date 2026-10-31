variable "name" {
  description = "Repository name."
  type        = string
}

variable "max_image_count" {
  description = "How many images to keep before the oldest are deleted."
  type        = number
  default     = 20
}

variable "untagged_expiry_days" {
  type    = number
  default = 7
}
