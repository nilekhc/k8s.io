/*
Copyright 2023 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

locals {
  domain_name = "cdn.dl-sandbox.k8s.dev"
}

resource "fastly_service_vcl" "files" {
  name     = local.domain_name
  activate = true

  domain {
    name = local.domain_name
  }

  backend {
    name             = "GCS"
    auto_loadbalance = false

    healthcheck = "GCS Health"

    address           = "storage.googleapis.com"
    port              = 443
    use_ssl           = true
    ssl_cert_hostname = "storage.googleapis.com"
    ssl_sni_hostname  = "storage.googleapis.com"

    override_host = "${var.bucket}.storage.googleapis.com"

    shield = "chi-il-us"

    connect_timeout       = 5000  # milliseconds
    between_bytes_timeout = 15000 # milliseconds
    error_threshold       = 5
  }

  /*
  healthcheck {
    name = "GCS Health"

    host           = "${var.bucket}.storage.googleapis.com"
    method         = "GET"
    path           = "/"
    check_interval = 3000
    timeout        = 2000
    threshold      = 2
    initial        = 2
    window         = 4
  }
*/
  snippet {
    content  = <<-EOT
      if (req.url.path ~ "^/release/") {
        set req.enable_segmented_caching = true;
      }
    EOT
    name     = "Enable segment caching for large files"
    priority = 60
    type     = "recv"
  }

  # Allow CORS GET requests.
  header {
    destination = "http.access-control-allow-origin"
    type        = "response"
    action      = "set"
    name        = "CORS Allow"
    source      = "\"*\""
  }
  # Do not cache 'not found' & authenticated requests:
  condition {
    type      = "CACHE"
    name      = "is-not-found"
    statement = "beresp.status == 404"
  }

  cache_setting {
    name            = "pass-not-found"
    cache_condition = "is-not-found"
    action          = "pass"
    ttl             = 120
    stale_ttl       = 120
  }

  snippet {
    name = "Authenticate to GCS requests"
    type = "init"
    content = templatefile("${path.module}/vcl/gcs-auth.vcl", {
      access_key     = data.google_secret_manager_secret_version_access.gcs_reader_access_key.secret_data
      secret_key     = data.google_secret_manager_secret_version_access.gcs_reader_secret_key.secret_data
      backend_bucket = var.bucket
      region         = "us-central1"
      }
    )
  }

  /*
  snippet {
    name    = "GCS Auth - MISS"
    type    = "miss"
    content = <<-EOT
      call set_google_auth_header;
    EOT
  }

  snippet {
    name    = "GCS Auth - PASS"
    type    = "pass"
    content = <<-EOT
      call set_google_auth_header;
    EOT
  }
  */

  vcl {
    name    = "Main"
    content = file("${path.module}/vcl/binaries.vcl")
    main    = true
  }

  product_enablement {
    origin_inspector = true
    domain_inspector = true
  }

  force_destroy = true
}

