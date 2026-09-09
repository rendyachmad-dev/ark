variable "ssh_public_key" {
  description = "SSH public key for the DR instance. Generate with: ssh-keygen -t ed25519"
  type        = string
}
