terraform {
  backend "oras" {
    repository   = "ghcr.io/OWNER/infra-state"
    max_versions = 0
  }
}

resource "terraform_data" "example" {
  input = "synthetic-state-only"
}
